 #!/usr/bin/env bash
 # WeKnora 阿里云 ECS 一键部署脚本
 #
 # 用法：./scripts/deploy-aliyun.sh
 #
 # 前置条件：
 #   1. git 已推送到 fork（winnie-xzh/WeKnora）
 #   2. .env 已备份到 /root/.env.weknora.bak 或脚本路径下
 #   3. SSH 密钥路径正确
 #
 set -euo pipefail
 
 SSH_KEY="/Users/winnie/Documents/惠民卡资料/gxlyykt.pem"
 HOST="root@8.134.215.118"
 SSH_OPTS="-o ServerAliveInterval=30 -o ServerAliveCountMax=3"
 
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
 rm -rf /root/WeKnora-new
 git clone https://github.com/winnie-xzh/WeKnora.git /root/WeKnora-new
 
 echo "--- 恢复配置 ---"
 cp /root/.env.weknora.bak /root/WeKnora-new/.env 2>/dev/null || echo "WARN: 没有 .env.bak"
 cp /root/WeKnora/config/config.yaml /root/WeKnora-new/config/ 2>/dev/null || true
 
 cd /root/WeKnora-new
 
 # 1) 修改 Dockerfile 基础镜像源（Docker Hub 在国内不可用）
 echo "--- 修改Dockerfile镜像源 ---"
 sed -i 's|FROM golang:1.26-bookworm AS builder|FROM docker.m.daocloud.io/library/golang:1.26-bookworm AS builder|' docker/Dockerfile.app
 sed -i 's|FROM debian:12.12-slim|FROM docker.m.daocloud.io/library/debian:12.12-slim|' docker/Dockerfile.app
 sed -i 's|FROM nginx:stable-alpine|FROM docker.m.daocloud.io/library/nginx:stable-alpine|' frontend/Dockerfile
 
 # 2) 注释掉 UPX 压缩步骤（UPX arm64 在 x86_64 上会报 Exec format error）
 sed -i '/RUN curl.*upx\.github\.io/,+4 s/^/# /' docker/Dockerfile.app
 
 echo "--- 构建 app 镜像（后台，请等待） ---"
 nohup docker build \
   -t weknora-app:latest \
   -f docker/Dockerfile.app \
   --build-arg APK_MIRROR_ARG=mirrors.aliyun.com \
   --build-arg GOPROXY_ARG=https://goproxy.cn,direct \
   . > /tmp/build-app.log 2>&1 &
 BUILD_PID=$!
 echo "Build PID: $BUILD_PID，日志：tail -f /tmp/build-app.log"
 
 # 等待 app 构建完成（最多等 40 分钟）
 echo "--- 等待 app 构建完成 ---"
 for i in $(seq 1 80); do
   if docker images weknora-app:latest --format '{{.Repository}}' 2>/dev/null | grep -q .; then
     echo "App 镜像构建完成！"
     break
   fi
   if ! kill -0 $BUILD_PID 2>/dev/null; then
     echo "构建进程已结束，检查日志..."
     tail -5 /tmp/build-app.log
     break
   fi
   echo "  等待中... (${i}x30s)"
   sleep 30
 done
 
 echo "--- 构建前端镜像 ---"
 VITE_IS_DOCKER=true ./scripts/build_frontend_dist.sh
 docker build -t weknora-ui:latest -f frontend/Dockerfile frontend/
 
 echo "--- 打标签 ---"
 docker tag weknora-app:latest wechatopenai/weknora-app:latest
 docker tag weknora-ui:latest wechatopenai/weknora-ui:latest
 
 echo "--- 替换容器（保持项目名 weknora） ---"
 docker stop WeKnora-app WeKnora-frontend WeKnora-docreader 2>/dev/null || true
 docker rm WeKnora-app WeKnora-frontend WeKnora-docreader 2>/dev/null || true
 docker compose -p weknora up -d
 
 echo "=== 部署完成 ==="
 sleep 5
 docker compose -p weknora ps
 echo "--- 健康检查 ---"
 curl -s http://localhost:8080/health
 echo ""
 REMOTE
 
 echo "=== 全部完成 ==="
