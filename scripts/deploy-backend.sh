#!/usr/bin/env bash
# 清除代理环境变量（Mac 上 Surge/Clash 会干扰 ACR 连接）
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
#
# WeKnora 后端一键部署脚本
#
# 思路：在 Mac 上只提交代码，服务器上原生构建，
#       避免 Mac arm64 → 服务器 x86_64 架构问题。
#
# 用法
#   ./scripts/deploy-backend.sh               # 默认
#   ./scripts/deploy-backend.sh --no-cache     # 强制重构建
#
set -euo pipefail

START_TIME=$(date +%s)

SSH_KEY="/Users/winnie/Documents/惠民卡资料/gxlyykt.pem"
HOST="root@8.134.215.118"
SSH_OPTS="-o ServerAliveInterval=30 -o ServerAliveCountMax=3"
ACR_REGISTRY="gz3-registry.cn-guangzhou.cr.aliyuncs.com"
ACR_NAMESPACE="weknora"
NO_CACHE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-cache) NO_CACHE="--no-cache"; shift ;;
    *) echo "用法: $0 [--no-cache]"; exit 1 ;;
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

echo "=== Step 2: 在服务器上构建 app 镜像 ==="
echo "服务器是 x86_64，原生编译 Go，比 Mac 上 QEMU 模拟快很多。"
echo ""

# 获取 ACR 临时 Token
ACR_TOKEN=$(aliyun cr GetAuthorizationToken --InstanceId cri-j5gbox3b9osyqjxy --RegionId cn-guangzhou 2>&1 | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d['AuthorizationToken'])
")

ssh -i $SSH_KEY $SSH_OPTS $HOST "
set -euo pipefail

cd /root/WeKnora-new

echo '--- 拉取最新代码 ---'
git pull origin main
echo '最新提交：'
git log --oneline -1

echo '--- 登录 ACR ---'
echo '$ACR_TOKEN' | docker login --username=cr_temp_user --password-stdin $ACR_REGISTRY 2>&1

echo '--- 构建 app 镜像（服务器原生编译，约 3-5 分钟）---'
docker compose -p weknora build $NO_CACHE --build-arg GOPROXY_ARG=https://goproxy.cn,direct app 2>&1

echo '--- 推送 app 到 ACR ---'
docker compose -p weknora push app 2>&1 | tail -3

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
ELAPSED=$(( $(date +%s) - START_TIME ))
printf "⏱ 总耗时: %dm%02ds\n" $((ELAPSED/60)) $((ELAPSED%60))
