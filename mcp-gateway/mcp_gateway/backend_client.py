"""HTTP client that translates MCP tool calls into REST API requests."""

from __future__ import annotations

import json
import logging
import urllib.parse
from typing import Any

import requests

from mcp_gateway.auth import apply_headers, get_auth
from mcp_gateway.errors import BackendHTTPError, BackendTimeoutError, BackendUnavailableError
from mcp_gateway.registry import ParameterDef, ServiceConfig, ToolDef

logger = logging.getLogger(__name__)


def _build_url(base_url: str, path: str, args: dict, params: list[ParameterDef]) -> str:
    """Build the request URL by substituting path parameters and appending query string.

    Path parameters are replaced in the URL template ``{param_name}``.
    Query parameters are appended as ``?key=value``.
    """
    path_params = {p.name: args.get(p.name) for p in params if p.location == "path"}
    resolved_path = path
    for pname, pvalue in path_params.items():
        if pvalue is not None:
            encoded = urllib.parse.quote(str(pvalue), safe="")
            resolved_path = resolved_path.replace(f"{{{pname}}}", encoded)

    # collect query params
    query_parts: list[str] = []
    for p in params:
        if p.location == "query":
            val = args.get(p.name)
            if val is not None:
                query_parts.append(f"{urllib.parse.quote(p.name)}={urllib.parse.quote(str(val))}")

    url = f"{base_url}{resolved_path}"
    if query_parts:
        url = f"{url}?{'&'.join(query_parts)}"
    return url


def _build_headers(
    service: ServiceConfig, tool: ToolDef, args: dict
) -> dict[str, str]:
    """Build HTTP headers for the request.

    Includes auth headers and any header-type parameters.
    """
    headers: dict[str, str] = {"Content-Type": "application/json"}

    # auth
    headers.update(apply_headers(service.auth))

    # header-type parameters
    for p in tool.parameters:
        if p.location == "header" and p.name in args:
            headers[p.name] = str(args[p.name])

    return headers


def _build_body(tool: ToolDef, args: dict) -> Any:
    """Build the request body for POST/PUT/PATCH methods.

    Body parameters are those whose location is "body" and are present in args.
    """
    body_params = {
        p.name: args[p.name]
        for p in tool.parameters
        if p.location == "body" and p.name in args
    }
    return body_params if body_params else None


def execute_rest_call(
    service: ServiceConfig, tool: ToolDef, args: dict, session: requests.Session | None = None
) -> dict:
    """Execute a REST call against a backend service.

    Returns the parsed JSON response body.

    Raises:
        BackendUnavailableError: if the backend is unreachable.
        BackendHTTPError: if the backend returns a non-2xx status.
        BackendTimeoutError: if the request times out.
    """
    url = _build_url(service.base_url, tool.path, args, tool.parameters)
    headers = _build_headers(service, tool, args)
    body = _build_body(tool, args)

    close_session = False
    if session is None:
        session = requests.Session()
        close_session = True

    try:
        logger.info(
            "Calling backend %s: %s %s (timeout=%ds)",
            service.name,
            tool.method,
            url,
            service.timeout,
        )

        resp = session.request(
            method=tool.method,
            url=url,
            headers=headers,
            json=body,
            params=None,  # params are embedded in URL already
            timeout=service.timeout,
            auth=get_auth(service.auth),
        )

        if not resp.ok:
            body_text = resp.text[:500]
            logger.warning(
                "Backend %s returned HTTP %d: %s", service.name, resp.status_code, body_text
            )
            raise BackendHTTPError(service.name, resp.status_code, body_text)

        if not resp.content:
            return {"status": "ok"}

        # try JSON, fall back to text
        content_type = resp.headers.get("content-type", "")
        if "json" in content_type:
            return resp.json()
        return {"data": resp.text}

    except requests.ConnectionError as e:
        raise BackendUnavailableError(service.name, service.base_url, str(e))
    except requests.Timeout:
        raise BackendTimeoutError(service.name, service.timeout)
    finally:
        if close_session:
            session.close()
