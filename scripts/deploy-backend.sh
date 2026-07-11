#!/usr/bin/env bash
#
# WeKnora 后端一键部署脚本
#
# 思路：在 Mac 上只提交代码，服务器上原生构建，
#       避免 Mac arm64 → 服务器 x86_64 架构问题。
#
# 用法
#   ./scripts/deploy-backend.sh                          # 默认 quick 模式（热替换，~15-20s）
#   ./scripts/deploy-backend.sh --docker                  # Docker 构建 + 推 ACR + 重启
#   ./scripts/deploy-backend.sh --docker --no-cache       # 强制重构建
#   ./scripts/deploy-backend.sh --docreader               # 同时部署 docreader（极少变动）
#   WEKNORA_VERSION=v1.2.3 ./scripts/deploy-backend.sh    # 有版本标签时自动走 Docker 模式
#
# 环境变量（详见 scripts/deploy-common.sh）
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

# ── 解析参数 ──
DEPLOY_DOCREADER=false
DOCKER_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --docker)        DOCKER_MODE=true; shift ;;
        --no-cache)      NO_CACHE="--no-cache"; shift ;;
        --docreader)     DEPLOY_DOCREADER=true; shift ;;
        *) echo "用法: $0 [--docker] [--no-cache] [--docreader]"; exit 1 ;;
    esac
done

cd "$(dirname "$0")/.."

# ── 模式选择 ──
# 规则：有版本标签（非 latest）或显式 --docker 时走 Docker 模式，否则默认 quick 模式
if [[ "$WEKNORA_VERSION" != "latest" && -n "${WEKNORA_VERSION:-}" ]]; then
    DOCKER_MODE=true
fi

SERVICES=("app")
if $DEPLOY_DOCREADER; then SERVICES+=("docreader"); fi

echo "=== WeKnora 后端部署 ==="
echo "  服务:     ${SERVICES[*]}"
echo "  版本:     ${WEKNORA_VERSION}"
echo "  ACR:      ${ACR_REGISTRY}/${ACR_NAMESPACE}"
echo "  服务器:   ${SSH_HOST}"
echo "  仓库路径: ${REMOTE_REPO_PATH}"
if $DOCKER_MODE; then
    echo "  模式:     docker（构建 + 推送 ACR + 重启）"
else
    echo "  模式:     quick（热替换二进制，不推 ACR）"
fi
[ -n "$NO_CACHE" ] && echo "  重构建:   是"
echo ""

# ── Docker 模式需要 ACR 认证 ──
if $DOCKER_MODE; then
    acr_auth
fi

_tick

# ═══════════════════════════════════════════════════════
# 远程脚本：拉取最新代码
# ═══════════════════════════════════════════════════════
GIT_SCRIPT='
echo "--- 拉取最新代码 ---"
git fetch origin main
LOCAL_HASH=$(git rev-parse HEAD)
REMOTE_HASH=$(git rev-parse origin/main)
if [ "$LOCAL_HASH" = "$REMOTE_HASH" ]; then
    echo "代码已是最新 (${LOCAL_HASH:0:8})，跳过拉取"
else
    echo "更新: ${LOCAL_HASH:0:8} → ${REMOTE_HASH:0:8}"
    git pull origin main
fi
echo "--- 最新提交 ---"
git log --oneline -3
'

if ! $DOCKER_MODE; then
    # ── 快速模式（默认）：Docker 编译 → 提取二进制 → 热替换 ──
    REMOTE_SCRIPT=$(cat << ENDSSH
set -euo pipefail
cd ${REMOTE_REPO_PATH}
${GIT_SCRIPT}

echo ""
echo "--- [quick] Docker 编译（builder 阶段，跳过 final 镜像）---"
docker buildx build \
  --target=builder \
  --output type=local,dest=.build-out \
  -f docker/Dockerfile.app \
  --build-arg APK_MIRROR_ARG=mirrors.aliyun.com \
  --build-arg GOPROXY_ARG=https://goproxy.cn,direct \
  .
echo "编译完成"

echo "--- [quick] 提取二进制 ---"
cp .build-out/app/WeKnora ./WeKnora
rm -rf .build-out

echo "--- [quick] 查找 app 容器 ---"
CID=\$(docker compose -p weknora ps -q app)
if [ -z "\$CID" ]; then
    echo "错误: app 容器未运行"
    exit 1
fi

echo "--- [quick] 热替换二进制 ---"
docker cp ./WeKnora \$CID:/app/WeKnora
echo "--- [quick] 重启 app ---"
docker compose -p weknora restart app

echo ""
echo "=== 部署完成 ==="
echo "--- 健康检查 ---"
for i in \$(seq 1 30); do
    if curl -sf http://localhost:8080/health; then echo ""; echo "app 已就绪"; break; fi
    [ \$i -eq 30 ] && echo "FAILED (超时)" || sleep 1
done
ENDSSH
    )

else
    # ── Docker 模式：Docker 构建 → 推送 ACR → 重启 ──
    BUILD_ARGS=""
    [ -n "$NO_CACHE" ] && BUILD_ARGS="--no-cache"
    SERVICES_STR=$(IFS=' '; echo "${SERVICES[*]}")

    REMOTE_SCRIPT=$(cat << ENDSSH
set -euo pipefail
cd ${REMOTE_REPO_PATH}
${GIT_SCRIPT}

echo ""
echo '--- 登录 ACR ---'
echo '${ACR_AUTH_PASS}' | docker login --username='${ACR_AUTH_USER}' --password-stdin ${ACR_REGISTRY} 2>&1

echo ""
echo '--- 构建镜像（服务器原生编译）---'
APK_MIRROR_ARG=mirrors.aliyun.com GOPROXY_ARG=https://goproxy.cn,direct docker compose -p weknora build ${BUILD_ARGS} ${SERVICES_STR}
echo '构建完成'

echo ""
echo '--- 推送镜像到 ACR ---'
for svc in ${SERVICES_STR}; do
    echo "推送 \$svc..."
    docker compose -p weknora push \$svc
done

echo ""
echo '--- 重启服务 ---'
for svc in ${SERVICES_STR}; do
    docker compose -p weknora rm -fs \$svc 2>/dev/null || true
done
docker compose -p weknora up -d ${SERVICES_STR} --no-deps

echo ""
echo '=== 部署完成 ==='
echo '--- 服务状态 ---'
docker compose -p weknora ps --format 'table {{.Name}}\t{{.Image}}\t{{.Status}}'

echo ""
echo '--- 健康检查（等待就绪，最多 30s）---'
for i in \$(seq 1 30); do
    if curl -sf http://localhost:8080/health; then echo ""; echo "app 已就绪"; break; fi
    [ \$i -eq 30 ] && echo "FAILED (超时)" || sleep 1
done
ENDSSH
    )
fi

ssh -i "$SSH_KEY" $SSH_OPTS "$SSH_HOST" "$REMOTE_SCRIPT"
_tick

# ── 汇总 ──
SERVICES_STR=$(IFS=' '; echo "${SERVICES[*]}")
echo ""
echo "=== 全部完成 ==="
ELAPSED=$(( $(date +%s) - START_TIME ))
printf "⏱ 总耗时: %dm%02ds\n" $((ELAPSED / 60)) $((ELAPSED % 60))
echo "部署版本: ${WEKNORA_VERSION}"
echo "服务:     ${SERVICES_STR}"
