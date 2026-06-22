# Making Observability a First-Class Platform Concern

A hands-on workshop for platform engineers. Fix a broken OTel pipeline, understand why each decision matters, and make instrumentation automatic for every service on the platform.

---

## Prerequisites (already done before you arrive)

- [ ] Docker Desktop + Kind installed
- [ ] kubectl + Helm installed
- [ ] Dash0 account created at app.dash0.com
- [ ] Auth token from Settings > Auth Tokens
- [ ] Repo cloned and .env filled in
- [ ] `./scripts/preflight.sh` passing green

---

## Section 1: Why does a Collector matter?

Three things the Collector gives you that direct export does not: all OTLP config in one ConfigMap, endpoint and protocol as platform decisions instead of per-service config, and a retry and buffer layer between services and the backend.

Inspect what the services see:

```bash
kubectl describe configmap otel-platform-config -n meridian
kubectl exec -n meridian deploy/order-service -- env | grep OTEL
```

Why one ConfigMap controls all services: each deployment uses `envFrom: otel-platform-config`. One change in that file, one rollout restart, every service picks it up. The only value that stays per-service is `OTEL_SERVICE_NAME`, because the platform cannot know the service identity in advance.

---

## Section 2: What does a production-grade pipeline look like?

Three bugs. Two files. Find all three before fixing anything. Then apply both files and do one rollout restart.

### Bug 1 — `k8s/broken/otel-platform-config.yaml`

Port mismatch. `OTEL_EXPORTER_OTLP_PROTOCOL` is `grpc`, which expects `:4317`. `OTEL_EXPORTER_OTLP_ENDPOINT` points at `:4318`, the HTTP port. The SDK connects, gets rejected at the protocol layer, and drops spans silently.

Symptom: `ECONNREFUSED` in service logs.

### Bug 2 — same file

`OTEL_RESOURCE_ATTRIBUTES` is missing entirely. Spans arrive with no `service.version` and no `deployment.environment`. The data lands but is useless for filtering, alerting, or environment separation.

Symptom: "Accessing resource attributes before async attributes settled" in service logs.

### Bug 3 — `k8s/broken/otel-collector.yaml`

No `sending_queue`, no `retry_on_failure` on the `otlp` exporter. Any pod restart or backend blip silently drops in-flight spans. No error. No warning. Just lost data.

Fix: `sending_queue` with `file_storage` extension plus `retry_on_failure`.

### Investigate

```bash
kubectl describe configmap otel-platform-config -n meridian
kubectl logs deployment/order-service -n meridian --tail=20
kubectl get configmap otel-collector-config -n meridian -o yaml
```

### Fix and apply

```bash
kubectl apply -f k8s/broken/otel-platform-config.yaml
kubectl apply -f k8s/broken/otel-collector.yaml
kubectl rollout restart deployment -n meridian
```

### Verify

```bash
./scripts/check-act1.sh
```

---

## Section 3: How does this scale?

Every service still needs `OTEL_SERVICE_NAME` hardcoded in its deployment YAML. The Dash0 operator removes that last manual step. It injects OTel automatically via a mutating admission webhook before the container starts.

Install the operator:

```bash
helm repo add dash0-operator https://dash0hq.github.io/dash0-operator
helm repo update
helm install dash0-operator dash0-operator/dash0-operator \
  --namespace dash0-system \
  --create-namespace
```

Configure the backend and label the namespace:

```bash
set -a && source .env && set +a
envsubst < k8s/operator/dash0-operator-configuration.yaml | kubectl apply -f -
kubectl label namespace meridian dash0.com/instrumentWorkloads=all
kubectl apply -f k8s/operator/dash0-monitoring.yaml
kubectl rollout restart deployment/shipping-service -n meridian
```

Inspect what the operator injected:

```bash
kubectl describe pod -n meridian -l app=shipping-service
```

Three things to look for in the output:

- `dash0.com/instrumented=true` label on the pod
- `dash0-instrumentation` init container, Exit Code 0
- `LD_PRELOAD` pointing to `libotelinject.so`

Generate traffic and watch `shipping-service` appear in Dash0:

```bash
./scripts/generate-traffic.sh --with-issues
```

---

## Key architectural concepts

**ConfigMap as platform config**

One file, one change, every service picks it up on rollout restart. `OTEL_SERVICE_NAME` stays per-service because the platform cannot know the service identity in advance. Everything else is a platform decision.

**Persistent queue over batch processor**

The batch processor buffers in memory and loses data on restart. The `sending_queue` with `file_storage` writes to disk first. If the Collector restarts, the queue survives.

**gRPC vs HTTP/protobuf**

gRPC on `:4317`, HTTP/protobuf on `:4318`. Protocol and port must match. The mismatch in Bug 1 is one of the most common silent failures in OTel setups.

**DaemonSet vs Deployment**

Deployment for application telemetry and central aggregation. DaemonSet for host-level signals that need node access. The Dash0 operator uses a DaemonSet Collector per node (port 40318), which is why injected pods point to `DASH0_NODE_IP`, not the cluster Collector.

---

## Quick reference

```bash
# Inspect the platform ConfigMap
kubectl describe configmap otel-platform-config -n meridian

# Tail service logs for export errors
kubectl logs deployment/order-service -n meridian --tail=20

# See the full Collector config
kubectl get configmap otel-collector-config -n meridian -o yaml

# See what a pod actually resolved from the ConfigMap
kubectl exec -n meridian deploy/order-service -- env | grep OTEL

# All pods in the namespace
kubectl get pods -n meridian

# Restart all deployments after a ConfigMap change
kubectl rollout restart deployment -n meridian

# Tear everything down
kind delete cluster --name meridian-workshop
```
