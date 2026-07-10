#!/usr/bin/env bash
#
# WeKnora 后端一键部署脚本
#
# 思路：在 Mac 上只提交代码，服务器上原生构建，
#       避免 Mac arm64 → 服务器 x86_64 架构问题。
#
# 用法
#   ./scripts/deploy-backend.sh                         # 完整构建部署（Docker 镜像）
#   ./scripts/deploy-backend.sh --quick                  # 快速模式：直接编译 + 热替换，跳过 Docker
#   ./scripts/deploy-backend.sh --no-cache               # 强制重构建
#   ./scripts/deploy-backend.sh --docreader              # 同时部署 docreader（极少变动）
#   WEKNORA_VERSION=v1.2.3 ./scripts/deploy-backend.sh   # 指定版本标签（完整模式）
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
QUICK_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-cache)      NO_CACHE="--no-cache"; shift ;;
        --quick)         QUICK_MODE=true; shift ;;
        --docreader)     DEPLOY_DOCREADER=true; shift ;;
        *) echo "用法: $0 [--quick] [--no-cache] [--docreader]"; exit 1 ;;
    esac
done

cd "$(dirname "$0")/.."

# ── 构建服务列表 ──（docreader 不支持 quick 模式）
SERVICES=("app")
if $DEPLOY_DOCREADER; then SERVICES+=("docreader"); fi

echo "=== WeKnora 后端部署 ==="
echo "  服务:     ${SERVICES[*]}"
echo "  版本:     ${WEKNORA_VERSION}"
echo "  ACR:      ${ACR_REGISTRY}/${ACR_NAMESPACE}"
echo "  服务器:   ${SSH_HOST}"
echo "  仓库路径: ${REMOTE_REPO_PATH}"
$QUICK_MODE && echo "  模式:     quick（直接编译 + 热替换，不推 ACR）"
[ -n "$NO_CACHE" ] && echo "  重构建:   是"
echo ""

# ── ACR 认证（quick 模式不需要，但预先获取也无妨）──
if ! $QUICK_MODE; then
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

if $QUICK_MODE; then
    # ── 快速模式：服务器直接编译 Go，热替换二进制 ──
    REMOTE_SCRIPT=$(cat << ENDSSH
set -euo pipefail
cd ${REMOTE_REPO_PATH}
${GIT_SCRIPT}

echo ""
echo "--- [quick] 编译 Go 二进制（约 1-2 分钟）---"
make build-prod
echo "编译完成"

echo ""
echo "--- [quick] 查找 app 容器 ---"
CID=\$(docker compose -p weknora ps -q app)
if [ -z "\$CID" ]; then
    echo "错误: app 容器未运行"
    exit 1
fi
echo "容器 ID: \${CID:0:12}"

echo "--- [quick] 热替换二进制（~260MB）---"
docker cp ./WeKnora \$CID:/app/WeKnora
echo "--- [quick] 重启 app ---"
docker compose -p weknora restart app

echo ""
echo "=== 部署完成 ==="
echo "--- 健康检查（等待就绪，最多 60s）---"
for i in \$(seq 1 20); do
    if curl -sf http://localhost:8080/health; then echo ""; echo "app 已就绪"; break; fi
    [ \$i -eq 20 ] && echo "FAILED (超时)" || sleep 3
done
ENDSSH
    )

else
    # ── 完整模式：Docker 构建 → 推送 ACR → 重启 ──
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
docker compose -p weknora build ${BUILD_ARGS} ${SERVICES_STR}
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
echo '--- 健康检查（等待就绪，最多 60s）---'
for i in \$(seq 1 20); do
    if curl -sf http://localhost:8080/health; then echo ""; echo "app 已就绪"; break; fi
    [ \$i -eq 20 ] && echo "FAILED (超时)" || sleep 3
done
ENDSSH
    )
fi

ssh -i "$SSH_KEY" $SSH_OPTS "$SSH_HOST" "$REMOTE_SCRIPT"
_tick

# ── 汇总 ──
echo ""
echo "=== 全部完成 ==="
ELAPSED=$(( $(date +%s) - START_TIME ))
printf "⏱ 总耗时: %dm%02ds\n" $((ELAPSED / 60)) $((ELAPSED % 60))
echo "部署版本: ${WEKNORA_VERSION}"
echo "服务:     ${SERVICES_STR}"
