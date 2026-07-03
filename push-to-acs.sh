#!/usr/bin/env bash
# 推送镜像到阿里云企业版 CR 并部署 WeKnora 到 ACS
set -euo pipefail
cd "$(dirname "$0")"

export NO_PROXY="cri-wnce2b2kj1t5pjwx-registry.cn-shanghai.cr.aliyuncs.com,.cr.aliyuncs.com,localhost,127.0.0.1,${NO_PROXY:-}"
export no_proxy="$NO_PROXY"

REGISTRY="cri-wnce2b2kj1t5pjwx-registry.cn-shanghai.cr.aliyuncs.com"
NAMESPACE="weknora"
KUBECONFIG="$(pwd)/acs-kubeconfig"
export KUBECONFIG

echo "=========================================="
echo "  1/5 登录容器镜像服务"
echo "=========================================="
TOKEN=$(aliyun cr get-authorization-token --instance-id cri-wnce2b2kj1t5pjwx --region cn-shanghai 2>&1 | \
  python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('AuthorizationToken',''))")
USER=$(aliyun cr get-authorization-token --instance-id cri-wnce2b2kj1t5pjwx --region cn-shanghai 2>&1 | \
  python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('TempUsername','cr_temp_user'))")

echo "$TOKEN" | docker login --username="$USER" --password-stdin "$REGISTRY" 2>/dev/null || {
  echo "-> 临时 token 登录失败，改用密码登录:"
  echo "-> 请输入 CR 登录密码（gxlyykt 对应的密码）:"
  read -s CR_PASS
  echo "$CR_PASS" | docker login --username=gxlyykt --password-stdin "$REGISTRY"
}

echo "=========================================="
echo "  2/5 加载本地镜像"
echo "=========================================="
docker load -i images.tar
docker load -i app.tar

echo "=========================================="
echo "  3/5 推送镜像到 CR"
echo "=========================================="
for src in weknora-ui weknora-app weknora-docreader; do
  # 给所有可能的本地标签打上 registry 地址
  docker tag "wechatopenai/$src:latest" "$REGISTRY/ai/$src:latest" 2>/dev/null || true
  docker tag "$src:latest" "$REGISTRY/ai/$src:latest" 2>/dev/null || true
  echo "推送 $src ..."
  docker push "$REGISTRY/ai/$src:latest" && echo "✓ $src 推送成功" || echo "✗ $src 推送失败"
done

# 检查是否有未标记的 app 镜像
APP_ID=$(docker images --format '{{.ID}}' --filter=reference='*weknora-app*' | head -1)
if [ -z "$APP_ID" ]; then
  APP_ID=$(docker images --format '{{.ID}}' | head -1)
  docker tag "$APP_ID" "$REGISTRY/ai/weknora-app:latest"
  echo "推送 app (来自 ID $APP_ID)..."
  docker push "$REGISTRY/ai/weknora-app:latest"
fi

echo "=========================================="
echo "  4/5 创建命名空间和 CR 凭据"
echo "=========================================="
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# 用临时 token 创建 ImagePullSecret
kubectl create secret docker-registry regcred -n "$NAMESPACE" \
  --docker-server="$REGISTRY" \
  --docker-username="$USER" \
  --docker-password="$TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "=========================================="
echo "  5/5 Helm 部署"
echo "=========================================="
DB_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')
REDIS_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')
JWT_SECRET=$(openssl rand -base64 32)

helm upgrade --install weknora ./helm \
  --namespace "$NAMESPACE" \
  --create-namespace \
  -f helm/values-acs.yaml \
  --set secrets.dbPassword="$DB_PASS" \
  --set secrets.redisPassword="$REDIS_PASS" \
  --set secrets.jwtSecret="$JWT_SECRET"

echo ""
echo "=========================================="
echo "  部署完成！"
echo "=========================================="
echo "  查看 Pods: kubectl get pods -n $NAMESPACE"
echo "  查看日志: kubectl logs -n $NAMESPACE -l app.kubernetes.io/component=app"
echo ""
echo "  DB 密码: $DB_PASS"
echo "  Redis 密码: $REDIS_PASS"
echo "=========================================="
