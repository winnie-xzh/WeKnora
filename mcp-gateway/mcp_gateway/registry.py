"""Service and tool registry for the MCP gateway.

Loads backend service definitions from a YAML config file, resolves
environment variable references, and constructs MCP ``Tool`` objects.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from typing import Any, Optional

import mcp.types as types
import yaml

from mcp_gateway.auth import AuthConfig, AuthType

# ── env-var reference: ${VAR} or ${VAR:-default} ──────────────────────
_ENV_REF_RE = re.compile(r"\$\{([^}:]+)(?::-(.*?))?\}")


def _resolve_env(value: str) -> str:
    """Replace ``${VAR}`` and ``${VAR:-default}`` references from the environment."""

    def _replace(m: re.Match) -> str:
        var = m.group(1)
        default = m.group(2)
        return os.environ.get(var, default or "")

    return _ENV_REF_RE.sub(_replace, value)


def _resolve_env_deep(obj: Any) -> Any:
    """Recursively resolve env-var references in strings found in *obj*."""
    if isinstance(obj, str):
        return _resolve_env(obj)
    if isinstance(obj, dict):
        return {k: _resolve_env_deep(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_resolve_env_deep(item) for item in obj]
    return obj


# ── data models ───────────────────────────────────────────────────────


@dataclass
class ParameterDef:
    """A single parameter for a REST endpoint."""

    name: str
    type: str = "string"
    description: str = ""
    required: bool = False
    location: str = "query"  # path | query | header | body
    default: Any = None


@dataclass
class ToolDef:
    """A tool definition derived from a backend REST endpoint."""

    name: str = ""
    description: str = ""
    method: str = "GET"  # GET | POST | PUT | DELETE | PATCH
    path: str = "/"  # e.g. /api/quotes/{product}
    parameters: list[ParameterDef] = field(default_factory=list)


@dataclass
class ServiceConfig:
    """Configuration for a single backend service."""

    name: str = ""
    display_name: str = ""
    description: str = ""
    base_url: str = ""
    timeout: int = 30
    auth: AuthConfig = field(default_factory=AuthConfig)
    tools: list[ToolDef] = field(default_factory=list)


# ── registry ──────────────────────────────────────────────────────────

_NAMESPACE_SEP = "__"


class Registry:
    """Loads backend service config and provides MCP tool lookups.

    Usage::

        registry = Registry("config/gateway.yaml")
        tools = registry.list_all_tools()
        service, tool = registry.resolve_tool("pricing__get_quote")
    """

    def __init__(self, config_path: str) -> None:
        self._services: list[ServiceConfig] = []
        self._tool_map: dict[
            str, tuple[ServiceConfig, ToolDef]
        ] = {}  # namespaced name → (service, tool)
        self._load(config_path)

    # ── public API ────────────────────────────────────────────────────

    @property
    def services(self) -> list[ServiceConfig]:
        return list(self._services)

    @property
    def service_count(self) -> int:
        return len(self._services)

    @property
    def tool_count(self) -> int:
        return len(self._tool_map)

    def list_all_tools(self) -> list[types.Tool]:
        """Return all MCP tools across all backend services."""
        return [
            types.Tool(
                name=ns_name,
                description=self._tool_description(service, tool),
                inputSchema=self._build_input_schema(tool),
            )
            for ns_name, (service, tool) in sorted(self._tool_map.items())
        ]

    def resolve_tool(self, name: str) -> tuple[ServiceConfig, ToolDef]:
        """Lookup a namespaced tool name.

        Raises ``KeyError`` if the tool is not found.
        """
        return self._tool_map[name]

    def resolve_tool_or_none(
        self, name: str
    ) -> Optional[tuple[ServiceConfig, ToolDef]]:
        """Lookup a namespaced tool name, returning ``None`` on miss."""
        return self._tool_map.get(name)

    def known_tool_names(self) -> list[str]:
        return sorted(self._tool_map.keys())

    # ── internal ──────────────────────────────────────────────────────

    def _load(self, config_path: str) -> None:
        """Load and parse the YAML config file."""
        if not os.path.isfile(config_path):
            raise FileNotFoundError(f"Gateway config not found: {config_path}")

        with open(config_path, "r", encoding="utf-8") as f:
            raw = yaml.safe_load(f)

        if not raw or "services" not in raw:
            raise ValueError("Config must contain a 'services' list")

        # resolve env vars in the entire parsed document
        resolved = _resolve_env_deep(raw)

        gateway_cfg = resolved.get("gateway", {})
        self._default_timeout = gateway_cfg.get("request_timeout", 30)

        for svc in resolved["services"]:
            self._add_service(svc)

    def _add_service(self, svc: dict) -> None:
        """Parse one service block and register its tools."""
        name = svc.get("name", "")
        if not name:
            raise ValueError("Each service must have a 'name'")

        auth_cfg = AuthConfig.from_dict(svc.get("auth", {}))
        base_url = svc.get("base_url", "").rstrip("/")
        timeout = svc.get("timeout", self._default_timeout)

        service_cfg = ServiceConfig(
            name=name,
            display_name=svc.get("display_name", name),
            description=svc.get("description", ""),
            base_url=base_url,
            timeout=timeout,
            auth=auth_cfg,
        )

        for td in svc.get("tools", []):
            tool = self._parse_tool(td)
            service_cfg.tools.append(tool)

            ns_name = f"{name}{_NAMESPACE_SEP}{tool.name}"
            if ns_name in self._tool_map:
                raise ValueError(
                    f"Duplicate tool name {ns_name!r} "
                    f"(service={name!r}, tool={tool.name!r})"
                )
            self._tool_map[ns_name] = (service_cfg, tool)

        self._services.append(service_cfg)

    def _parse_tool(self, td: dict) -> ToolDef:
        """Parse one tool definition."""
        params = []
        for pd in td.get("parameters", []):
            params.append(
                ParameterDef(
                    name=pd.get("name", ""),
                    type=pd.get("type", "string"),
                    description=pd.get("description", ""),
                    required=pd.get("required", False),
                    location=pd.get("in", "query"),
                    default=pd.get("default"),
                )
            )

        return ToolDef(
            name=td.get("name", ""),
            description=td.get("description", ""),
            method=td.get("method", "GET").upper(),
            path=td.get("path", "/"),
            parameters=params,
        )

    def _tool_description(self, service: ServiceConfig, tool: ToolDef) -> str:
        """Build a description string for an MCP Tool."""
        parts = [f"[{service.display_name or service.name}] {tool.description}"]
        if service.description:
            parts.append(f" ({service.description})")
        return "".join(parts)

    def _build_input_schema(self, tool: ToolDef) -> dict:
        """Build a JSON Schema for the tool's input parameters."""
        properties: dict[str, dict] = {}
        required: list[str] = []

        for p in tool.parameters:
            schema: dict[str, Any] = {"type": p.type, "description": p.description}
            if p.default is not None:
                schema["default"] = p.default
            properties[p.name] = schema
            if p.required:
                required.append(p.name)

        schema: dict[str, Any] = {"type": "object", "properties": properties}
        if required:
            schema["required"] = required
        return schema
