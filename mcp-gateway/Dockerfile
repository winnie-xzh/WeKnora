FROM python:3.11-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
RUN pip install --no-cache-dir -e .

ENV MCP_HOST=0.0.0.0
ENV MCP_PORT=8000
# Set MCP_GATEWAY_AUTH_TOKEN at runtime; HTTP transport refuses to start without it.

EXPOSE 8000

CMD ["mcp-gateway", "--transport", "http", "--host", "0.0.0.0", "--port", "8000"]
