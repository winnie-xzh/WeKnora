#!/usr/bin/env bash
# WeKnora 部署脚本公共库

# ── 清除代理环境变量（Mac 上 Surge/Clash 会干扰 ACR 连接）──
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY

# ── SSH 连接配置 ──
# 可通过环境变量覆盖
SSH_KEY="${DEPLOY_SSH_KEY:-/Users/winnie/Documents/惠民卡资料/gxlyykt.pem}"
SSH_HOST="${DEPLOY_SSH_HOST:-root@8.134.215.118}"
SSH_OPTS="-o ServerAliveInterval=30 -o ServerAliveCountMax=3"
REMOTE_REPO_PATH="${DEPLOY_REMOTE_REPO_PATH:-/root/WeKnora-new}"

# ── ACR 配置 ──
ACR_REGISTRY="${DEPLOY_ACR_REGISTRY:-gz3-registry.cn-guangzhou.cr.aliyuncs.com}"
ACR_NAMESPACE="${DEPLOY_ACR_NAMESPACE:-weknora}"
ACR_INSTANCE_ID="${DEPLOY_ACR_INSTANCE_ID:-cri-j5gbox3b9osyqjxy}"
ACR_REGION="${DEPLOY_ACR_REGION:-cn-guangzhou}"
ACR_CRED_FILE="${SCRIPT_DIR}/.acr-cred"

# ── 构建选项 ──
WEKNORA_VERSION="${WEKNORA_VERSION:-latest}"
NO_CACHE="${NO_CACHE:-}"

# ── 计时工具 ──
__TICK=${__TICK:-$(date +%s)}
_tick() {
    local now d
    now=$(date +%s)
    d=$((now - __TICK))
    __TICK=$now
    printf "  ⏱ %dm%02ds\n" $((d / 60)) $((d % 60))
}

# ── ACR 认证 ──
# 优先用永久凭证，其次通过 aliyun CLI 获取临时 Token
acr_auth() {
    if [ -f "$ACR_CRED_FILE" ]; then
        source "$ACR_CRED_FILE"
        ACR_AUTH_USER="$ACR_USERNAME"
        ACR_AUTH_PASS="$ACR_PASSWORD"
        echo "[acr] 使用永久凭证（${ACR_CRED_FILE}）"
    else
        echo "[acr] 获取临时 Token..."
        ACR_AUTH_USER="cr_temp_user"
        ACR_AUTH_PASS=$(aliyun cr GetAuthorizationToken \
            --InstanceId "$ACR_INSTANCE_ID" \
            --RegionId "$ACR_REGION" 2>&1 | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['AuthorizationToken'])
")
    fi
}

# ── ACR 登录（本地 Docker）──
acr_login() {
    echo "[acr] 登录 ${ACR_REGISTRY}..."
    echo "$ACR_AUTH_PASS" | docker login --username="$ACR_AUTH_USER" --password-stdin "$ACR_REGISTRY" 2>&1
}


# ── 镜像全名（含 registry/namespace/tag）──
image_full_name() {
    local svc="$1"
    echo "${ACR_REGISTRY}/${ACR_NAMESPACE}/${svc}:${WEKNORA_VERSION}"
}
