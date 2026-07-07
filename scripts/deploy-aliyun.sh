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
#
set -euo pipefail

SSH_KEY="/Users/winnie/Documents/惠民卡资料/gxlyykt.pem"
HOST="root@8.134.215.118"
SSH_OPTS="-o ServerAliveInterval=30 -o ServerAliveCountMax=3"
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

echo "=== Step 2: 服务器上拉取代码并构建 ==="
ssh -i $SSH_KEY $SSH_OPTS $HOST << 'REMOTE'
set -euo pipefail

echo "--- 拉取代码 ---"
rm -rf /root/WeKnora-new /tmp/WeKnora-clone
git clone https://github.com/winnie-xzh/WeKnora.git /tmp/WeKnora-clone
cp -a /tmp/WeKnora-clone /root/WeKnora-new
rm -rf /tmp/WeKnora-clone

echo "--- 恢复配置 ---"
cp /root/.env.weknora.bak /root/WeKnora-new/.env 2>/dev/null || echo "WARN: 没有 .env.bak"
if [ ! -f /root/WeKnora/config/config.yaml ]; then
  mkdir -p /root/WeKnora/config
fi
cp /root/WeKnora/config/config.yaml /root/WeKnora-new/config/ 2>/dev/null || true
cp /root/WeKnora-new/.env /root/.env.weknora.bak 2>/dev/null || true

cd /root/WeKnora-new

echo "--- 修改 Dockerfile 镜像源（国内网络） ---"
sed -i 's|FROM golang:1.26-bookworm AS builder|FROM docker.m.daocloud.io/library/golang:1.26-bookworm AS builder|' docker/Dockerfile.app
sed -i 's|FROM debian:12.12-slim|FROM docker.m.daocloud.io/library/debian:12.12-slim|' docker/Dockerfile.app
sed -i 's|FROM nginx:stable-alpine|FROM docker.m.daocloud.io/library/nginx:stable-alpine|' frontend/Dockerfile

echo "--- 注释 UPX 步骤（x86_64 架构不兼容） ---"
sed -i '/RUN curl.*upx\.github\.io/,+4 s/^/# /' docker/Dockerfile.app

echo "--- 构建 app 镜像 ---"
nohup docker build -t weknora-app:latest \
  -f docker/Dockerfile.app \
  --build-arg APK_MIRROR_ARG=mirrors.aliyun.com \
  --build-arg GOPROXY_ARG=https://goproxy.cn,direct \
  . > /tmp/build-app.log 2>&1 &
BUILD_PID=$!
echo "PID: $BUILD_PID | 日志: tail -f /tmp/build-app.log"

for i in $(seq 1 80); do
  if docker images weknora-app:latest --format '{{.Repository}}' 2>/dev/null | grep -q .; then
    echo "app 镜像构建完成！"
    break
  fi
  if ! kill -0 $BUILD_PID 2>/dev/null; then
    echo "构建结束，最后日志："
    tail -5 /tmp/build-app.log
    break
  fi
  echo "  等待中... (${i}x30s)"
  sleep 30
done

echo "--- 构建前端镜像 ---"
VITE_IS_DOCKER=true ./scripts/build_frontend_dist.sh
docker build -t weknora-ui:latest -f frontend/Dockerfile frontend/

docker tag weknora-app:latest wechatopenai/weknora-app:latest
docker tag weknora-ui:latest wechatopenai/weknora-ui:latest

if [ "$FULL_DEPLOY" = true ]; then
  echo "--- 构建 docreader 镜像 ---"
  nohup docker build -t weknora-docreader:latest \
    -f docker/Dockerfile.docreader \
    --build-arg APT_MIRROR=mirrors.aliyun.com \
    . > /tmp/build-docreader.log 2>&1 &
  wait
  docker tag weknora-docreader:latest wechatopenai/weknora-docreader:latest
fi

echo "--- 确保基础设施容器在运行 ---"
for svc in WeKnora-postgres WeKnora-redis WeKnora-docreader; do
  if ! docker ps --filter "name=$svc" --format '{{.Names}}' 2>/dev/null | grep -q .; then
    s=${svc#WeKnora-}
    echo "  启动 $svc ..."
    docker compose -p weknora up -d "$s" --no-deps 2>/dev/null || true
  fi
done

echo "--- 替换 app + frontend ---"
docker stop WeKnora-app WeKnora-frontend 2>/dev/null || true
docker rm WeKnora-app WeKnora-frontend 2>/dev/null || true
docker compose -p weknora up -d app frontend --no-deps

echo "=== 部署完成 ==="
sleep 3
docker compose -p weknora ps
echo "--- 健康检查 ---"
curl -s http://localhost:8080/health
echo ""
REMOTE

echo "=== 全部完成 ==="
echo ""
echo "快速部署（只更新 app + frontend）："
echo "  ./scripts/deploy-aliyun.sh"
echo ""
echo "全量部署（含 docreader）："
echo "  ./scripts/deploy-aliyun.sh --full"
