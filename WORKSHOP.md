# Making Observability a First-Class Platform Concern
### Workshop companion — run these commands as we go

---

## Before we start

```bash
./scripts/preflight.sh
./scripts/deploy-broken.sh
```

Open `http://localhost:8080` and place three orders: `widget`, `slow-item`, `broken-item`.

Then open Dash0. Notice anything?

---

## Section 1 — Inspect the platform config

```bash
kubectl describe configmap otel-platform-config -n meridian
kubectl exec -n meridian deploy/order-service -- env | grep OTEL
```

**Look for:** which keys are in the ConfigMap, and which key is missing entirely.

---

## Section 2 — Find the three bugs

```bash
kubectl describe configmap otel-platform-config -n meridian
kubectl logs deployment/order-service -n meridian --tail=20
kubectl get configmap otel-collector-config -n meridian -o yaml
```

**Issue 1 — broken connection:** look for `ECONNREFUSED` in the logs. What port is the endpoint using?

**Issue 2 — missing configuration:** look for `Accessing resource attributes before async attributes settled`. Which key is absent from the ConfigMap?

**Issue 3 — reliability gap:** look at the `otlp` exporter block in the Collector config. What is missing?

---

## Section 2 — Fix and apply

Edit `k8s/broken/otel-platform-config.yaml` and `k8s/broken/otel-collector.yaml`, then:

```bash
kubectl apply -f k8s/broken/otel-platform-config.yaml
kubectl apply -f k8s/broken/otel-collector.yaml
kubectl rollout restart deployment -n meridian
./scripts/check-act1.sh
```

Open Dash0. Both services should now be visible with correct names.

---

## Section 2b — Use the working observability

```bash
./scripts/generate-traffic.sh --with-issues
```

In Dash0, go to Built-in views > All spans.

**Find 1 — the slow trace:** sort the table by Duration descending. Open a slow `POST /orders` trace. In the waterfall, which span is taking 2 seconds and which service owns it?

**Find 2 — the error trace:** find a trace with a red ERROR indicator. Open it. Where did the error originate? Do both services appear in the same trace?

**Find 3 — Triage:** click the Triage tab. Set the analysis method to "Compare spans with status code ERROR versus OK and UNSET". Scroll to `http.target`. Which endpoint is correlated with errors?

---

## Section 3 — The operator

```bash
helm repo add dash0-operator https://dash0hq.github.io/dash0-operator
helm repo update
helm install dash0-operator dash0-operator/dash0-operator \
  --namespace dash0-system \
  --create-namespace

set -a && source .env && set +a
envsubst < k8s/operator/dash0-operator-configuration.yaml | kubectl apply -f -

kubectl label namespace meridian dash0.com/instrumentWorkloads=all
kubectl apply -f k8s/operator/dash0-monitoring.yaml
kubectl rollout restart deployment/shipping-service -n meridian
```

```bash
kubectl describe pod -n meridian -l app=shipping-service
```

**Look for:** `dash0.com/instrumented=true` label, `dash0-instrumentation` init container with Exit Code 0, `LD_PRELOAD` in the env vars.

```bash
./scripts/generate-traffic.sh --with-issues
```

Open Dash0. `shipping-service` should appear within 60 seconds.

---

## Teardown

```bash
kind delete cluster --name meridian-workshop
```

---

## Going deeper

Full architectural notes, topology decisions, GitOps patterns, and sampling strategy are in the [README](./README.md).
