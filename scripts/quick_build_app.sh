#!/usr/bin/env bash
# Quick-rebuild the WeKnora app binary and hot-replace it in the running container.
# This skips the final production stage (Debian packages), only compiling Go code.
#
# Usage: ./scripts/quick_build_app.sh [--no-cache]
#
# Prerequisites:
#   docker compose up -d app        (app container must be running)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTAINER="WeKnora-app"

cd "$PROJECT_ROOT"

echo "==> 1/4 Building Go binary (builder stage only, skipping final stage)..."
CACHE=""
if [ "${1:-}" = "--no-cache" ]; then
  CACHE="--no-cache"
fi

docker build $CACHE \
  --platform linux/arm64 \
  --target builder \
  -f docker/Dockerfile.app \
  -t weknora-builder:latest .

echo "==> 2/4 Extracting binary from builder image..."
docker rm -f tmp-weknora-builder 2>/dev/null || true
docker create --name tmp-weknora-builder weknora-builder:latest
docker cp tmp-weknora-builder:/app/WeKnora /tmp/WeKnora.new
docker rm tmp-weknora-builder

echo "==> 3/4 Copying binary into running container..."
docker cp /tmp/WeKnora.new "$CONTAINER":/app/WeKnora

echo "==> 4/4 Restarting container..."
docker compose restart app

echo "==> Done. Binary rebuilt and container restarted."
