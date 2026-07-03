#!/bin/bash
# 重新生成 WeKnora 项目地图
# 用法: ./scripts/regenerate-map.sh

set -e
cd "$(dirname "$0")/.."

echo "Regenerating project map..."
echo ""

# Set up caches
GOCACHE=$(mktemp -d)
GOMODCACHE=$(mktemp -d)
export GOCACHE GOMODCACHE

# Generate compact JSON + pretty JSON
go run scripts/codex-map/main.go -root . -output /private/tmp/project-map.json

# Generate markdown overview
go run scripts/codex-map/main.go -root . -format markdown \
  -output /Users/winnie/WeKnora/.codex-map-overview.md

echo ""
echo "Done! Map files:"
echo "  /private/tmp/project-map.json        (compact JSON, for queries)"
echo "  /private/tmp/project-map.pretty.json (pretty JSON, for reading)"
echo "  .codex-map-overview.md               (Markdown overview)"
echo ""
echo "Query tool: python3 scripts/map_query.py <command>"
echo "  Examples:"
echo "    python3 scripts/map_query.py stats"
echo "    python3 scripts/map_query.py symbol ChatService"
echo "    python3 scripts/map_query.py pkg handler"
