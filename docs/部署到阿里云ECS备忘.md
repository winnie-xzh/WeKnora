 # WeKnora 阿里云 ECS 部署备忘
 
 ## 环境
 
 - 服务器 IP：8.134.215.118
 - SSH 密钥：`/Users/winnie/Documents/惠民卡资料/gxlyykt.pem`
 - 用户名：`root`
 - 部署目录：`/root/WeKnora-new`
 - 旧备份：`/root/WeKnora`（保留不删）
 - 反向代理：nginx 容器（`ai.gxlyykt.cn`，暴露 80/443）
 
 ## 部署前准备
 
 ### 1. 提交代码到 GitHub
 
 ```bash
 git add .
 git commit -m "描述变更"
 git push fork main
 ```
 
 推送后 GitHub Actions 会自动构建（如果有配 Docker Hub secrets），但我们的 fork 可能没有，
 所以需要手动在服务器上构建（见下）。
 
 ### 2. 在服务器上拉取代码
 
 ```bash
 ssh -i /path/to/gxlyykt.pem root@8.134.215.118
 
 # 克隆新代码（如果已有则跳过）
 rm -rf /root/WeKnora-new
 git clone https://github.com/winnie-xzh/WeKnora.git /root/WeKnora-new
 
 # 恢复 .env
 cp /root/.env.weknora.bak /root/WeKnora-new/.env
 ```
 
 ## 构建 Docker 镜像
 
 ### ⚠️ 注意事项（教训总结）
 
 #### 1. Docker Hub 在国内不可用
 
 Docker Hub 在国内 DNS 污染且无法直连。
 必须修改两个 Dockerfile 中的 `FROM` 语句，将基础镜像改为 DaoCloud 镜像源：
 
 ```bash
 # docker/Dockerfile.app 修改两处
 FROM docker.m.daocloud.io/library/golang:1.26-bookworm AS builder
 FROM docker.m.daocloud.io/library/debian:12.12-slim
 
 # frontend/Dockerfile 修改一处
 FROM docker.m.daocloud.io/library/nginx:stable-alpine
 ```
 
 #### 2. UPX 压缩架构问题
 
 Dockerfile 里硬编码了 `upx-4.2.4-arm64_linux`，但阿里云 ECS 是 x86_64 架构。
 要么改成 `amd64_linux`，要么直接注释掉 UPX 步骤（非必需，只优化镜像大小）。
 
 ```bash
 # 注释掉 docker/Dockerfile.app 中的 UPX 步骤
 sed -i '/RUN curl.*upx\.github\.io/,+4 s/^/# /' docker/Dockerfile.app
 ```
 
 #### 3. 使用国内镜像加速 apt 和 Go 模块
 
 ```bash
 # apt 用阿里云镜像
 --build-arg APK_MIRROR_ARG=mirrors.aliyun.com
 
 # Go 模块用 goproxy.cn
 --build-arg GOPROXY_ARG=https://goproxy.cn,direct
 ```
 
 #### 4. SSH 超时问题
 
 构建耗时 20-30 分钟，SSH 连接容易超时中断。
 **必须用 `nohup` 后台运行**，不要直接运行 `docker build`：
 
 ```bash
 nohup docker build ... > /tmp/build.log 2>&1 &
 tail -f /tmp/build.log  # 查看进度
 ```
 
 ### 执行构建
 
 ```bash
 cd /root/WeKnora-new
 
 nohup docker build \
   -t weknora-app:latest \
   -f docker/Dockerfile.app \
   --build-arg APK_MIRROR_ARG=mirrors.aliyun.com \
   --build-arg GOPROXY_ARG=https://goproxy.cn,direct \
   . > /tmp/build-app.log 2>&1 &
 
 # 构建前端（需要先构建 dist）
 cd /root/WeKnora-new
 VITE_IS_DOCKER=true ./scripts/build_frontend_dist.sh
 docker build -t weknora-ui:latest -f frontend/Dockerfile frontend/
 ```
 
 ## 部署（替换旧容器）
 
 ### 给镜像打标签
 
 ```bash
 docker tag weknora-app:latest wechatopenai/weknora-app:latest
 docker tag weknora-ui:latest wechatopenai/weknora-ui:latest
 ```
 
 ### 替换容器
 
 **关键**：必须用 `-p weknora` 保持项目名一致，否则会创建新网络：
 
 ```bash
 cd /root/WeKnora-new
 
 # 停旧容器
 docker stop WeKnora-app WeKnora-frontend WeKnora-docreader 2>/dev/null || true
 docker rm WeKnora-app WeKnora-frontend WeKnora-docreader 2>/dev/null || true
 
 # 启动全部服务（用 -p weknora 匹配旧项目名）
 docker compose -p weknora up -d
 ```
 
 ### 验证
 
 ```bash
 docker compose -p weknora ps
 curl http://localhost:8080/health
 curl http://localhost:8081/ | head -3
 ```
 
 ## 构建缓存说明
 
 - Docker build 会缓存成功的步骤层
 - 修改 Dockerfile 会使**所有后续步骤**缓存失效
 - 如果没有改 Dockerfile，`COPY . .` 之后的步骤（主要是 `go build`）需要重跑
 - 中断构建后重新用 nohup 启动即可，大部分层会命中缓存
 
 ## 一键部署脚本
 
 已保存到 `scripts/deploy-aliyun.sh`，基于本次经验编写，整合了上述所有避坑点。
