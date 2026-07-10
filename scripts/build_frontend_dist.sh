#!/usr/bin/env bash
# Build frontend static assets for Docker / release packaging.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -z "${VITE_FRONTEND_COMMIT:-}" ]; then
	# shellcheck source=/dev/null
	eval "$("$PROJECT_ROOT/scripts/get_version.sh" env)"
	export VITE_FRONTEND_COMMIT="${COMMIT_ID:-unknown}"
fi

export VITE_IS_DOCKER="${VITE_IS_DOCKER:-true}"

cd "$PROJECT_ROOT/frontend"
if [ -d "node_modules" ] && [ "node_modules" -nt "package-lock.json" ]; then
  echo "  → 依赖已安装，跳过 npm ci"
else
  npm ci
fi
npm run build
