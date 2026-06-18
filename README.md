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
```

Then run these scripts (preflight checks everything is installed and your credentials work).
```bash
./scripts/preflight.sh
./scripts/deploy-broken.sh
```

When the script finishes you will have the frontend at `http://localhost:8080`, and order API at `http://localhost:3000`.

---

## Act 1: Fix the platform

You have three bugs to fix on two files:

- `k8s/broken/otel-platform-config.yaml` contains Bug 1 and Bug 2
- `k8s/broken/otel-collector.yaml` contains Bug 3

Both services inherit their OTLP config from `otel-platform-config` via `envFrom`. That means neither service has a hardcoded endpoint or resource attributes. One change in the ConfigMap propagates to both services on the next rollout restart. When all services are dark, start with the shared config, not the individual service YAMLs.

Start your investigation here:

```bash
# inspect the platform config — protocol, endpoint, missing keys
kubectl describe configmap otel-platform-config -n meridian

# service logs — export errors show up here, not in the Collector
kubectl logs deployment/order-service -n meridian --tail=20
```

Find all three bugs first, fix them, then apply everything at once:

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

Check the service pod logs:

```bash
kubectl logs deployment/order-service -n meridian --tail=20
# look for ECONNREFUSED — that tells you the hostname resolved but the port or protocol is wrong
```

`ECONNREFUSED` means the hostname was right but nothing answered on that port. `ENOTFOUND` would mean the hostname itself was wrong. Check the port in `OTEL_EXPORTER_OTLP_ENDPOINT` in `k8s/broken/otel-platform-config.yaml` and compare it to what the Collector actually listens on:

```bash
kubectl get svc otel-collector -n meridian -o yaml
```

The OTel Collector listens for gRPC on `:4317` and HTTP/protobuf on `:4318`. The protocol in `OTEL_EXPORTER_OTLP_PROTOCOL` and the port in `OTEL_EXPORTER_OTLP_ENDPOINT` must match.

</details>

<details>
<summary>Hint 2: spans will arrive with no environment or version</summary>

Run `kubectl describe configmap otel-platform-config -n meridian` and look at every key that's there. A complete observability config needs an endpoint, a protocol, and resource attributes. Which of those three is missing from this ConfigMap?

</details>

<details>
<summary>Hint 3: about the Collector</summary>

Look at the `otlp` exporter in `k8s/broken/otel-collector.yaml`. What happens to queued spans if the Collector pod restarts? What happens if Dash0 is temporarily unreachable?

The fixed version uses `sending_queue` with `file_storage` and `retry_on_failure`. See `k8s/fixed/otel-collector.yaml`.

</details>

<details>
<summary>All three fixes (spoilers)</summary>

**Bug 1** `OTEL_EXPORTER_OTLP_ENDPOINT` uses port `:4318`, which is the Collector's HTTP/protobuf port. `OTEL_EXPORTER_OTLP_PROTOCOL` is set to `grpc`, which expects port `:4317`. The hostname resolves, the connection opens, but the request is rejected at the protocol layer. Fix:
```yaml
OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector:4317"
```
Alternatively: change the protocol to `http/protobuf` and leave the port as `:4318`. Both work; `grpc` on `:4317` is preferred within a cluster.

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

In Dash0, open the trace explorer. Three things to find:

1. **The slow trace.** Switch to the Outlier chart. Sort the table by duration. Click into one of the ~2s traces and open the waterfall. Which specific span is taking the two seconds and which service owns it? Look at the HTTP status code on that span. Is it an error?

2. **The error trace.** Find a trace with a failed span. Where does the error originate (order-service or inventory-service)? Does it appear in both services in the same trace, or as two disconnected traces? What does that tell you about how the services are connected?

3. **The Triage view.** Switch to the Triage tab. Set the analysis method to "Compare spans with status ERROR versus OK & UNSET." Which `http.target` is most correlated with errors? Which status codes appear? This is how you'd find the broken endpoint in a system you'd never seen before.

---

## Act 3: Dash0 Operator

`shipping-service` is running in the cluster with zero OTel config. The Dash0 Operator instruments new workloads automatically via a mutating admission webhook, no code changes, no Dockerfile edits.

```bash
helm repo add dash0-operator https://dash0hq.github.io/dash0-operator
helm repo update

helm install dash0-operator dash0-operator/dash0-operator \
  --namespace dash0-system \
  --create-namespace
```

The helm install deploys the operator but doesn't configure the backend. Apply the operator configuration with your credentials (the file uses `${DASH0_OTLP_ENDPOINT}` and `${DASH0_TOKEN}` from your `.env`):

