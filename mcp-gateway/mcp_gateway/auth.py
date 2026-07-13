"""Authentication strategies for backend services."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Optional

import requests
from requests.auth import HTTPBasicAuth


class AuthType(Enum):
    """Supported authentication methods for backend services."""

    NONE = "none"
    API_KEY = "api_key"
    BEARER = "bearer"
    BASIC = "basic"


@dataclass
class AuthConfig:
    """Authentication configuration for a backend service.

    Secrets are resolved from environment variables at startup and
    injected here — the YAML config file never contains raw secrets.
    """

    type: AuthType = AuthType.NONE
    key: str = "X-API-Key"  # header name for api_key type
    value: Optional[str] = None  # secret value (resolved from env)
    username: Optional[str] = None  # for basic auth
    password: Optional[str] = None  # for basic auth

    @classmethod
    def from_dict(cls, data: dict) -> "AuthConfig":
        """Build AuthConfig from a parsed YAML dict (post env resolution)."""
        raw_type = data.get("type", "none")
        try:
            auth_type = AuthType(raw_type)
        except ValueError:
            raise ValueError(f"Unsupported auth type: {raw_type!r}")

        return cls(
            type=auth_type,
            key=data.get("key", "X-API-Key"),
            value=data.get("value"),
            username=data.get("username"),
            password=data.get("password"),
        )


def apply_headers(config: AuthConfig) -> dict[str, str]:
    """Return HTTP headers required by the given auth config.

    For ``basic`` auth this returns empty headers — the auth is applied
    via the ``requests`` ``auth=`` parameter instead.
    """
    if config.type == AuthType.API_KEY and config.value:
        return {config.key: config.value}
    if config.type == AuthType.BEARER and config.value:
        return {"Authorization": f"Bearer {config.value}"}
    return {}


def get_auth(config: AuthConfig) -> Optional[requests.auth.AuthBase]:
    """Return a ``requests`` auth object, or ``None``.

    Only meaningful for ``basic`` auth; other types use headers only.
    """
    if config.type == AuthType.BASIC and config.username and config.password:
        return HTTPBasicAuth(config.username, config.password)
    return None
