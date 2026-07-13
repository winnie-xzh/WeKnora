#!/usr/bin/env python3
"""
MCP Gateway Server — 主入口点

集中式 MCP 网关，对接多个异构业务系统（Java、.NET 等），将 MCP 工具调用
翻译为 REST API 请求。

环境变量:
  MCP_GATEWAY_CONFIG      YAML 配置文件路径（默认: config/gateway.yaml）
  MCP_GATEWAY_AUTH_TOKEN  SSE/HTTP 传输的认证令牌
  MCP_TRANSPORT           传输方式: stdio / sse / http
  MCP_HOST                网络传输绑定地址
  MCP_PORT                网络传输绑定端口
"""

import argparse
import asyncio
import logging
import os
import sys
from pathlib import Path


def setup_environment():
    """Ensure the package directory is in the Python path."""
    current_dir = Path(__file__).parent.absolute()
    if str(current_dir) not in sys.path:
        sys.path.insert(0, str(current_dir))


def check_dependencies():
    """Check that key dependencies are installed."""
    try:
        import mcp  # noqa: F401
        import requests  # noqa: F401
        import yaml  # noqa: F401
        return True
    except ImportError as e:
        print(f"Missing dependency: {e}")
        print("Run: pip install -r requirements.txt")
        return False


def parse_arguments():
    """Parse CLI arguments."""
    parser = argparse.ArgumentParser(
        description="MCP Gateway - Centralized enterprise business system gateway",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--transport",
        choices=["stdio", "sse", "http"],
        default=os.getenv("MCP_TRANSPORT", "stdio"),
        help="Transport type (default: stdio)",
    )
    parser.add_argument(
        "--host",
        default=os.getenv("MCP_HOST", "127.0.0.1"),
        help="Bind host for network transports",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.getenv("MCP_PORT", "8000")),
        help="Bind port for network transports",
    )
    parser.add_argument(
        "--config",
        default="",
        help="Path to gateway YAML config (default: config/gateway.yaml)",
    )
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Only check configuration, do not start server",
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true", help="Enable verbose logging"
    )
    return parser.parse_args()


async def async_main():
    """Main async entry point."""
    args = parse_arguments()
    setup_environment()

    if not check_dependencies():
        sys.exit(1)

    log_level = logging.DEBUG if args.verbose else logging.INFO
    logging.basicConfig(
        level=log_level,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    if args.config:
        os.environ["MCP_GATEWAY_CONFIG"] = args.config

    # import after path setup
    from mcp_gateway.gateway_server import preload, run_stdio, run_sse, run_http

    # pre-load registry to fail fast on config errors
    try:
        preload()
    except Exception as e:
        logger = logging.getLogger(__name__)
        logger.error("Failed to load gateway config: %s", e)
        sys.exit(1)

    if args.check_only:
        print("Configuration OK.")
        return

    if args.transport == "stdio":
        await run_stdio()
    elif args.transport == "sse":
        await run_sse(args.host, args.port)
    elif args.transport == "http":
        await run_http(args.host, args.port)


def sync_main():
    """Synchronous wrapper for entry_points."""
    asyncio.run(async_main())


if __name__ == "__main__":
    sync_main()
