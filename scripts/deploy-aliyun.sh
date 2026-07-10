#!/usr/bin/env bash
# 清除代理环境变量（Mac 上 Surge/Clash 会干扰 ACR 连接）
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
#
# WeKnora 阿里云 ECS 一键部署脚本
#
# 思路：
#   - 前端（nginx + 静态文件）→ Mac 本地构建，推 ACR
#   - 后端（Go 编译）→ 用 deploy-backend.sh 在服务器上构建，已推 ACR
#   这里只做部署：拉取最新镜像，重启服务
#
# 用法
#   ./scripts/deploy-aliyun.sh               # 默认
#   ./scripts/deploy-aliyun.sh --full         # 全量（含 docreader）
#
# 前置条件：
#   1. 最新镜像已在 ACR（用 deploy-backend.sh 构建）
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

echo "=== Step 2: 构建并推送前端镜像 ==="
echo "前端是 nginx + 静态文件，Mac 本地构建，快。"
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

# 构建前端
VITE_IS_DOCKER=true ./scripts/build_frontend_dist.sh 2>&1 | grep -E 'built in|error'
docker build --platform=linux/amd64 -t weknora-ui:latest -f frontend/Dockerfile frontend/ 2>&1 | tail -3

docker tag weknora-ui:latest "$ACR_REGISTRY/$ACR_NAMESPACE/ui:latest"
docker push "$ACR_REGISTRY/$ACR_NAMESPACE/ui:latest" 2>&1 | tail -3
echo "--- ui 镜像已推送到 ACR ---"

# docreader 镜像（非必需时跳过）
if [ "$FULL_DEPLOY" = true ]; then
  echo "--- 推送 docreader 镜像 ---"
  docker pull wechatopenai/weknora-docreader:latest 2>&1 | tail -1
  docker tag wechatopenai/weknora-docreader:latest "$ACR_REGISTRY/$ACR_NAMESPACE/docreader:latest"
  docker push "$ACR_REGISTRY/$ACR_NAMESPACE/docreader:latest" 2>&1 | tail -1
fi

echo ""
echo "=== Step 3: 服务器部署 ==="
echo "后端镜像从 ACR 拉取，不在服务器上编译。"
echo "如需编译后端，先执行：./scripts/deploy-backend.sh"
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

echo '--- 拉取最新镜像 ---'
docker compose -p weknora pull app frontend 2>&1 | tail -10

echo '--- 重启服务 ---'
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
echo "快速部署（从 ACR 拉镜像，不编译）："
echo "  ./scripts/deploy-aliyun.sh"
echo ""
echo "全量部署（含 docreader）："
echo "  ./scripts/deploy-aliyun.sh --full"
echo ""
echo "如需编译并推送后端镜像到 ACR："
echo "  ./scripts/deploy-backend.sh"
