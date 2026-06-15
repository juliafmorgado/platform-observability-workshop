#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

step() { echo -e "\n${CYAN}▶ $1${NC}"; }
ok()   { echo -e "${GREEN}  ✅ $1${NC}"; }
die()  { echo -e "${RED}  ❌ $1${NC}"; exit 1; }

# Load credentials
if [ ! -f "${REPO_ROOT}/.env" ]; then
  die ".env not found — copy .env.template to .env and add your Dash0 credentials"
fi
# shellcheck source=/dev/null
source "${REPO_ROOT}/.env"

[ -z "${DASH0_TOKEN:-}" ]         && die "DASH0_TOKEN is not set in .env"
[ -z "${DASH0_OTLP_ENDPOINT:-}" ] && die "DASH0_OTLP_ENDPOINT is not set in .env"

CLUSTER_NAME="meridian-workshop"

# ── 1. Kind cluster ──────────────────────────────────────────────────────────
step "Creating Kind cluster '${CLUSTER_NAME}'"
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "  Cluster already exists, skipping creation."
else
  kind create cluster --name "${CLUSTER_NAME}" --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080
        hostPort: 8080
        protocol: TCP
      - containerPort: 30000
        hostPort: 3000
        protocol: TCP
EOF
  ok "Cluster created"
fi
kubectl config use-context "kind-${CLUSTER_NAME}"

# ── 2. Build images ──────────────────────────────────────────────────────────
step "Building service images"
for svc in order-service inventory-service shipping-service; do
  docker build -t "meridian/${svc}:latest" "${REPO_ROOT}/services/${svc}" --quiet
  kind load docker-image "meridian/${svc}:latest" --name "${CLUSTER_NAME}"
  ok "${svc} image loaded"
done

# ── 3. Deploy broken manifests ───────────────────────────────────────────────
step "Deploying broken manifests to cluster"
kubectl apply -f "${REPO_ROOT}/k8s/broken/namespace.yaml"

# Create the Secret from real .env values — idempotent on re-runs
kubectl create secret generic dash0-credentials \
  --namespace meridian \
  --from-literal=otlp-endpoint="${DASH0_OTLP_ENDPOINT}" \
  --from-literal=token="${DASH0_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "${REPO_ROOT}/k8s/broken/otel-collector.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/broken/otel-platform-config.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/broken/inventory-service.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/broken/order-service.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/broken/shipping-service.yaml"
ok "Manifests applied"

# ── 4. Frontend via NodePort ─────────────────────────────────────────────────
step "Deploying frontend"

# nginx proxies /orders to order-service so the browser never makes a cross-origin request
kubectl apply -f - <<'NGINXEOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
  namespace: meridian
data:
  default.conf: |
    server {
        listen 80;
        root /usr/share/nginx/html;
        index index.html;

        location /orders {
            proxy_pass http://order-service:3000;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        location / {
            try_files $uri /index.html;
        }
    }
NGINXEOF

# HTML as a ConfigMap — embedded from the local file
kubectl create configmap frontend-html \
  --namespace meridian \
  --from-file=index.html="${REPO_ROOT}/frontend/index.html" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<'FRONTENDEOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: meridian
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
        - name: nginx
          image: nginx:alpine
          ports:
            - containerPort: 80
          volumeMounts:
            - name: html
              mountPath: /usr/share/nginx/html
            - name: nginx-config
              mountPath: /etc/nginx/conf.d
      volumes:
        - name: html
          configMap:
            name: frontend-html
        - name: nginx-config
          configMap:
            name: nginx-config
---
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: meridian
spec:
  type: NodePort
  selector:
    app: frontend
  ports:
    - port: 80
      targetPort: 80
      nodePort: 30080
---
apiVersion: v1
kind: Service
metadata:
  name: order-service-nodeport
  namespace: meridian
spec:
  type: NodePort
  selector:
    app: order-service
  ports:
    - port: 3000
      targetPort: 3000
      nodePort: 30000
FRONTENDEOF
ok "Frontend deployed"

# ── 5. Wait for rollout ──────────────────────────────────────────────────────
step "Waiting for pods to be ready"
kubectl rollout status deployment/otel-collector    -n meridian --timeout=120s
kubectl rollout status deployment/inventory-service -n meridian --timeout=120s
kubectl rollout status deployment/order-service     -n meridian --timeout=120s
kubectl rollout status deployment/shipping-service  -n meridian --timeout=120s
kubectl rollout status deployment/frontend          -n meridian --timeout=120s
ok "All pods ready"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Meridian is running — broken state deployed     ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Frontend:      http://localhost:8080            ║${NC}"
echo -e "${GREEN}║  Order API:     http://localhost:3000            ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Next: scripts/generate-traffic.sh              ║${NC}"
echo -e "${GREEN}║        scripts/check-act1.sh  (to verify fixes) ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
