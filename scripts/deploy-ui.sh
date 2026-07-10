#!/usr/bin/env bash
# 清除代理环境变量（Mac 上 Surge/Clash 会干扰 ACR 连接）
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
#
# WeKnora 前端部署脚本
#
# 只构建和部署前端（UI）服务，不涉及后端。
# 后端部署请使用：./scripts/deploy-backend.sh
#
# 用法
#   ./scripts/deploy-ui.sh
#
# 前置条件：
#   - git 已推送到 fork（winnie-xzh/WeKnora）
#   - SSH 密钥路径正确
#   - ACR 已配置（公网端点、命名空间、仓库已创建）
#
set -euo pipefail

START_TIME=$(date +%s)

SSH_KEY="/Users/winnie/Documents/惠民卡资料/gxlyykt.pem"
HOST="root@8.134.215.118"
SSH_OPTS="-o ServerAliveInterval=30 -o ServerAliveCountMax=3"
ACR_REGISTRY="gz3-registry.cn-guangzhou.cr.aliyuncs.com"
ACR_NAMESPACE="weknora"

echo "=== Step 1: 提交代码到 GitHub ==="
cd "$(dirname "$0")/.."
git add -A
git status --short
read -p "Commit message [auto deploy]: " msg
git commit -m "${msg:-auto deploy: $(date +%F)}"
git push fork main
echo "--- 提交完成 ---"

echo "=== Step 2: 构建并推送前端镜像 ==="
echo "前端是 nginx + 静态文件，Mac 本地构建。"
echo ""

# 获取 ACR 临时 Token
ACR_TOKEN=$(aliyun cr GetAuthorizationToken --InstanceId cri-j5gbox3b9osyqjxy --RegionId cn-guangzhou 2>&1 | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d['AuthorizationToken'])
")

# 登录 ACR
echo "登录 ACR..."
echo "$ACR_TOKEN" | docker login --username=cr_temp_user --password-stdin "$ACR_REGISTRY" 2>&1

# 构建前端（指定 amd64 避免 Mac arm64 架构问题）
VITE_IS_DOCKER=true ./scripts/build_frontend_dist.sh 2>&1 | grep -E 'built in|error'
docker build --platform=linux/amd64 -t weknora-ui:latest -f frontend/Dockerfile frontend/ 2>&1 | tail -3

docker tag weknora-ui:latest "$ACR_REGISTRY/$ACR_NAMESPACE/ui:latest"
docker push "$ACR_REGISTRY/$ACR_NAMESPACE/ui:latest" 2>&1 | tail -3
echo "--- ui 镜像已推送到 ACR ---"

echo "=== Step 3: 服务器部署（只更新前端） ==="
echo ""

# 获取新的临时 Token（旧的可能已过期）
ACR_TOKEN=$(aliyun cr GetAuthorizationToken --InstanceId cri-j5gbox3b9osyqjxy --RegionId cn-guangzhou 2>&1 | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d['AuthorizationToken'])
")

ssh -i $SSH_KEY $SSH_OPTS $HOST "
set -euo pipefail

cd /root/WeKnora-new

echo '--- 登录 ACR ---'
echo '$ACR_TOKEN' | docker login --username=cr_temp_user --password-stdin $ACR_REGISTRY 2>&1

echo '--- 拉取最新前端镜像 ---'
docker compose -p weknora pull frontend 2>&1 | tail -5

echo '--- 重启前端服务 ---'
docker compose -p weknora rm -fs frontend 2>/dev/null || true
FRONTEND_PORT=8081 docker compose -p weknora up -d frontend --no-deps

echo '=== 部署完成 ==='
sleep 3
docker compose -p weknora ps --format 'table {{.Name}}\t{{.Image}}\t{{.Status}}'
echo ''
curl -s http://localhost:8081/ | grep -o '<title>.*</title>'
"

echo ""
echo "=== 全部完成 ==="
echo ""
ELAPSED=$(( $(date +%s) - START_TIME ))
printf "⏱ 总耗时: %dm%02ds\n" $((ELAPSED/60)) $((ELAPSED%60))
echo ""
echo "后端部署请使用：./scripts/deploy-backend.sh"
