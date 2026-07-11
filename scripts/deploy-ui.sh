#!/usr/bin/env bash
#
# WeKnora 前端一键部署脚本
#
# 用法
#   ./scripts/deploy-ui.sh
#   WEKNORA_VERSION=v1.2.3 ./scripts/deploy-ui.sh  # 指定版本标签
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

echo "=== WeKnora 前端部署 ==="
echo "  版本:     ${WEKNORA_VERSION}"
echo "  ACR:      ${ACR_REGISTRY}/${ACR_NAMESPACE}"
echo "  服务器:   ${SSH_HOST}"
echo ""

# ── ACR 认证 ──
acr_auth

# ── Step 1: 本地构建并推送 ──
echo "=== Step 1: 构建并推送前端镜像 ==="

acr_login
_tick

echo "编译前端静态资源..."
VITE_IS_DOCKER=true ./scripts/build_frontend_dist.sh > /tmp/build-ui.log 2>&1
_tick

echo "构建 Docker 镜像..."
docker build --platform=linux/amd64 \
    -t "weknora-ui:${WEKNORA_VERSION}" \
    -f frontend/Dockerfile frontend/ > /dev/null 2>&1
_tick

echo "推送镜像到 ACR..."
docker tag "weknora-ui:${WEKNORA_VERSION}" "$(image_full_name ui)"
docker push "$(image_full_name ui)" 2>&1 | grep 'digest:'
_tick

# ── Step 2: 服务器拉取并重启 ──
echo ""
echo "=== Step 2: 服务器部署 ==="

REMOTE_SCRIPT=$(cat << ENDSSH
set -euo pipefail

cd ${REMOTE_REPO_PATH}

echo '--- 登录 ACR ---'
echo '${ACR_AUTH_PASS}' | docker login --username='${ACR_AUTH_USER}' --password-stdin ${ACR_REGISTRY} 2>&1

echo '--- 从 ACR 拉取前端镜像 ---'
ACR_IMAGE="${ACR_REGISTRY}/${ACR_NAMESPACE}/ui:${WEKNORA_VERSION}"
docker pull \$ACR_IMAGE

echo '--- 标记为 compose 镜像名 ---'
docker tag \$ACR_IMAGE "wechatopenai/weknora-ui:${WEKNORA_VERSION}"

echo '--- 重启前端服务 ---'
docker compose -p weknora rm -fs frontend 2>/dev/null || true
FRONTEND_PORT=8081 WEKNORA_VERSION='${WEKNORA_VERSION}' docker compose -p weknora up -d frontend --no-deps

echo '=== 部署完成 ==='
docker compose -p weknora ps --format 'table {{.Name}}\t{{.Image}}\t{{.Status}}'
echo ''
curl -s http://localhost:8081/ | grep -o '<title>.*</title>' || echo '(页面检查跳过)'
ENDSSH
)

ssh -i "$SSH_KEY" $SSH_OPTS "$SSH_HOST" "$REMOTE_SCRIPT"
_tick

echo ""
echo "=== 全部完成 ==="
ELAPSED=$(( $(date +%s) - START_TIME ))
printf "⏱ 总耗时: %dm%02ds\n" $((ELAPSED / 60)) $((ELAPSED % 60))
echo "部署版本: ${WEKNORA_VERSION}"
