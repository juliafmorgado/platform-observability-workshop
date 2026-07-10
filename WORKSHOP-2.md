# Making Observability a First-Class Platform Concern
### Workshop 2 companion — platform tour, run these commands as we go

This is a guided tour of the *fixed* platform (as opposed to [WORKSHOP.md](./WORKSHOP.md), which has you find and fix the bugs yourself). Use it to walk through why each piece exists.

---

## Before we start

```bash
./scripts/preflight.sh
./scripts/deploy-fixed.sh
```

Open `http://localhost:8080` and place an order. Telemetry is already flowing into Dash0.

---

## Section 1 — The ConfigMap pattern

```bash
kubectl describe configmap otel-platform-config -n meridian
kubectl exec -n meridian deploy/order-service -- env | grep OTEL
```

Look at `services/order-service/server.js` line 1 — the only OTel line in the whole service. Look at `k8s/fixed/order-service.yaml` — no OTLP endpoint, no resource attributes in the env block.

**Look for:** `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_PROTOCOL`, `OTEL_RESOURCE_ATTRIBUTES` in `k8s/fixed/otel-platform-config.yaml`. Set once at the namespace level, inherited by every service via `envFrom`.

---

## Section 2 — Persistent queue

```bash
kubectl get configmap otel-collector-config -n meridian -o yaml
```

Look at the `otlp` exporter block in `k8s/fixed/otel-collector.yaml`.

**Look for:** `sending_queue` backed by `file_storage` (survives a Collector pod restart) and `retry_on_failure` (survives a temporary Dash0 outage). This is the production baseline, not an advanced feature.

---

## Section 3 — Collector topology (discussion, no commands)

Deployment vs. DaemonSet. A Deployment is fine for application telemetry (what `otel-collector` is here). A DaemonSet is needed for host-level signals (CPU, disk, node metrics) because those require node access. In production you typically run both — the Dash0 operator brings its own node-local DaemonSet Collector on port `40318`, separate from the cluster `otel-collector` Deployment.

---

## Section 4 — Generate traffic and explore Dash0

```bash
./scripts/generate-traffic.sh --with-issues
```

In Dash0: **Built-in views → All spans**.

**Find 1 — the slow trace:** Outliers chart at the top, sort the table by Duration descending, open a ~2s `POST /orders` trace, open the waterfall. Which span is taking the two seconds, and which service owns it? Check the status code — is it actually an error?

**Find 2 — the error trace:** find a trace with a red ERROR indicator, open the waterfall. Where does the error originate — `order-service` or `inventory-service`? Do both services show up in the same trace?

**Find 3 — Triage:** Triage tab → analysis method "Compare spans with status code ERROR versus OK and UNSET" → scroll to `http.target`. Which endpoint is most correlated with errors? Also check `k8s.pod.name` — that column only exists because of the resource attributes set in Section 1.

---

## Section 5 — Alerting and Agent0 automation

In Dash0: **Checks → Failed checks**.

**Look for:** the "Meridian inventory errors" check firing CRITICAL, and the check detail showing Affected resource (service, version, environment) — that's the resource attributes from Section 1 at work.

Then: **Agent0 → Automations → Alert Root Cause Analysis → open the successful run**.

**Look for:** the automated step checklist (load skill, get failed check, retrieve spans/logs, correlate, check pods, synthesize), the Root Cause Analysis section with a confidence rating and correlation percentages, the Affected Services and Blast Radius table, Suggested Next Steps, and the direct Dash0 links to the evidence.

---

## Section 6 — The operator

`shipping-service` has been running this whole time with zero OTel config.

```bash
helm repo add dash0-operator https://dash0hq.github.io/dash0-operator
helm repo update
helm install dash0-operator dash0-operator/dash0-operator \
  --namespace dash0-system \
  --create-namespace
```

```bash
set -a && source .env && set +a
envsubst < k8s/operator/dash0-operator-configuration.yaml | kubectl apply -f -
```

```bash
kubectl label namespace meridian dash0.com/instrumentWorkloads=all
kubectl apply -f k8s/operator/dash0-monitoring.yaml
kubectl rollout restart deployment/shipping-service -n meridian
```

```bash
./scripts/generate-traffic.sh --with-issues
```

```bash
kubectl describe pod -n meridian -l app=shipping-service
```

**Look for:** `dash0.com/instrumented=true` label, a `dash0-instrumentation` init container with Exit Code 0, `LD_PRELOAD=libotelinject.so`, `OTEL_EXPORTER_OTLP_ENDPOINT` pointing at `$(DASH0_NODE_IP):40318` — and no `OTEL_SERVICE_NAME` anywhere. The operator derives it from Kubernetes metadata at runtime.

Open Dash0 — `shipping-service` should appear within 60 seconds, spans flowing, zero OTel code ever written for it.

---

## If something goes wrong

- **Check not firing:** confirm `generate-traffic.sh --with-issues` is still running. Checks evaluate every minute — wait 2 minutes and refresh Failed checks.
- **Agent0 automation not triggering:** open the automation and click "Test automation" to run it manually.
- **shipping-service not appearing:** wait 60 seconds after the rollout restart, and make sure traffic actually hit it (place orders through the frontend).
- **Operator helm install slow:** normal — keep going, it usually finishes within a minute or two.

---

## Teardown

```bash
kind delete cluster --name meridian-workshop
```

---

## Going deeper

Full architectural notes, topology decisions, GitOps patterns, and sampling strategy are in the [README](./README.md). For the hands-on bug-hunting version of this workshop, see [WORKSHOP.md](./WORKSHOP.md).
