#!/usr/bin/env bash
# 清除代理环境变量（Mac 上 Surge/Clash 会干扰 ACR 连接）
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
#
# !!! CROSS-PLATFORM BUILD NOTICE !!!
# Mac（arm64）构建的镜像推送到 x86_64 服务器跑不了 → exec format error。
# 所以必须加 --platform=linux/amd64 交叉编译。
#
# WeKnora 阿里云 ECS 一键部署脚本
#
# 用法
#   ./scripts/deploy-aliyun.sh               # 快速部署（app + frontend）
#   ./scripts/deploy-aliyun.sh --no-cache     # 强制重构建，不用缓存
#   ./scripts/deploy-aliyun.sh --full         # 全量部署（含 docreader）
#
# 前置条件：
#   1. git 已推送到 fork（winnie-xzh/WeKnora）
#   2. .env 已备份到 /root/.env.weknora.bak
#   3. SSH 密钥路径正确
#   4. ACR 已配置（公网端点、命名空间、仓库已创建）
#
set -euo pipefail

SSH_KEY="/Users/winnie/Documents/惠民卡资料/gxlyykt.pem"
HOST="root@8.134.215.118"
SSH_OPTS="-o ServerAliveInterval=30 -o ServerAliveCountMax=3"
ACR_REGISTRY="gz3-registry.cn-guangzhou.cr.aliyuncs.com"
ACR_NAMESPACE="weknora"
FULL_DEPLOY=false
NO_CACHE=""
PLATFORM="linux/amd64"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full) FULL_DEPLOY=true; shift ;;
    --no-cache) NO_CACHE="--no-cache"; shift ;;
    *) echo "用法: $0 [--full|--no-cache]"; exit 1 ;;
  esac
done

echo "=== Step 1: 提交代码到 GitHub ==="
cd "$(dirname "$0")/.."
git add -A
git status --short
read -p "Commit message [auto deploy]: " msg
git commit -m "${msg:-auto deploy: $(date +%F)}"
git push fork main
echo "--- 提交完成 ---"

echo "=== Step 2: 构建并推送到 ACR ==="

# 获取 ACR 临时 Token
ACR_TOKEN=$(aliyun cr GetAuthorizationToken --InstanceId cri-j5gbox3b9osyqjxy --RegionId cn-guangzhou 2>&1 | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d['AuthorizationToken'])
")

# 登录 ACR
echo "登录 ACR..."
echo "$ACR_TOKEN" | docker login --username=cr_temp_user --password-stdin "$ACR_REGISTRY" 2>&1

# 构建前端（必须指定 platform 为 amd64，服务器是 x86_64）
VITE_IS_DOCKER=true ./scripts/build_frontend_dist.sh 2>&1 | grep -E 'built in|error'
docker build $NO_CACHE --platform=$PLATFORM -t weknora-ui:latest -f frontend/Dockerfile frontend/

# 构建 app（同上，后台构建以节省时间）
echo "构建 app 镜像（后台，可查看日志: tail -f /tmp/build-app.log）..."
docker build $NO_CACHE --platform=$PLATFORM -t weknora-app:latest \
  -f docker/Dockerfile.app \
  --build-arg GOPROXY_ARG=https://goproxy.cn,direct \
  . > /tmp/build-app.log 2>&1 &
APP_PID=$!

# 先推送前端（app 还在后台构建）
docker tag weknora-ui:latest "$ACR_REGISTRY/$ACR_NAMESPACE/ui:latest"
docker push "$ACR_REGISTRY/$ACR_NAMESPACE/ui:latest" 2>&1 | tail -3
echo "--- ui 镜像已推送到 ACR ---"
# 同时推一个显式的架构 tag，便于回滚
docker tag weknora-ui:latest "$ACR_REGISTRY/$ACR_NAMESPACE/ui:amd64"
docker push "$ACR_REGISTRY/$ACR_NAMESPACE/ui:amd64" 2>&1 | tail -1

# 等待 app 构建完成
# BUGFIX: 用 wait $APP_PID 判断进程是否结束，而不是 docker images
# （旧镜像会干扰判断：上次构建的 weknora-app:latest 还在，直接返回 true）
echo "等待 app 构建..."
APP_BUILD_OK=false
for i in $(seq 1 80); do
  if ! kill -0 $APP_PID 2>/dev/null; then
    if wait $APP_PID 2>/dev/null; then
      echo "app 镜像构建完成"
      APP_BUILD_OK=true
    else
      echo "app 镜像构建失败！最后 20 行日志："
      tail -20 /tmp/build-app.log
    fi
    break
  fi
  sleep 15
done

if [ "$APP_BUILD_OK" != "true" ]; then
  echo "app 构建失败，查看日志: tail -f /tmp/build-app.log"
  exit 1
fi

# 推送 app
docker tag weknora-app:latest "$ACR_REGISTRY/$ACR_NAMESPACE/app:latest"
docker push "$ACR_REGISTRY/$ACR_NAMESPACE/app:latest" 2>&1 | tail -3
docker tag weknora-app:latest "$ACR_REGISTRY/$ACR_NAMESPACE/app:amd64"
docker push "$ACR_REGISTRY/$ACR_NAMESPACE/app:amd64" 2>&1 | tail -1
echo "--- app 镜像已推送到 ACR ---"

echo "=== Step 3: 服务器部署 ==="

# 获取新的临时 Token（旧的可能已过期）
ACR_TOKEN=$(aliyun cr GetAuthorizationToken --InstanceId cri-j5gbox3b9osyqjxy --RegionId cn-guangzhou 2>&1 | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d['AuthorizationToken'])
")

ssh -i $SSH_KEY $SSH_OPTS $HOST "
set -euo pipefail

echo '--- 登录 ACR ---'
echo '$ACR_TOKEN' | docker login --username=cr_temp_user --password-stdin $ACR_REGISTRY 2>&1

echo '--- 拉取最新镜像 ---'
cd /root/WeKnora-new
docker compose -p weknora pull app frontend 2>&1 | tail -10

echo '--- 重启服务 ---'
# BUGFIX: 用 rm -fs 替代 stop+rm，确保容器被完全移除
# 否则容器可能复用之前的 arm64 层
docker compose -p weknora rm -fs app frontend 2>/dev/null || true
FRONTEND_PORT=8081 docker compose -p weknora up -d app frontend --no-deps

echo '=== 部署完成 ==='
sleep 3
docker compose -p weknora ps --format 'table {{.Name}}\t{{.Image}}\t{{.Status}}'
echo ''
curl -s http://localhost:8080/health
echo ''
curl -s http://localhost:8081/ | grep -o '<title>.*</title>'
"

echo ""
echo "=== 全部完成 ==="
echo ""
echo "快速部署（只更新 app + frontend）："
echo "  ./scripts/deploy-aliyun.sh"
echo ""
echo "强制重构建（不使用 Docker 缓存）："
echo "  ./scripts/deploy-aliyun.sh --no-cache"
echo ""
echo "全量部署（含 docreader）："
echo "  ./scripts/deploy-aliyun.sh --full"
