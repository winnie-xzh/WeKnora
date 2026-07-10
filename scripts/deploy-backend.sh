#!/usr/bin/env bash
# 清除代理环境变量（Mac 上 Surge/Clash 会干扰 ACR 连接）
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
#
# !!! CROSS-PLATFORM BUILD NOTICE !!!
# Mac（arm64）构建的镜像推送到 x86_64 服务器跑不了 → exec format error。
# 所以必须加 --platform=linux/amd64 交叉编译。
#
# WeKnora 后端一键部署脚本
#
# 用法
#   ./scripts/deploy-backend.sh
#
# 基于 scripts/deploy-aliyun.sh 精简，只部署 app（后端）服务
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
NO_CACHE="${NO_CACHE:-}"
PLATFORM="linux/amd64"

echo "=== Step 1: 提交代码到 GitHub ==="
cd "$(dirname "$0")/.."
git add -A
git status --short
read -p "Commit message [auto deploy]: " msg
git commit -m "${msg:-auto deploy: $(date +%F)}"
git push fork main
echo "--- 提交完成 ---"

echo "=== Step 2: 构建并推送 app 镜像到 ACR ==="

# 获取 ACR 临时 Token
ACR_TOKEN=$(aliyun cr GetAuthorizationToken --InstanceId cri-j5gbox3b9osyqjxy --RegionId cn-guangzhou 2>&1 | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d['AuthorizationToken'])
")

# 登录 ACR
echo "登录 ACR..."
echo "$ACR_TOKEN" | docker login --username=cr_temp_user --password-stdin "$ACR_REGISTRY" 2>&1

# 构建后端 app 镜像
echo "构建 app 镜像（后台，可查看日志: tail -f /tmp/build-app.log）..."
docker build $NO_CACHE --platform=$PLATFORM -t weknora-app:latest \
  -f docker/Dockerfile.app \
  --build-arg GOPROXY_ARG=https://goproxy.cn,direct \
  . > /tmp/build-app.log 2>&1 &
APP_PID=$!

# 等待 app 构建完成 — 用 PID 判断，不用 docker images
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

# 推送 app 到 ACR
docker tag weknora-app:latest "$ACR_REGISTRY/$ACR_NAMESPACE/app:latest"
docker push "$ACR_REGISTRY/$ACR_NAMESPACE/app:latest" 2>&1 | tail -3
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

echo '--- 拉取最新 app 镜像 ---'
cd /root/WeKnora-new
docker compose -p weknora pull app 2>&1 | tail -5

echo '--- 重启 app 服务 ---'
docker compose -p weknora rm -fs app 2>/dev/null || true
docker compose -p weknora up -d app --no-deps

echo '=== 部署完成 ==='
sleep 3
docker compose -p weknora ps --format 'table {{.Name}}\t{{.Image}}\t{{.Status}}'
echo ''
curl -s http://localhost:8080/health
"

echo ""
echo "=== 全部完成 ==="
echo ""
echo "后端已部署到服务器"
echo ""
echo "全量部署（含前端）请使用："
echo "  ./scripts/deploy-aliyun.sh"
