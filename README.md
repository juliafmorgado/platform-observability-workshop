# Making Observability a First-Class Platform Concern

**PlatformCon Workshop**

The CTO is getting customer complaints about slow and failing orders. You open your observability backend and there is nothing useful even though the services are running.

Three things are misconfigured in the platform layer and all three fail silently. Find them, fix them, and then use the working telemetry to diagnose what is actually wrong with the app.

---

## Architecture

```
[Frontend] -> [order-service :3000] -> [inventory-service :3001]
                                    -> [shipping-service :3002]
```

- **order-service** takes orders and calls inventory to check stock
- **inventory-service** checks stock; some items behave badly by design
- **shipping-service** has no instrumentation yet (that's Act 3)
- **Frontend** is a simple order form at `http://localhost:8080`

All Node.js services use `@opentelemetry/auto-instrumentations-node`. The only OTel line in any service file:

```js
require('@opentelemetry/auto-instrumentations-node/register');
```

Everything else, the endpoint, protocol, and resource attributes, comes from environment variables. That's by design. It means the platform controls the observability config, not the individual services.

---

## Setup

**Requires:** Docker Desktop, kind, kubectl, helm, [Dash0 account](https://www.dash0.com/)

```bash
cp .env.template .env
# fill in DASH0_TOKEN and DASH0_OTLP_ENDPOINT
./scripts/preflight.sh
./scripts/deploy-broken.sh
```

When the script finishes: frontend at `http://localhost:8080`, order API at `http://localhost:3000`.

---

## Act 1: Fix the platform

Three bugs. Two files:

- `k8s/broken/otel-platform-config.yaml` contains Bug 1 and Bug 2
- `k8s/broken/otel-collector.yaml` contains Bug 3

Both services inherit their OTLP config from `otel-platform-config` via `envFrom`. That means neither service has a hardcoded endpoint or resource attributes. One change in the ConfigMap propagates to both services on the next rollout restart. When all services are dark, start with the shared config, not the individual service YAMLs.

```bash
kubectl describe configmap otel-platform-config -n meridian
kubectl logs deployment/otel-collector -n meridian --tail=30
```

Find all three bugs first, then apply everything at once:

```bash
kubectl apply -f k8s/broken/otel-platform-config.yaml
kubectl apply -f k8s/broken/otel-collector.yaml
kubectl rollout restart deployment -n meridian
```

```bash
./scripts/check-act1.sh
```

<details>
<summary>Hint 1: nothing is reaching Dash0</summary>

Check the service pod logs and the Collector logs for export errors. The Collector hostname is reachable — the connection is being established. Look at both `OTEL_EXPORTER_OTLP_PROTOCOL` and the port in `OTEL_EXPORTER_OTLP_ENDPOINT` in `k8s/broken/otel-platform-config.yaml`.

The OTel Collector has two listeners on two different ports: gRPC on `:4317`, HTTP/protobuf on `:4318`. They are not interchangeable. Protocol and port must match.

</details>

<details>
<summary>Hint 2: spans arrive but have no environment or version</summary>

Filter spans in Dash0 by `deployment.environment`. Nothing comes back. Look at `k8s/broken/otel-platform-config.yaml`. What key is missing?

</details>

<details>
<summary>Hint 3: about the Collector</summary>

Look at the `otlp` exporter in `k8s/broken/otel-collector.yaml`. What happens to queued spans if the Collector pod restarts? What happens if Dash0 is temporarily unreachable?

The fixed version uses `sending_queue` with `file_storage` and `retry_on_failure`. See `k8s/fixed/otel-collector.yaml`.

</details>

<details>
<summary>All three fixes (spoilers)</summary>

**Bug 1** `OTEL_EXPORTER_OTLP_PROTOCOL` is `http/protobuf` but the endpoint uses port `:4317`, which is the Collector's gRPC port. The SDK connects successfully but spans are rejected at the protocol layer with no clear error message. Fix:
```yaml
OTEL_EXPORTER_OTLP_PROTOCOL: "grpc"
```
Alternatively: change the endpoint port to `:4318` and leave the protocol as `http/protobuf`. Both work; `grpc` is preferred within a cluster.

**Bug 2** `OTEL_RESOURCE_ATTRIBUTES` is missing entirely from `otel-platform-config`. Add:
```yaml
OTEL_RESOURCE_ATTRIBUTES: "service.version=1.0.0,deployment.environment=production"
```
Keep these values low-cardinality. Resource attributes are stamped on every span. High-cardinality values here (pod names, user IDs, request IDs) multiply ingestion cost and cause dimension explosion in metric backends. Those belong on individual spans, not on the resource.

**Bug 3** The `otlp` exporter in `otel-collector` has no `sending_queue` and no `retry_on_failure`. Every pod restart or backend blip silently drops in-flight spans. See `k8s/fixed/otel-collector.yaml` for the complete fix.

Apply:
```bash
kubectl apply -f k8s/broken/otel-platform-config.yaml
kubectl apply -f k8s/broken/otel-collector.yaml
kubectl rollout restart deployment -n meridian
```

</details>

---

## Act 2: Diagnose the app

With observability working, generate traffic that includes the problematic items:

```bash
./scripts/generate-traffic.sh --with-issues
```

In Dash0, open the trace explorer. Two things to find:

1. **The slow trace.** Sort by duration. Which span is taking 2 seconds? Which service owns it? You'd never know from the HTTP response alone.
2. **The error trace.** Where does the error originate? Does it propagate to the calling service, or do you see two disconnected traces?

Try Agent0:
- *"Which service is causing slow orders?"*
- *"Show me traces where inventory-service returned a 500"*
- *"What's the P95 latency for the /stock endpoint over the last 5 minutes?"*

---

## Act 3: Dash0 Operator

`shipping-service` is running in the cluster with zero OTel config. The Dash0 Operator instruments new workloads automatically via a mutating admission webhook, no code changes, no Dockerfile edits.

```bash
helm repo add dash0-operator https://dash0hq.github.io/dash0-operator
helm repo update

helm install dash0-operator dash0-operator/dash0-operator \
  --namespace dash0-system \
  --create-namespace \
  --set operator.dash0Backend.endpoint="${DASH0_OTLP_ENDPOINT}" \
  --set operator.dash0Backend.authorization.token="${DASH0_TOKEN}"
```

Label the namespace, then restart the service:

```bash
kubectl label namespace meridian dash0.com/instrumentWorkloads=all
kubectl rollout restart deployment/shipping-service -n meridian
```

Inspect what the operator injected:

```bash
kubectl describe pod -n meridian -l app=shipping-service
```

You'll see `OTEL_SERVICE_NAME=shipping-service` from the operator (derived from the workload name). You won't see `OTEL_EXPORTER_OTLP_ENDPOINT` or `OTEL_RESOURCE_ATTRIBUTES` in the injected env, because those came from `otel-platform-config`, the ConfigMap you fixed in Act 1. The operator handled the identity. The platform handled the rest.

---

## Bonus: remove the last hardcoded value

Every service still has `OTEL_SERVICE_NAME` hardcoded in its deployment YAML. Replace it with a Downward API reference that derives the name from the pod's own `app` label:

```yaml
- name: OTEL_SERVICE_NAME
  valueFrom:
    fieldRef:
      fieldPath: "metadata.labels['app']"
```

The `app` label is already set on every pod. With this change, adding a new service to the platform requires zero OTel config. The label is the identity, and the platform handles everything else. That's what the Dash0 operator does for uninstrumented workloads.

---

## Reference

### Reset to fixed state

```bash
kubectl apply -f k8s/fixed/
```

### Useful commands

```bash
# Inspect the namespace-level platform config
kubectl describe configmap otel-platform-config -n meridian

# See what a pod actually resolved from the ConfigMap
kubectl exec -n meridian deploy/order-service -- env | grep OTEL

# Collector logs
kubectl logs -n meridian deploy/otel-collector -f

# All pods
kubectl get pods -n meridian

# Restart all deployments after a ConfigMap change
kubectl rollout restart deployment -n meridian
```

### Traffic generation

```bash
./scripts/generate-traffic.sh                    # normal traffic only
./scripts/generate-traffic.sh --with-issues      # adds slow and error requests
ORDER_API=http://localhost:3000 ./scripts/generate-traffic.sh --with-issues
```

### Teardown

```bash
kind delete cluster --name meridian-workshop
```

---

### Taking this further

**Multi-environment (staging vs. production)**

Separate namespaces, separate ConfigMaps. `otel-platform-config` in `meridian-staging` has `deployment.environment=staging`. With Kustomize: a base ConfigMap with shared defaults and a per-environment overlay that patches `OTEL_RESOURCE_ATTRIBUTES`. The developer-facing config is identical either way — services don't know or care which ConfigMap they inherit from.

**Collector topology: DaemonSet vs. Deployment**

For application telemetry, a single Collector Deployment is fine. If you also need host-level metrics (node CPU, disk I/O, kubelet stats), add a DaemonSet Collector alongside it — it runs one pod per node and has the node-level access a Deployment doesn't. Common pattern: DaemonSet for node metrics, Deployment as the aggregation and export layer.

**Sampling**

At scale, 100% trace sampling gets expensive. The right answer is tail-based sampling in the Collector: buffer complete traces, then decide whether to keep them based on whether they had errors, exceeded latency thresholds, or match some other policy. The `tail_sampling` processor handles this. The persistent queue from Bug 3 is a prerequisite — you need durable buffering for tail sampling to work correctly.

**GitOps**

The ConfigMap is a plain manifest. ArgoCD or Flux syncs it like anything else. The discipline: treat `otel-platform-config.yaml` as platform infrastructure with its own review process, not application config scattered across service repos. Platform config that gets treated like application config eventually drifts.

---

## Repo structure

```
.
├── services/
│   ├── order-service/       # Express, port 3000, calls inventory
│   ├── inventory-service/   # Express, port 3001, slow/broken items
│   └── shipping-service/    # Express, port 3002, no OTel
├── frontend/
│   └── index.html
├── k8s/
│   ├── broken/              # Starting state, three intentional bugs
│   └── fixed/               # Correct state
└── scripts/
    ├── preflight.sh
    ├── deploy-broken.sh
    ├── generate-traffic.sh
    └── check-act1.sh
```