```bash
set -a && source .env && set +a
envsubst < k8s/operator/dash0-operator-configuration.yaml | kubectl apply -f -
```

Label the namespace, create the monitoring resource, then restart the service:

```bash
kubectl label namespace meridian dash0.com/instrumentWorkloads=all
kubectl apply -f k8s/operator/dash0-monitoring.yaml
kubectl rollout restart deployment/shipping-service -n meridian
```

Inspect what the operator injected:

```bash
kubectl describe pod -n meridian -l app=shipping-service
```

You'll see three things the operator injected:

- `dash0.com/instrumented=true` label on the pod
- A `dash0-instrumentation` init container that installed the OTel SDK before the main container started
- `LD_PRELOAD` pointing to `libotelinject.so` — a dynamic library hook that wires up instrumentation at process startup, no code change required

The `OTEL_EXPORTER_OTLP_ENDPOINT` points to `http://$(DASH0_NODE_IP):40318` — the operator's own node-local DaemonSet collector, not our `otel-collector` service. The operator is fully self-contained. shipping-service has no `envFrom`, no reference to `otel-platform-config`. The service name is derived from Kubernetes metadata at runtime. The developer configured nothing.

Now generate some traffic and open Dash0. Within 30–60 seconds you'll see `shipping-service` appear in the trace explorer with spans flowing from a service that had zero OTel config when this act started.

```bash
./scripts/generate-traffic.sh --with-issues
```

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

Run staging and production in separate namespaces. Each namespace gets its own `otel-platform-config` ConfigMap. The production one has `deployment.environment=production`, the staging one has `deployment.environment=staging`. That's the only difference.

Services don't change at all. They use `envFrom: otel-platform-config` in both namespaces. They just inherit from whichever ConfigMap exists in their namespace. A service deployed to `meridian-staging` automatically gets staging attributes. The same service deployed to `meridian-production` gets production attributes. No per-service config, no environment variables in CI, no developer involvement.

With Kustomize you can manage this without duplicating the whole file: a base `otel-platform-config` with shared defaults (endpoint, protocol, service version) and a per-environment overlay that patches only `OTEL_RESOURCE_ATTRIBUTES`. Change the base once and both environments inherit it on the next rollout.

**Collector topology: DaemonSet vs. Deployment**

A Deployment runs a fixed number of Collector replicas anywhere in the cluster. A DaemonSet runs exactly one Collector pod per node.

For application telemetry (traces, service metrics, application logs) a single Collector Deployment is fine. Services send spans to it over the network, it batches and exports to Dash0. That's what this workshop uses. If you also need host-level signals (node CPU and memory, disk I/O, kubelet stats, container runtime metrics) you need a DaemonSet. Those signals require access to the node's filesystem and kubelet API, which a Deployment pod doesn't have. The DaemonSet runs on every node so it can collect local host metrics without network hops.

The common production pattern is both. A DaemonSet for node-level signals, and a Deployment as the aggregation and export layer that the DaemonSet forwards to. The Dash0 operator uses exactly this pattern. It deploys its own DaemonSet Collector on each node (port 40318), which is why `OTEL_EXPORTER_OTLP_ENDPOINT` in the injected pods points to the node IP rather than a cluster service.

The aggregation Deployment is where platform policy lives. It's the `otel-collector` you built in Act 1, the one with `sending_queue`, `retry_on_failure`, and the persistent PVC. In production you'd extend it with multiple exporters to fan out to several backends simultaneously, a `transform` processor to scrub PII from logs before export, and a `tail_sampling` processor to keep 100% of error traces while sampling down healthy ones. All of that happens in one Collector config, applied to every service automatically, with no developer involvement.

**Sampling**

At scale, 100% trace sampling gets expensive. The right answer is tail-based sampling in the Collector. So buffer complete traces, then decide whether to keep them based on whether they had errors, exceeded latency thresholds, or match some other policy. The `tail_sampling` processor handles this. The persistent queue from Bug 3 is a prerequisite. You need durable buffering for tail sampling to work correctly.

**GitOps**

The ConfigMap is a plain manifest. ArgoCD or Flux syncs it like anything else. Treat `otel-platform-config.yaml` as platform infrastructure with its own review process, not application config scattered across service repos. Platform config that gets treated like application config eventually drifts.

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
│   ├── fixed/               # Correct state
│   └── operator/            # Dash0 operator resources for Act 3
└── scripts/
    ├── preflight.sh
    ├── deploy-broken.sh
    ├── generate-traffic.sh
    └── check-act1.sh
```
