#!/usr/bin/env bash
#
# MCP 网关一键部署脚本
#
# 构建 mcp-gateway Docker 镜像 → 推送到 ACR → 服务器拉取并重启
#
# 用法
#   ./scripts/deploy-mcp-gateway.sh                      # 构建 + 推送 + 部署
#   ./scripts/deploy-mcp-gateway.sh --no-cache            # 强制重构建
#   WEKNORA_VERSION=v1.2.3 ./scripts/deploy-mcp-gateway.sh  # 指定版本标签
#
# 环境变量（同 deploy-backend.sh，详见 scripts/deploy-common.sh）
#
# 前置条件：
#   - SSH 密钥可连接服务器
#   - ACR 已配置（公网端点、命名空间、仓库已创建）
#   - （可选）scripts/.acr-cred 永久凭证，免 aliyun CLI 调用
#
set -euo pipefail

START_TIME=$(date +%s)

# ── 定位脚本目录并加载公共库 ──
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/deploy-common.sh"

cd "$(dirname "$0")/.."

# ── 解析参数 ──
NO_CACHE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-cache)      NO_CACHE="--no-cache"; shift ;;
        *) echo "用法: $0 [--no-cache]"; exit 1 ;;
    esac
done

echo "=== MCP 网关部署 ==="
echo "  版本:     ${WEKNORA_VERSION}"
echo "  ACR:      ${ACR_REGISTRY}/${ACR_NAMESPACE}"
echo "  服务器:   ${SSH_HOST}"
echo "  源路径:   mcp-gateway/"
[ -n "$NO_CACHE" ] && echo "  重构建:   是"
echo ""

# ── ACR 认证 ──
acr_auth
_tick

# ── Step 1: 本地构建并推送 ──
echo "=== Step 1: 构建并推送 mcp-gateway 镜像 ==="

acr_login
_tick

SERVICE_NAME="mcp-gateway"
IMAGE_TAG="weknora-${SERVICE_NAME}:${WEKNORA_VERSION}"
ACR_FULL_IMAGE="${ACR_REGISTRY}/${ACR_NAMESPACE}/${SERVICE_NAME}:${WEKNORA_VERSION}"

BUILD_ARGS=""
[ -n "$NO_CACHE" ] && BUILD_ARGS="--no-cache"

echo "构建 Docker 镜像..."
# shellcheck disable=SC2086
docker build $BUILD_ARGS \
    --platform=linux/amd64 \
    -t "${IMAGE_TAG}" \
    -f mcp-gateway/Dockerfile mcp-gateway/ > /dev/null 2>&1
_tick

echo "推送镜像到 ACR..."
docker tag "${IMAGE_TAG}" "${ACR_FULL_IMAGE}"
docker push "${ACR_FULL_IMAGE}" 2>&1 | grep 'digest:'
_tick

# ── Step 2: 服务器拉取并重启 ──
echo ""
echo "=== Step 2: 服务器部署 ==="

REMOTE_SCRIPT=$(cat << ENDSSH
set -euo pipefail

cd ${REMOTE_REPO_PATH}

echo '--- 登录 ACR ---'
echo '${ACR_AUTH_PASS}' | docker login --username='${ACR_AUTH_USER}' --password-stdin ${ACR_REGISTRY} 2>&1

echo '--- 从 ACR 拉取 mcp-gateway 镜像 ---'
docker pull ${ACR_FULL_IMAGE}

echo '--- 标记为 compose 镜像名 ---'
docker tag ${ACR_FULL_IMAGE} ${IMAGE_TAG}

echo '--- 拉取最新代码（确保 docker-compose.yml 中有 mcp-gateway 服务定义）---'
git fetch origin main
LOCAL_HASH=\$(git rev-parse HEAD)
REMOTE_HASH=\$(git rev-parse origin/main)
if [ "\$LOCAL_HASH" != "\$REMOTE_HASH" ]; then
    echo "更新: \${LOCAL_HASH:0:8} → \${REMOTE_HASH:0:8}"
    git pull origin main
fi

echo '--- 重启 mcp-gateway 服务 ---'
docker compose -p weknora rm -fs ${SERVICE_NAME} 2>/dev/null || true

# 加载网关后端服务的环境变量（如果存在）
ENV_FILE="${REMOTE_REPO_PATH}/.env"
if [ -f "\$ENV_FILE" ]; then
    set -a
    source "\$ENV_FILE"
    set +a
fi

docker compose -p weknora up -d ${SERVICE_NAME} --no-deps

echo ''
echo '=== 部署完成 ==='
docker compose -p weknora ps --format 'table {{.Name}}\t{{.Image}}\t{{.Status}}' | grep -E "mcp-gateway|Name"

echo ''
echo '--- 健康检查（等待就绪，最多 15s）---'
for i in \$(seq 1 15); do
    if curl -sf http://localhost:${MCP_GATEWAY_PORT:-8083}/health 2>/dev/null; then
        echo ""
        echo "mcp-gateway 已就绪"
        break
    fi
    [ \$i -eq 15 ] && echo "FAILED (超时)" || sleep 1
done
ENDSSH
)

ssh -i "$SSH_KEY" $SSH_OPTS "$SSH_HOST" "$REMOTE_SCRIPT"
_tick

# ── 汇总 ──
echo ""
echo "=== 全部完成 ==="
ELAPSED=$(( $(date +%s) - START_TIME ))
printf "⏱ 总耗时: %dm%02ds\n" $((ELAPSED / 60)) $((ELAPSED % 60))
echo "部署版本: ${WEKNORA_VERSION}"
echo "服务:     mcp-gateway"
