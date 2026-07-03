#!/usr/bin/env bash
# 部署 WeKnora 到阿里云 ACS
set -euo pipefail

export NO_PROXY="cri-wnce2b2kj1t5pjwx-registry.cn-shanghai.cr.aliyuncs.com,.cr.aliyuncs.com,localhost,127.0.0.1,${NO_PROXY:-}"
export no_proxy="$NO_PROXY"

REGISTRY="cri-wnce2b2kj1t5pjwx-registry.cn-shanghai.cr.aliyuncs.com"
NAMESPACE="weknora"

echo "=== 1/6 登录容器镜像服务 ==="
aliyun cr get-authorization-token --instance-id cri-wnce2b2kj1t5pjwx --region cn-shanghai | \
  python3 -c "
import sys,json
d=json.load(sys.stdin)
print(f'docker login --username={d[\"data\"][\"tempUserName\"]} --password-stdin {d[\"data\"][\"authorizationToken\"]}')
" | head -1 | bash

echo "=== 2/6 加载本地镜像 ==="
docker load -i images.tar
docker load -i app.tar

echo "=== 3/6 推送镜像到 CR ==="
for img in ui app docreader; do
  src="weknora-${img}:latest"
  dst="${REGISTRY}/ai/weknora-${img}:latest"
  docker tag "$src" "$dst"
  docker push "$dst"
done

echo "=== 4/6 创建 CR 凭据 ==="
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
# 需要从 ~/.docker/config.json 提取凭据，或用 aliyun cr get-authorization-token 生成临时凭据
kubectl create secret docker-registry regcred -n "$NAMESPACE" \
  --docker-server="$REGISTRY" \
  --docker-username="cr_temp_user" \
  --docker-password="$(aliyun cr get-authorization-token --instance-id cri-wnce2b2kj1t5pjwx --region cn-shanghai 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["authorizationToken"])')" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "=== 5/6 生成随机密码 ==="
DB_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')
REDIS_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')
JWT_SECRET=$(openssl rand -base64 32)

echo "=== 6/6 Helm 部署 ==="
helm upgrade --install weknora ./helm \
  --namespace "$NAMESPACE" \
  --create-namespace \
  -f helm/values-acs.yaml \
  --set secrets.dbPassword="$DB_PASS" \
  --set secrets.redisPassword="$REDIS_PASS" \
  --set secrets.jwtSecret="$JWT_SECRET"

echo ""
echo "=== 部署完成! ==="
echo "DB密码: $DB_PASS"
echo "Redis密码: $REDIS_PASS"
echo ""
echo "查看状态: kubectl get pods -n $NAMESPACE"
echo "查看日志: kubectl logs -n $NAMESPACE -l app.kubernetes.io/component=app"
