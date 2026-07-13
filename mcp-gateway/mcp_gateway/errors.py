"""Structured error types for the MCP gateway."""


class GatewayError(Exception):
    """Base error for all gateway-level failures."""

    def __init__(self, message: str, *, is_error: bool = True):
        self.is_error = is_error
        super().__init__(message)


class ToolNotFoundError(GatewayError):
    """Raised when a requested tool name is not registered."""

    def __init__(self, name: str, known_tools: list[str]):
        tools_summary = ", ".join(sorted(known_tools))
        super().__init__(
            f"Unknown tool: {name!r}. Available tools: [{tools_summary}]"
        )


class BackendUnavailableError(GatewayError):
    """Raised when a backend service is unreachable."""

    def __init__(self, service_name: str, base_url: str, reason: str):
        super().__init__(
            f"Backend service {service_name!r} is unreachable at {base_url}: {reason}"
        )


class BackendHTTPError(GatewayError):
    """Raised when a backend returns a non-2xx HTTP status."""

    def __init__(self, service_name: str, status: int, body: str):
        super().__init__(
            f"Backend service {service_name!r} returned HTTP {status}: {body[:500]}"
        )


class BackendTimeoutError(GatewayError):
    """Raised when a backend request times out."""

    def __init__(self, service_name: str, timeout: int):
        super().__init__(
            f"Backend service {service_name!r} did not respond within {timeout}s"
        )


class ConfigError(GatewayError):
    """Raised when the gateway configuration is invalid."""

    pass


def format_error(e: Exception) -> str:
    """Format an exception into an LLM-friendly error string."""
    if isinstance(e, GatewayError):
        return str(e)
    return f"Unexpected error: {e}"
