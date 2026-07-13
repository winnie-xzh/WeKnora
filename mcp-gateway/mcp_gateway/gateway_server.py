"""MCP Gateway Server — translates MCP tool calls into REST API requests."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import secrets
import sys
from typing import Any

import mcp.server.stdio
import mcp.types as types
import requests
from mcp.server import NotificationOptions, Server
from mcp.server.models import InitializationOptions

from .backend_client import execute_rest_call
from .errors import GatewayError, ToolNotFoundError, format_error
from .registry import Registry

logger = logging.getLogger(__name__)

# ── config path ───────────────────────────────────────────────────────
_DEFAULT_CONFIG = os.path.join(os.path.dirname(__file__), "config", "gateway.yaml")


def _resolve_config_path() -> str:
    return os.environ.get("MCP_GATEWAY_CONFIG", _DEFAULT_CONFIG)


# ── auth for the gateway's own network transports ─────────────────────


def _network_auth_token() -> str:
    return os.getenv("MCP_GATEWAY_AUTH_TOKEN", "").strip()


def _require_network_auth(transport: str) -> str:
    token = _network_auth_token()
    if transport in ("sse", "http") and not token:
        logger.error(
            "MCP_GATEWAY_AUTH_TOKEN is required for %s transport. "
            "Set a strong shared secret.",
            transport,
        )
        sys.exit(1)
    return token


class MCPAuthMiddleware:
    """ASGI middleware that gates network transports behind a shared secret."""

    def __init__(self, app, token: str):
        self.app = app
        self.token = token

    async def __call__(self, scope, receive, send):
        if scope.get("type") != "http":
            await self.app(scope, receive, send)
            return

        # 健康检查跳过认证
        raw_path = scope.get("raw_path", b"").decode("latin-1", errors="replace")
        if raw_path == "/health":
            await self.app(scope, receive, send)
            return

        headers = {
            k.decode("latin-1").lower(): v.decode("latin-1")
            for k, v in scope.get("headers", [])
        }
        provided = ""
        auth = headers.get("authorization", "")
        if auth.lower().startswith("bearer "):
            provided = auth[7:].strip()
        elif "x-mcp-auth-token" in headers:
            provided = headers["x-mcp-auth-token"]

        if not provided or not secrets.compare_digest(provided, self.token):
            body = b'{"error":"unauthorized"}'
            await send(
                {
                    "type": "http.response.start",
                    "status": 401,
                    "headers": [[b"content-type", b"application/json"]],
                }
            )
            await send({"type": "http.response.body", "body": body})
            return

        await self.app(scope, receive, send)


# ── app setup ─────────────────────────────────────────────────────────

app = Server("mcp-gateway")

# initialise registry (lazy, on first tool access)
_registry: Registry | None = None
_http_session: requests.Session | None = None


def _get_registry() -> Registry:
    global _registry
    if _registry is None:
        config_path = _resolve_config_path()
        logger.info("Loading gateway config from %s", config_path)
        _registry = Registry(config_path)
        logger.info(
            "Loaded %d service(s) with %d tool(s)",
            _registry.service_count,
            _registry.tool_count,
        )
    return _registry


def _get_http_session() -> requests.Session:
    global _http_session
    if _http_session is None:
        _http_session = requests.Session()
    return _http_session


def preload():
    """Pre-load registry to fail fast on config errors. Call at startup."""
    _get_registry()


# ── MCP handlers ──────────────────────────────────────────────────────


@app.list_tools()
async def handle_list_tools() -> list[types.Tool]:
    """List all available tools from all backend services."""
    registry = _get_registry()
    return registry.list_all_tools()


@app.call_tool()
async def handle_call_tool(
    name: str, arguments: dict | None
) -> list[types.TextContent | types.ImageContent | types.EmbeddedResource]:
    """Execute a tool by routing the call to the appropriate backend service."""
    args = arguments or {}
    registry = _get_registry()

    resolved = registry.resolve_tool_or_none(name)
    if resolved is None:
        err = ToolNotFoundError(name, registry.known_tool_names())
        return [
            types.TextContent(type="text", text=str(err), isError=True)
        ]

    service, tool = resolved

    try:
        result = await asyncio.get_running_loop().run_in_executor(
            None,
            execute_rest_call,
            service,
            tool,
            args,
            _get_http_session(),
        )
        return [
            types.TextContent(
                type="text",
                text=json.dumps(result, indent=2, ensure_ascii=False),
            )
        ]
    except GatewayError as e:
        logger.warning("Gateway error for tool %s: %s", name, e)
        return [types.TextContent(type="text", text=str(e), isError=True)]
    except Exception as e:
        logger.exception("Unexpected error executing tool %s", name)
        return [
            types.TextContent(type="text", text=format_error(e), isError=True)
        ]


# ── transport runners ─────────────────────────────────────────────────


def _init_options() -> InitializationOptions:
    return InitializationOptions(
        server_name="mcp-gateway",
        server_version="1.0.0",
        capabilities=app.get_capabilities(
            notification_options=NotificationOptions(),
            experimental_capabilities={},
        ),
    )


async def run_stdio():
    """Run the MCP server using stdio transport."""
    async with mcp.server.stdio.stdio_server() as (read_stream, write_stream):
        await app.run(read_stream, write_stream, _init_options())


async def run_sse(host: str, port: int):
    """Run the MCP server using SSE transport."""
    auth_token = _require_network_auth("sse")
    try:
        from mcp.server.sse import SseServerTransport
        from starlette.applications import Starlette
        from starlette.routing import Mount
        import uvicorn
    except ImportError as e:
        raise ImportError(
            f"SSE transport requires 'starlette' and 'uvicorn': pip install starlette uvicorn\n{e}"
        ) from e

    sse = SseServerTransport("/messages/")

    async def handle_sse(scope, receive, send):
        async with sse.connect_sse(scope, receive, send) as streams:
            await app.run(streams[0], streams[1], _init_options())

    tool_count = _get_registry().tool_count

    async def health_endpoint(scope, receive, send):
        """健康检查 — 跳过认证中间件。"""
        if scope.get("method") == "GET":
            body = b'{"status":"ok","service":"mcp-gateway","tools":' + str(tool_count).encode() + b'}'
            await send({
                "type": "http.response.start",
                "status": 200,
                "headers": [[b"content-type", b"application/json"]],
            })
            await send({"type": "http.response.body", "body": body})

    starlette_app = Starlette(
        routes=[
            Mount("/health", app=health_endpoint),
            Mount("/sse", app=handle_sse),
            Mount("/messages/", app=sse.handle_post_message),
        ]
    )
    starlette_app = MCPAuthMiddleware(starlette_app, auth_token)

    logger.info("Starting SSE MCP gateway on %s:%d (%d tools)", host, port, tool_count)
    config = uvicorn.Config(starlette_app, host=host, port=port, log_level="info")
    server = uvicorn.Server(config)
    await server.serve()


async def run_http(host: str, port: int):
    """Run the MCP server using Streamable HTTP transport."""
    auth_token = _require_network_auth("http")
    try:
        from contextlib import asynccontextmanager
        from mcp.server.streamable_http_manager import StreamableHTTPSessionManager
        from starlette.applications import Starlette
        from starlette.routing import Mount
        import uvicorn
    except ImportError as e:
        raise ImportError(
            f"HTTP transport requires 'starlette' and 'uvicorn': pip install starlette uvicorn\n{e}"
        ) from e

    session_manager = StreamableHTTPSessionManager(
        app=app,
        event_store=None,
        json_response=False,
        stateless=True,
    )

    @asynccontextmanager
    async def lifespan(_app):
        async with session_manager.run():
            yield

    tool_count = _get_registry().tool_count

    async def health_endpoint(scope, receive, send):
        if scope.get("method") == "GET":
            body = b'{"status":"ok","service":"mcp-gateway","tools":' + str(tool_count).encode() + b'}'
            await send({
                "type": "http.response.start",
                "status": 200,
                "headers": [[b"content-type", b"application/json"]],
            })
            await send({"type": "http.response.body", "body": body})

    starlette_app = Starlette(
        routes=[
            Mount("/health", app=health_endpoint),
            Mount("/", app=session_manager.handle_request),
        ],
        lifespan=lifespan,
    )
    starlette_app = MCPAuthMiddleware(starlette_app, auth_token)

    logger.info("Starting Streamable HTTP MCP gateway on %s:%d", host, port)
    config = uvicorn.Config(starlette_app, host=host, port=port, log_level="info")
    server = uvicorn.Server(config)
    await server.serve()
