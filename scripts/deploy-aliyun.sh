#!/usr/bin/env bash
# WeKnora 阿里云 ECS 一键部署脚本
#
# 用法
#   ./scripts/deploy-aliyun.sh           # 只更新 app + frontend
#   ./scripts/deploy-aliyun.sh --full    # 全量更新（含 docreader）
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full) FULL_DEPLOY=true; shift ;;
    *) echo "用法: $0 [--full]"; exit 1 ;;
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

# 构建前端
VITE_IS_DOCKER=true ./scripts/build_frontend_dist.sh 2>&1 | grep -E 'built in|error'
docker build -t weknora-ui:latest -f frontend/Dockerfile frontend/

# 构建 app
echo "构建 app 镜像（后台，可查看日志: tail -f /tmp/build-app.log）..."
docker build -t weknora-app:latest \
  -f docker/Dockerfile.app \
  --build-arg GOPROXY_ARG=https://goproxy.cn,direct \
  . > /tmp/build-app.log 2>&1 &
APP_PID=$!

# 先推送前端（app 还在构建）
docker tag weknora-ui:latest "$ACR_REGISTRY/$ACR_NAMESPACE/ui:latest"
docker push "$ACR_REGISTRY/$ACR_NAMESPACE/ui:latest" 2>&1 | tail -3
echo "--- ui 镜像已推送到 ACR ---"

# 等待 app 构建完成
echo "等待 app 构建..."
for i in $(seq 1 80); do
  if docker images weknora-app:latest --format '{{.Repository}}' 2>/dev/null | grep -q .; then
    echo "app 镜像构建完成"
    break
  fi
  if ! kill -0 $APP_PID 2>/dev/null; then
    echo "构建进程已结束，最终日志："
    tail -5 /tmp/build-app.log
    break
  fi
  sleep 15
done

# 推送 app
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

echo '--- 拉取最新镜像 ---'
cd /root/WeKnora-new
docker compose -p weknora pull app frontend 2>&1 | tail -5

echo '--- 重启服务 ---'
docker stop WeKnora-app WeKnora-frontend 2>/dev/null || true
docker rm WeKnora-app WeKnora-frontend 2>/dev/null || true
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
echo "全量部署（含 docreader）："
echo "  ./scripts/deploy-aliyun.sh --full"
