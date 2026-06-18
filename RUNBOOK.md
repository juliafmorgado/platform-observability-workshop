# Workshop Complete Runbook
## Making Observability a First-Class Platform Concern
**PlatformCon — Virtual (90 min) + NYC In-Person (60 min)**

---

## PART 1 — WHAT TO PREPARE

### The repo folder: `platform-observability-workshop`

```
platform-observability-workshop/
├── README.md                              ← participant guide
├── .env.template                          ← DASH0_TOKEN + DASH0_OTLP_ENDPOINT placeholders
├── services/
│   ├── order-service/
│   │   ├── index.js                       ← Express app, ~40 lines
│   │   ├── package.json
│   │   └── Dockerfile
│   ├── inventory-service/
│   │   ├── index.js                       ← Express app, slow-item + broken-item
│   │   ├── package.json
│   │   └── Dockerfile
│   └── shipping-service/                  ← zero OTel, for operator demo
│       ├── index.js
│       ├── package.json
│       └── Dockerfile
├── frontend/
│   └── index.html                         ← order form at localhost:8080
├── k8s/
│   ├── broken/
│   │   ├── namespace.yaml
│   │   ├── otel-platform-config.yaml      ← BUG 1 + BUG 2 live here
│   │   ├── otel-collector.yaml            ← BUG 3 lives here
│   │   ├── order-service.yaml             ← uses envFrom, no per-service OTEL vars
│   │   ├── inventory-service.yaml         ← uses envFrom, no per-service OTEL vars
│   │   └── shipping-service.yaml          ← zero OTel
│   └── fixed/
│       ├── otel-platform-config.yaml      ← correct endpoint + resource attributes
│       ├── otel-collector.yaml            ← sending_queue + PVC + retry
│       ├── order-service.yaml
│       ├── inventory-service.yaml
│       ├── shipping-service.yaml
│       └── namespace.yaml
└── scripts/
    ├── preflight.sh                        ← checks Docker, kind, kubectl, helm, .env
    ├── deploy-broken.sh                    ← builds images, creates cluster, deploys broken state
    ├── generate-traffic.sh                 ← accepts --with-issues flag
    └── check-act1.sh                       ← validates all three fixes at the platform level
```

---

### The three broken things

**Important framing shift**: none of the bugs are in service deployment YAMLs. All three are platform-level misconfigurations. The fix for each is one place — and propagates to every service automatically.

---

**Broken thing 1 — Protocol/port mismatch (platform misconfiguration)**

`k8s/broken/otel-platform-config.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-platform-config
  namespace: meridian
data:
  # BUG 1: gRPC protocol pointed at the HTTP port (:4318) — gRPC expects :4317
  OTEL_EXPORTER_OTLP_PROTOCOL: "grpc"
  OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector:4318"
  # BUG 2: OTEL_RESOURCE_ATTRIBUTES is absent
```

The OTel Collector has two receivers on two different ports: gRPC on `:4317`, HTTP/protobuf on `:4318`. They are not interchangeable. With `grpc` protocol pointing at `:4318`, the SDK connects successfully — hostname resolves, TCP handshake works, the port is open — but the HTTP receiver at `:4318` doesn't speak gRPC. Every span export fails at the protocol layer. No crash. No DNS error. Spans just don't arrive.

This is deliberately harder than a wrong hostname. A wrong hostname fails fast with a DNS NXDOMAIN. A port mismatch like this fails quietly — the connection looks fine from both sides, but they're speaking different languages once the handshake is done.

Fix: change the port in `OTEL_EXPORTER_OTLP_ENDPOINT` from `:4318` to `:4317`:
```yaml
OTEL_EXPORTER_OTLP_ENDPOINT: "http://otel-collector:4317"
```
```bash
kubectl apply -f k8s/broken/otel-platform-config.yaml
kubectl rollout restart deployment -n meridian
```
One change. Both services unblocked. That's the point.

---

**Broken thing 2 — Missing resource attributes (missing platform standard)**

Same file, same fix. `OTEL_RESOURCE_ATTRIBUTES` is absent from the ConfigMap entirely. Spans arrive at Dash0 with no `service.version`, no `deployment.environment`. You can't filter by environment, can't alert on version regressions.

Fix: add the key to `otel-platform-config.yaml`:
```yaml
OTEL_RESOURCE_ATTRIBUTES: "service.version=1.0.0,deployment.environment=production"
```
Apply + rollout restart (same commands as Bug 1). Every service in the namespace inherits it.

---

**Broken thing 3 — Collector has no persistent queue (platform reliability gap)**

`k8s/broken/otel-collector.yaml` configures the `otlp` exporter with no `sending_queue` and no `retry_on_failure`. When the Collector pod restarts during a node rotation — or when Dash0 is temporarily unreachable — all queued telemetry is silently lost.

```yaml
# BROKEN — fire and forget
exporters:
  otlp:
    endpoint: ${DASH0_OTLP_ENDPOINT}
    headers:
      Authorization: "Bearer ${DASH0_TOKEN}"
    # no sending_queue, no retry_on_failure
```

Fix (in `k8s/broken/otel-collector.yaml`):
```yaml
extensions:
  file_storage:
    directory: /var/lib/otelcol/file_storage

exporters:
  otlp:
    endpoint: ${DASH0_OTLP_ENDPOINT}
    headers:
      Authorization: "Bearer ${DASH0_TOKEN}"
    sending_queue:
      enabled: true
      num_consumers: 10
      queue_size: 10000
      storage: file_storage
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s

service:
  extensions: [file_storage]
```

The fixed Collector also mounts a `PersistentVolumeClaim` (not `emptyDir`) for queue storage — so the queue actually survives pod restarts instead of just surviving config restarts. See `k8s/fixed/otel-collector.yaml` for the complete manifest.

Apply:
```bash
kubectl apply -f k8s/broken/otel-collector.yaml
kubectl rollout restart deployment/otel-collector -n meridian
```

---

### Scripts

**scripts/generate-traffic.sh**
```bash
#!/usr/bin/env bash
ORDER_API="${ORDER_API:-http://localhost:3000}"

while true; do
  curl -s -X POST "$ORDER_API/orders" \
    -H "Content-Type: application/json" \
    -d '{"item":"widget","quantity":2}' > /dev/null

  if [[ "${1:-}" == "--with-issues" ]]; then
    curl -s -X POST "$ORDER_API/orders" \
      -H "Content-Type: application/json" \
      -d '{"item":"slow-item","quantity":1}' > /dev/null

    curl -s -X POST "$ORDER_API/orders" \
      -H "Content-Type: application/json" \
      -d '{"item":"broken-item","quantity":1}' > /dev/null
  fi

  sleep 2
done
```

**scripts/check-act1.sh** — validates platform state, not per-service state
```bash
#!/usr/bin/env bash
echo ""
echo "=== Act 1 Verification — Three Platform Fixes ==="
echo ""

# Check 1: ConfigMap has correct collector endpoint
CM_ENDPOINT=$(kubectl get configmap otel-platform-config -n meridian \
  -o jsonpath='{.data.OTEL_EXPORTER_OTLP_ENDPOINT}' 2>/dev/null || echo "")

[ "${CM_ENDPOINT}" = "http://otel-collector:4317" ] \
  && echo "✅ otel-platform-config endpoint → http://otel-collector:4317" \
  || echo "❌ otel-platform-config endpoint is '${CM_ENDPOINT}' — fix it in k8s/broken/otel-platform-config.yaml"

# Check 2: ConfigMap has resource attributes
CM_ATTRS=$(kubectl get configmap otel-platform-config -n meridian \
  -o jsonpath='{.data.OTEL_RESOURCE_ATTRIBUTES}' 2>/dev/null || echo "")

echo "${CM_ATTRS}" | grep -q "service.version" && echo "${CM_ATTRS}" | grep -q "deployment.environment" \
  && echo "✅ otel-platform-config has OTEL_RESOURCE_ATTRIBUTES" \
  || echo "❌ otel-platform-config missing OTEL_RESOURCE_ATTRIBUTES — add it to k8s/broken/otel-platform-config.yaml"

# Check 3: Collector has persistent queue
COLLECTOR_CONFIG=$(kubectl get configmap otel-collector-config -n meridian \
  -o jsonpath='{.data.config\.yaml}' 2>/dev/null || echo "")

echo "${COLLECTOR_CONFIG}" | grep -q "sending_queue" && echo "${COLLECTOR_CONFIG}" | grep -q "storage:" \
  && echo "✅ Collector sending_queue with persistent storage" \
  || echo "❌ Collector missing sending_queue — fix k8s/broken/otel-collector.yaml"

echo "${COLLECTOR_CONFIG}" | grep -q "retry_on_failure" \
  && echo "✅ Collector retry_on_failure configured" \
  || echo "❌ Collector missing retry_on_failure"
```

---

### What to send participants 48 hours before

> Subject: PlatformCon Workshop — 5 min setup before Thursday
>
> Hey! Really excited for the workshop on Thursday. To make sure we can jump straight in, please do this before you arrive:
>
> 1. Install Docker Desktop, kind, kubectl, and helm if you don't have them
> 2. Create a free Dash0 account at app.dash0.com — takes 2 min
> 3. Grab your auth token from Settings → Auth Tokens, and your OTLP endpoint from Settings → Endpoints
> 4. Clone the repo: `git clone https://github.com/juliafmorgado/platform-observability-workshop`
> 5. `cd dash0-examples/platform-observability-workshop`
> 6. Copy `.env.template` to `.env` and fill in your token and endpoint
> 7. Run `./scripts/preflight.sh` — it checks everything is installed and your credentials work
>
> If preflight fails or you hit any issues, reply to this email or join `#workshop-help` [link]. I'll be checking it the morning of.
>
> See you Thursday! Julia

---

### Your own setup the morning of the workshop

- Run `./scripts/deploy-broken.sh` at least 30 min before start
- Run `./scripts/generate-traffic.sh` (without `--with-issues`) for 15+ min so there's baseline data in Dash0
- Open Dash0 — nothing meaningful should be showing, or services should be unnamed/missing. Screenshot this as your opening slide backup
- Have VS Code open with `services/order-service/index.js`, font size 20+
- Have `k8s/broken/otel-platform-config.yaml` open in a second tab
- Have `k8s/broken/otel-collector.yaml` open in a third tab
- Pre-type the helm operator install command in a notes file — copy-paste only, never type live
- Test that slow and broken traffic actually flows:
  ```bash
  curl -s -X POST localhost:3000/orders -H "Content-Type: application/json" -d '{"item":"slow-item","quantity":1}'
  curl -s -X POST localhost:3000/orders -H "Content-Type: application/json" -d '{"item":"broken-item","quantity":1}'
  ```
- Have the participant guide URL in a short link ready to paste into chat
- For virtual: share your screen before the session starts

---

## PART 2 — THE COMPLETE SCRIPT

> **How to use this section:** Everything in quotes is verbatim. Read it, internalize it, then say it in your own voice — don't read it off the page. Stage directions are in [brackets]. Timing is approximate; if a section runs long, cut from the hands-on blocks, not the demo sections.

---

### OPENING + INSTRUMENTATION + SCENE SETTING (0:00–0:13)

**What's on screen:** The Meridian frontend at `http://localhost:8080`. Three tabs ready but hidden: frontend, broken Dash0, a working Dash0 trace from a prior run. VS Code open behind.

---

"Ok — if you're still setting up, just watch.

This is Meridian. E-commerce company. Simple order form."

[fill in `widget`, quantity `2`, submit — immediately]

[order confirms fast]

"Works. Fast. Good.

One more."

[fill in `slow-item`, quantity `1`, submit]

[wait. Don't talk. Let the two seconds happen.]

"...two seconds. Maybe a customer blames their internet. Maybe they don't.

One more."

[fill in `broken-item`, quantity `1`, submit]

[500 error]

"Failed. Customer got an error. The CTO's message: 'Orders are slow and failing — why can't we see this?'

Let me show you."

[switch to Dash0 — broken state, empty]

[pause — let people look]

"Nothing. No services. No traces. Three requests just happened — one slow, one failed — and Dash0 has no record of any of it.

So. Why?"

[switch to VS Code — `services/order-service/index.js`, font size 20+, scroll to top]

"This is order-service. Express app. Takes orders, calls inventory-service. Look at line 4."

[pause on line 4]

"`require('@opentelemetry/auto-instrumentations-node/register')`

One line. That's the entire OTel code in this service. No manual spans, no tracers, no propagation code.

What does it do? At startup, it monkey-patches the modules already in `node_modules` — `http`, `express`, `axios`, all of them. Every incoming request gets a span automatically. Every outgoing call gets a span. Trace context propagates to the next service. The developer doesn't write any of that — they add the require, and the SDK handles the rest.

The developer did their job."

[pause]

[switch to `k8s/broken/order-service.yaml`]

"Now the deployment YAML. The env block."

[scroll to env — shows PORT, INVENTORY_SERVICE_URL, OTEL_SERVICE_NAME only]

"No `OTEL_EXPORTER_OTLP_ENDPOINT`. No `OTEL_RESOURCE_ATTRIBUTES`. Where do those come from?

Here."

[switch to `k8s/broken/otel-platform-config.yaml`]

"This is `otel-platform-config`. A ConfigMap at the namespace level. Both services have `envFrom: configMapRef: otel-platform-config` in their specs — every key in here becomes an env var in every container that references it.

Exporter endpoint: one place. Resource attributes: one place. Protocol: one place. You change this ConfigMap, do a rollout restart, and every service in the namespace picks it up. No per-service YAML edits. No asking developers to change anything.

One file controls the observability config for the whole namespace.

When this file is correct — you get this."

[switch to pre-loaded working Dash0 trace tab — don't hunt for it live]

"A full distributed trace. Both services. The call chain from order-service to inventory-service. Latency on every hop. Error messages when something fails. Service graph. HTTP status codes.

The developer's code? Still just that one require line. Everything here came from the platform config — which is our job.

So when I say the problem isn't in the service code — I mean it. The instrumentation is there. The auto-instrumentation works. The problem is in the platform config. Two files: this ConfigMap and the Collector config.

I'm not going to tell you what's wrong with them. That's your job.

Open `http://localhost:8080`. Place the same three orders: `widget`, `slow-item`, `broken-item`. Watch what happens. Write it down.

Then open Dash0. Notice the gap between what you saw in the browser and what Dash0 shows you.

Then start here — not in the service YAMLs, here:"

[show terminal]

```bash
kubectl describe configmap otel-platform-config -n meridian
kubectl logs deployment/otel-collector -n meridian --tail=30
```

"If something is wrong with all services — not one, all — it's almost certainly in the ConfigMap or the Collector. That's the instinct.

Three things are wrong. Find all three before you fix any of them. Once you have all three, apply everything at once:

```bash
kubectl apply -f k8s/broken/otel-platform-config.yaml
kubectl apply -f k8s/broken/otel-collector.yaml
kubectl rollout restart deployment -n meridian
```

Two files, one restart. Hints are in the README if you're stuck after ten minutes.

Go."

[set timer — visible on screen for virtual, physical timer or slide for in-person]

**Questions you'll get here:**

**Q: Why a ConfigMap and not just env vars directly in each deployment YAML?**
A: Because that's how you end up with 47 services all named `my-service`. I once consulted for a team — someone copy-pasted a deployment YAML, changed everything except `OTEL_SERVICE_NAME`, and deployed. They had perfect traces. No idea which service any of them belonged to. A ConfigMap is a single source of truth. Change it once, roll out, done. Per-deployment env vars are copy-paste culture waiting to diverge.

**Q: What if two services need different OTLP endpoints?**
A: A per-pod `env` entry overrides `envFrom` — so a team can always override the default if they genuinely need to. But the right question is: why do they need a different backend? Usually it's "they set it up before the platform had an opinion." The Collector actually solves this better — one pipeline, multiple exporters, teams don't change anything. We'll see that in the architecture breakout.

**Q: Can't developers just put these in their `.env` and configure in CI?**
A: CI/CD shouldn't be the source of truth for runtime observability config. If you need to emergency-change the Collector endpoint, you want `kubectl apply` — not a triggered pipeline. Runtime config belongs in the cluster, not in the build.

---

### ACT 1 WORK BLOCK (0:15–0:35)

**What's on screen:** Timer. Participant guide URL in chat. Your Dash0 broken state open on one side.

**You:** Walk around the room. Check in with each group every few minutes. For virtual: monitor chat closely, respond to questions.

---

**What to say when you check in with a group:**

"What have you found so far?" [listen] "Have you applied any fixes yet, or are you still in investigation mode?"

[If they've already applied mid-investigation: "That works — but next time, try finding all three before you touch anything. You'll get a clearer picture of what's broken before you start changing it."]

If they've found Bug 1 already: "Good. Don't fix it yet — what else do you see in that ConfigMap? Look at all the keys. What should be there that isn't?"

If they're stuck on Bug 1: "The Collector looks healthy — the error is not there. Check the service logs: `kubectl logs deployment/order-service -n meridian --tail=20`. You'll see a gRPC export error. Then check what port the endpoint is using: `kubectl describe configmap otel-platform-config -n meridian`. Now compare it to what the Collector actually listens on: `kubectl get svc otel-collector -n meridian -o yaml`. The Collector listens for gRPC on :4317 and HTTP/protobuf on :4318. Which port is the ConfigMap using for a gRPC client?"

**What the service logs actually show — and what each line means:**

When someone runs `kubectl logs deployment/order-service -n meridian --tail=20`, they'll see roughly this:

```
OTEL_LOGS_EXPORTER is empty. Using default otlp exporter.
OTEL_TRACES_EXPORTER is empty. Using default otlp exporter.
OpenTelemetry automatic instrumentation started successfully
order-service listening on :3000
Accessing resource attributes before async attributes settled
Accessing resource attributes before async attributes settled
Accessing resource attributes before async attributes settled
{"grpcCode":"UNAVAILABLE","message":"Export failure — failed to connect to otel-collector:4318"}
```

Here's how to narrate each part:

**The good lines** — `OpenTelemetry automatic instrumentation started successfully` and `order-service listening on :3000`. SDK loaded fine, auto-instrumentation is active, service is healthy. The developer did their job. These are completely normal.

**The suspicious line** — `Accessing resource attributes before async attributes settled` appears three times. This is Bug 2 introducing itself: `OTEL_RESOURCE_ATTRIBUTES` isn't set, so the SDK tries to read resource attributes before they're ready. Not fatal, won't crash anything, but it's a hint. If attendees ask: "That's Bug 2 showing up — something's missing from the platform config."

**The line that reveals Bug 1:** A gRPC export error — `UNAVAILABLE` or `UNIMPLEMENTED`. The SDK opened a TCP connection to port `:4318` successfully — hostname resolved, TCP handshake worked, the port is actually open. But `:4318` is the Collector's HTTP/protobuf receiver. The gRPC client connects and starts speaking HTTP/2 with `Content-Type: application/grpc`, but the HTTP receiver doesn't understand it and rejects the request.

The key teaching point: this is not "connection refused" and not a DNS error. The connection worked. The hostname resolved. The port answered. It's a protocol mismatch once the connection is open — they shook hands and then started speaking different languages. That's why it's subtle and the service keeps running. One digit off in the endpoint port. Both services dark.

How to say it to the room: "The service is healthy. The Collector is running. The hostname is correct. So what's wrong? The port. The Collector has two listeners — gRPC on 4317, HTTP on 4318. The config is sending gRPC traffic to port 4318. The connection opens, both sides think they're talking, and then the protocol fails. One digit. That's it. Fix the port, do a rollout restart, both services come back."

If they've found Bug 1 and 2: "Nice — now the Collector. Open `kubectl get configmap otel-collector-config -n meridian -o yaml`. Look at the `otlp` exporter block. What happens to spans that are in-flight when the Collector pod restarts? What does the config do about that?"

If they've found all three but haven't applied yet: "Perfect. Now fix both files — `otel-platform-config.yaml` and `otel-collector.yaml`. Then apply both and do one rollout restart. Two files, three commands, done."

If they ask "how do we know it's the Collector and not the backend?": "Check the Collector logs — `kubectl logs deployment/otel-collector -n meridian`. You'll see either connection errors to the wrong host, or nothing — which means spans aren't reaching the Collector at all."

---

**Anecdotes to share while circulating (drop these naturally):**

On Bug 1 — if someone is hunting through service YAMLs looking for the endpoint:
> "The tell here is that both services are affected. When one service is dark, look in that service's config. When all services are dark, look at the shared platform config. That instinct saves a lot of time."

On Bug 3 — if someone finds the Collector config looks sparse:
> "Real story. At a previous job, we had a node rotation at 2am. The Collector restarted. No persistent queue, no retry. We lost maybe four minutes of telemetry — which happened to be the four minutes when a database failover was happening. The incident review went great except for the part where we had no data for the exact window when everything broke. The fix was literally one YAML block. Painful lesson."

On Bug 2 — if someone asks why resource attributes matter:
> "Open Dash0 right now and try to filter traces by `deployment.environment`. Nothing comes back. Now imagine you're a company running staging and production in the same cluster. How do you tell them apart? How do you build an alert that only fires in production? Without `deployment.environment` on every span, you can't. It's not decoration — it's how you make the data actually usable."

---

**What to watch for:**

- Bug 1 is trickier than it looks — the hostname resolves, the port is open, and the connection establishes. People typically find it by noticing the port number doesn't match the protocol, or by seeing the gRPC export error in service logs. It should take 5-8 minutes with the logs hint
- Bug 2 takes longer because people look in service YAMLs first instead of the ConfigMap. Let them discover this on their own — the "oh, it's not per-service, it's in the shared ConfigMap" moment is the whole lesson
- Bug 3 is the hardest. Most people haven't written Collector configs from scratch. That's fine — use the debrief to teach it

---

### ACT 1 DEBRIEF (0:35–0:40)

**What's on screen:** YOUR fixed Dash0 — both services visible, correct names, `deployment.environment=production`, `service.version=1.0.0` showing in span attributes. Have this pre-loaded on your machine.

**What the fixed UI looks like:** The trace explorer shows a span table with both `order-service` and `inventory-service`. The latency chart at the top has a dotted line at ~2s — that's the `slow-item` requests sitting as outliers. You'll see red ERROR dots in the timeline. In the span list: `POST /orders` (order-service, ROOT), `GET /stock/:item` (order-service, CLIENT), `GET /stock/:item` (inventory-service, SERVER) — the full distributed call chain. `GET /stock/broken-item` appears as an error span. The p99 will be around 2s.

---

"Ok. Timer's up. Let's look at what fixed looks like."

[show fixed Dash0 — point at the latency chart first, then the span table]

"Two services. Both visible. Look at the latency chart — that dotted line at two seconds is our slow-item requests. They're not random noise, they're consistent. Every single `slow-item` order takes exactly two seconds.

Look at the span table. `POST /orders` from order-service — that's the entry point, marked ROOT. Below it, `GET /stock/:item` from order-service as a CLIENT span calling inventory-service, and `GET /stock/:item` from inventory-service as the SERVER span receiving it. One trace, two services, the full call chain visible.

And the errors — `GET /stock/broken-item` is right there. You can see it failed. You can see where it failed.

This is what the platform was supposed to be showing you the whole time.

Before I show you the fixes — quick question. How many apply commands did you run? How many rollout restarts?"

[wait for answers — most people will have done multiple]

"The answer should be: two applies and one rollout restart. Two files changed. One restart that propagated everything. If you did it iteratively — fix one thing, apply, find the next thing, apply again — that's fine, it works, but next time try diagnosing everything first. You'll save two restarts and you'll have a much clearer picture of what you're actually changing before you change it.

Let me show you what changed."

[switch to `k8s/fixed/otel-platform-config.yaml`]

"Here's the fixed platform config. Two things different from the broken version."

[give people a moment to read it]

"Two things. First — protocol and port.

The OTel Collector has two receivers: gRPC on port 4317, HTTP/protobuf on port 4318. They are not the same port, they are not interchangeable, and the Collector will silently reject spans that arrive on the wrong one.

The broken config had `OTEL_EXPORTER_OTLP_PROTOCOL: 'grpc'` pointing at port 4318. The SDK connected successfully — hostname resolves, TCP handshake works, the port is actually open and listening. But port 4318 is the HTTP receiver. When the gRPC client connects and starts speaking gRPC, the HTTP receiver rejects it. Every batch of spans failed. No crash. No DNS error. Service stayed up. Collector stayed up. Spans just never arrived.

This is the class of failure that's worse than a hostname typo. A wrong hostname fails fast — you see DNS errors immediately. A port mismatch like this fails silently at the protocol layer, and the system looks healthy while your observability is dead. Could run for days.

Fix: `OTEL_EXPORTER_OTLP_ENDPOINT: 'http://otel-collector:4317'`. One digit. Both services unblocked.

Second — `OTEL_RESOURCE_ATTRIBUTES`. Completely absent in the broken version. This is where `service.version` and `deployment.environment` come from. Without it, spans arrive with no version, no environment. You can't filter by environment. You can't alert on version regressions. And here's the one people don't think about: resource attributes are stamped on every span. If you accidentally put a high-cardinality value here — pod name, user ID, request ID — you've just multiplied your ingestion cost by the cardinality of that field. Keep resource attributes low-cardinality. High-cardinality values belong on individual spans."

[switch to `k8s/fixed/otel-collector.yaml`]

"And the Collector. In the broken version, the `otlp` exporter had no `sending_queue` and no `retry_on_failure`. What that means in practice: the Collector receives a batch of spans, attempts to export them to Dash0, and if that export fails for any reason — network blip, Dash0 briefly unreachable, Collector pod restarting — those spans are gone. No retry. No buffer. Gone.

The fix has two parts. Walk through each piece — every line here does something specific.

First, the Collector config:

```yaml
extensions:
  file_storage:
    directory: /var/lib/otelcol/file_storage
```

This defines a directory on disk where spans are written before export. Without this, the queue only lives in memory — it survives backend blips but disappears when the pod restarts.

```yaml
service:
  extensions: [file_storage]
```

Extensions in the OTel Collector are declared separately from where they're used. This line actually loads the extension at startup. If you define `file_storage` but forget this line, the extension never initializes and the queue silently falls back to in-memory. No error, no warning.

```yaml
sending_queue:
  enabled: true
  storage: file_storage
```

Tells the exporter to write spans to disk before attempting export. The queue decouples receiving from exporting — the Collector keeps accepting spans from services even when the backend is slow or unreachable.

```yaml
retry_on_failure:
  enabled: true
  initial_interval: 5s
  max_interval: 30s
  max_elapsed_time: 300s
```

Without this, a failed export is dropped even with the queue configured. The queue holds the spans. Retry is what actually re-attempts sending them. Exponential backoff from 5 seconds, capped at 30 seconds per attempt, gives up entirely after 5 minutes total — at which point the queue fills up anyway.

Second — and this is the subtle part — the Deployment mounts a PVC at that same directory:

```yaml
volumeMounts:
  - name: queue-storage
    mountPath: /var/lib/otelcol/file_storage
volumes:
  - name: queue-storage
    persistentVolumeClaim:
      claimName: otel-collector-queue
```

Without the PVC, `file_storage` writes to the container's ephemeral filesystem. The queue works, right up until the pod restarts, at which point the filesystem is gone and so is the queue. You can have every config line correct and still lose data if you forget the volume mount.

That is the difference between losing four minutes of data during a node rotation and not losing it."

**Note — Bug 3 is not visible in normal operation.** Unlike Bugs 1 and 2, you won't see anything wrong in Dash0 until the Collector restarts or the backend blips. If you want to make it tangible, do this live:

```bash
# while generate-traffic.sh is running — kill the Collector pod
kubectl delete pod -n meridian -l app=otel-collector
```

With the broken config, spans generated during the ~30 second restart window are gone. You'll see a gap in the Dash0 timeline. With the fixed config and PVC, the queue flushes after the pod comes back and the gap doesn't appear.

For a 90-minute session this demo is optional — the node rotation story lands without it. For a more technical audience or a longer session, killing the pod live is a strong moment.

[pause]

"Now here's the thing I want you to notice about those fixes."

[switch back to VS Code — show the service YAMLs briefly]

"What files did we edit?

`otel-platform-config.yaml`. `otel-collector.yaml`.

That's it. Two files.

What files did we NOT edit?"

[pause for effect]

"`order-service.yaml`. `inventory-service.yaml`. We didn't touch a single service deployment. We didn't grep through pod specs. We didn't ask any developer to change anything."

[pause]

"You didn't fix order-service. You didn't fix inventory-service. You fixed the platform. That's the difference between a platform engineer and someone who's just doing support at a slower pace."

[quick poll — for virtual use chat/reaction]

"Quick question — who found all three? Show of hands. Who found two? Who found one? That's normal — Bug 3 is genuinely hard the first time. Most people haven't had to write a production Collector config from scratch. But now you know what one looks like. And more importantly, now you know what a broken one costs."

**Questions you'll get here:**

**Q: Why does `OTEL_SERVICE_NAME` have to be per-service? Why can't it come from the ConfigMap?**
A: The ConfigMap is shared across all services — it can't know the name of each consumer. It's like asking your `/etc/hosts` file to know which app is using it. But it doesn't have to stay hardcoded forever. There's a Kubernetes Downward API pattern that derives it from the pod's own `app` label — `fieldRef: fieldPath: "metadata.labels['app']"`. That's in the Bonus section of the README, and it's exactly what the Dash0 operator does automatically in Act 3.

**Q: What's the difference between `OTEL_SERVICE_NAME` and `OTEL_RESOURCE_ATTRIBUTES`?**
A: `OTEL_SERVICE_NAME` maps directly to `service.name` in the OTel resource model — it's the primary identity of a service. `OTEL_RESOURCE_ATTRIBUTES` is a catch-all key=value string for everything else: `service.version`, `deployment.environment`, `team.name`, `k8s.cluster.name`, whatever your platform needs. You can technically put `service.name=order-service` inside `OTEL_RESOURCE_ATTRIBUTES`, but `OTEL_SERVICE_NAME` takes precedence and is the correct place for it. Think of it as: `OTEL_SERVICE_NAME` is the required field, `OTEL_RESOURCE_ATTRIBUTES` is the metadata.

**Q: gRPC or HTTP for the exporter?**
A: gRPC is lower overhead and more efficient — it's the standard for service-to-Collector within a cluster. HTTP/protobuf is easier to debug and works through more proxies and firewalls. In a Kubernetes cluster where services can reach the Collector directly, use gRPC. If you're exporting through something that doesn't handle gRPC well, use HTTP.

**Q: Why not use a Collector `resource` processor to stamp resource attributes, instead of env vars?**
A: Both work. Env vars are simpler for per-namespace attributes and keep the config visible at the deployment level — any engineer can look at a pod's env and see what environment it's in. The Collector `resource` processor is better for cluster-wide attributes like `k8s.cluster.name` or `cloud.region` that you want applied uniformly regardless of what the service declares. In production you'd often do both — env vars for namespace-level defaults, Collector processor for cluster-level enrichment.

**Q: What should go in `OTEL_RESOURCE_ATTRIBUTES`? What shouldn't?**
A: Resource attributes are stamped on every span emitted by the service — they're baked into the resource model, not the span itself. Keep them low-cardinality: `service.version`, `deployment.environment`, `team.name`, `k8s.cluster.name`. Do not put high-cardinality values here — pod names, user IDs, request IDs. Backends that build dimensions or indexes from resource attributes will explode in cardinality, and you'll pay for it in storage and query cost. High-cardinality values belong on individual spans as span attributes.

**Q: How do you handle staging vs. production with this pattern?**
A: Separate namespaces, separate ConfigMaps. `otel-platform-config` in `meridian-staging` has `deployment.environment=staging`, same file, different value. With Kustomize: a base ConfigMap with shared defaults and per-environment overlays that patch `OTEL_RESOURCE_ATTRIBUTES`. The endpoint can point to the same Dash0 org with environment-based filtering, or different backends per environment. Either way, the service config is identical — they inherit from whatever ConfigMap is in their namespace and don't need to know which one.

**Q: How do I manage this with GitOps?**
A: The ConfigMap is just a manifest — ArgoCD or Flux syncs it like anything else. The discipline is: treat `otel-platform-config.yaml` as platform infrastructure, not application config. It belongs in your platform team's repo with its own review process, not scattered across service repos where it'll drift. Platform config that gets treated like application config eventually ends up like application config — inconsistent.

---

### ACT 2 INTRO (0:40–0:42)

**What's on screen:** Dash0 with traffic flowing normally. Both services visible, clean baseline data.

---

"Ok. You've fixed the observability stack. Now let's use it.

Remember the CTO's message — orders are slow, some are failing silently. We couldn't see it before because the platform was broken. Now we can see everything.

I'm going to run a script that simulates what was happening in production. A mix of normal traffic, some slow requests, and some requests that fail completely. This is what the system was doing while no one could see it."

[run `./scripts/generate-traffic.sh --with-issues` in your terminal — have it pre-aliased so it's one command]

"Watch your Dash0. Give it about 30 seconds for the data to flow through."

[wait — don't fill the silence unnecessarily. Let people watch their dashboards update. If something shows up, narrate it briefly: "There — see that? That's a trace coming through."]

---

### AGENT0 DEMO (0:42–0:52)

**What's on screen:** Dash0 trace explorer showing anomalous traffic, then Agent0.

---

[after data starts appearing — you should see some high-latency traces and some error traces]

"Ok. Here's what a normal person does now: they open the trace explorer, sort by duration, start clicking through traces one by one, look for patterns, try to correlate error rate to latency, maybe build a dashboard. It works. It takes twenty minutes.

Here's what I'm going to do instead."

[open Agent0]

"I'm going to ask."

[type: `What's wrong with order-service right now?`]

[hit submit — then stop talking. Seriously, stop. Let the audience watch the hypothesis tree build. The silence is fine. The loading animation is interesting. Don't narrate it.]

[wait for Agent0 to respond — usually 15-30 seconds]

"Watch what it's doing. It's not just running a search. It's forming hypotheses — 'is this a latency problem? an error rate problem? is it correlated to a specific endpoint?' — and querying your actual telemetry to test each one. The hypothesis tree you can see on the left is it showing its work.

Every SRE does this at 2am. They just do it slower, with more coffee, and with more 'wait, let me check one more thing' loops."

[once it returns — it should surface something about slow inventory-service responses and failures on broken-item]

"There it is.

It found the slow path — `inventory-service /stock/slow-item` with two-second latency. And it found the failure path — `inventory-service` returning 500 on `broken-item`, propagating up to `order-service`.

And notice — it's not just saying 'inventory-service is slow.' It's showing you the specific span, the specific endpoint, the specific latency percentile. This is a diagnosis, not a guess."

[ask the follow-up question]

"Let me ask it something more specific."

[type: `Which endpoint is causing the latency spikes and what's the P95?`]

[let it run]

[while waiting]

"Here's what I want you to think about. Right now, forty minutes ago, the Collector was misconfigured. inventory-service was completely dark. Traces were being sent to the Collector and rejected at the protocol layer — gRPC listener, HTTP/protobuf client. None of that data was reaching Dash0.

If I had tried to ask Agent0 this question forty minutes ago, what would it have said? It would have said 'I don't see any significant issues with order-service.' Because it's only as smart as the data it has. It can't tell you what it can't see.

The fixes you did in Act 1 didn't just make the dashboard look nicer. They made this conversation possible. The data quality is the foundation. Everything above it — the AI, the alerts, the dashboards — is only as good as what the platform is sending."

[Agent0 returns with the P95]

"That's the chain."

**Questions you'll get here:**

**Q: What LLM is Agent0 using?**
A: We don't publish the specific model. The more interesting architectural point is that Agent0 isn't just forwarding your question to a general-purpose LLM and hoping for the best. It has structured access to your actual telemetry — span indexes, metric time series, log aggregations — and it queries those directly to ground its answers. The LLM is doing reasoning and synthesis over real data from your cluster, not pattern-matching from training data.

**Q: How do I know the answer isn't hallucinated?**
A: The hypothesis tree is the answer to that. Every conclusion Agent0 reaches is backed by a specific query result you can click into. It shows you what it looked at and why it concluded what it did. Treat it like a junior engineer who shows their research: trust but verify. If the underlying telemetry is clean, the answers are grounded in your actual system state.

**Q: Can it create PromQL queries I can export elsewhere?**
A: Dashboards and alerts are native to Dash0. If you need to export queries — worth raising with the product team directly.

**Q: Does it have access to logs?**
A: All three signals — traces, metrics, and logs — if you're sending them. Logs become especially useful once Agent0 has identified a problematic span and you want to correlate it to log lines from the same request. The more complete the telemetry, the more correlation is possible.

---

### ACT 2 HANDS-ON (0:52–1:00)

**What's on screen:** Dash0 trace explorer.

---

"Ok your turn. Same data, your hands.

Three things I want you to find.

One — open the trace explorer. Switch the chart to Outlier view. Sort the table by duration. Click into one of the two-second traces and open the waterfall. Which specific span is taking the two seconds? Is the slowness in order-service or inventory-service? Look at the HTTP status code on that span.

Two — find a failed trace. Where does the error originate? Does it appear in both services in the same waterfall, or as two disconnected traces?

Three — switch to the Triage tab. Set analysis to 'Compare spans with status ERROR versus OK and UNSET.' Which http.target is most correlated with errors? Which status codes? This is the view you'd use on a system you'd never seen before.

Eight minutes. Go."

[give people eight minutes — walk around, watch over shoulders]

---

**What the UI looks like at this point:**

Two views are worth walking through explicitly.

**Table view + Outlier chart** — the starting point. At the top of the span explorer, the outlier chart has a dotted line at 2.01s. All normal spans cluster near zero. Every slow-item request sits exactly on that ceiling — consistent, not random. In the table below, you'll see `GET /stock/slow-item` (order-service, CLIENT, 2,008ms) and `GET /stock/:item` (inventory-service, SERVER, 2,005ms) right next to each other. Those two rows together tell you the story before you even click anything: the client span is order-service making the outbound call; the server span is inventory-service handling it. Both take ~2 seconds. The other spans on the page are <1ms.

**Waterfall view** — what you see after clicking into a slow trace. The root span is `POST /orders` from order-service, 2,011ms total. Almost all of it is one child span: `GET /stock/slow-item` at 2,008ms (order-service, CLIENT). Nested inside that is `GET /stock/:item` from inventory-service at 2,005ms (SERVER). Below that: four inventory-service middleware spans, all <1ms. The waterfall makes the call chain structural — you can see at a glance that order-service spends 2 seconds waiting for inventory-service, and inventory-service spends almost all of that inside the request handler. The right panel on the selected span shows `http.response.status_code: 200 OK`. That's the key detail: the request succeeded. The customer got a slow response, not an error. No alarm fired. There was nothing to indicate anything was wrong — except this trace.

**Triage view** — what you see after switching to the Triage tab with "Compare spans with status ERROR versus OK & UNSET." The table shows attributes ranked by how strongly they correlate with error spans. `http.target: /stock/broken-item` will be near the top at ~46% — meaning that attribute appears in 46% more error spans than healthy ones. `http.response.status_code: 500` and `502` appear together. This view answers the question "what's different about the requests that fail?" without requiring you to click through individual traces. In a real incident on an unfamiliar system, this is where you'd start.

---

**What to say during the debrief:**

"Ok who found the slow span? Where was it?"

[wait for someone to say `inventory-service /stock/slow-item`]

"Exactly. How did you know it was inventory-service and not order-service?

Look at the waterfall — `POST /orders` is the entry point in order-service, 2,011ms total. Then `GET /stock/slow-item` — that's order-service making the outbound call, also ~2s. Nested inside it: `GET /stock/:item` in inventory-service, 2,005ms. That's the server-side span — inventory-service receiving and handling the call.

The two seconds happen inside inventory-service's span. order-service is just waiting. Without distributed tracing you'd file a ticket saying 'orders are slow' and start looking at order-service code — which is completely innocent. The trace gives you the right service on the first click.

And look at the status code on that inventory-service span: 200 OK. It returned successfully. The customer got their order — just after waiting two seconds. No error, no alert, nothing in the logs. The only signal is this latency data."

"Now the error. Who found it? Where did the error show up?"

[wait for someone to notice the error on the inventory-service span AND the corresponding error on the order-service span]

"Both services. One trace. The error originated in inventory-service — but order-service received it over HTTP and marked its own span as failed too. That's trace context propagation working correctly.

The W3C Trace Context spec defines a `traceparent` header. When order-service calls inventory-service, the auto-instrumentation injects that header with the current trace ID and span ID. inventory-service reads it, creates a child span with the same trace ID, and continues the same trace. So when inventory-service fails, its span is marked as error — and because they share a trace ID, you see both spans in the same waterfall.

If that propagation wasn't working — if someone had disabled it, or if one service wasn't using OTel — you'd see two disconnected traces with no relationship. You'd know something was failing but you wouldn't know the call chain. That's a common debugging nightmare in mixed-instrumentation environments."

"Now — who used the Triage view? What did you find?"

[wait — someone will say /stock/broken-item or the 500 status code]

"Exactly. The Triage view doesn't require you to know what you're looking for in advance. You point it at your error spans and it tells you which attributes are statistically different from the healthy spans. `/stock/broken-item` near the top — that's the system telling you 'this endpoint is the problem' without you clicking through a hundred traces.

Here's why that matters at 2am: you've just been paged. You've never touched this codebase. The waterfall is great once you know which trace to look at. The Triage view is how you figure out which trace to look at.

These three views — Outlier chart, waterfall, Triage — are the investigation loop. Chart to find the anomaly. Waterfall to understand the call chain. Triage to find the correlated attributes. You now know how to use all three."

**Questions you'll get here:**

**Q: How exactly does trace context propagation work?**
A: The auto-instrumentation wraps every outgoing HTTP call. Before sending the request, it injects a `traceparent` header — a standardized string that encodes the trace ID, parent span ID, and some flags. The receiving service's auto-instrumentation reads that header on every incoming request and creates a child span that references the same trace ID. Zero developer code. This is the whole value of a standard format: any two services that both use OTel-compliant instrumentation can be part of the same trace automatically.

**Q: What about sampling? 100% of traces gets expensive.**
A: Yes. The right long-term answer is tail-based sampling in the Collector — you buffer complete traces and make a sampling decision based on whether the trace had errors, exceeded latency thresholds, or matches some other policy. That way you keep 100% of interesting traces and sample down the boring healthy ones. The `tail_sampling` processor handles this. The persistent queue we set up in Bug 3 is a prerequisite — you need durable buffering for tail sampling to work. We're not covering that today, but it's the natural next step from this setup.

**Q: Does this work with Java/Python/Go?**
A: Yes. The env vars — `OTEL_SERVICE_NAME`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_RESOURCE_ATTRIBUTES` — are part of the OTel spec, not Node.js-specific. Your ConfigMap works identically for a Java pod, a Python pod, and a Node.js pod in the same namespace. The auto-instrumentation package is different per language — `opentelemetry-javaagent.jar` for Java, `opentelemetry-instrument` wrapper for Python, manual SDK setup for Go since it's compiled — but the platform configuration is identical.

---

### ACT 3 INTRO (1:00–1:02)

**What's on screen:** Dash0 overview, both services healthy.

---

"Great. We found the problem, we understand why it happened, and we have the data to prove it.

Now let's make sure it can't happen again — and let's deal with the structural issue that made it possible in the first place.

Here's the structural issue: right now, every service that joins this platform has to declare its own `OTEL_SERVICE_NAME`. That's the one thing the ConfigMap can't provide — it's the service's own identity, and the platform can't know it in advance. Everything else — the endpoint, the protocol, the resource attributes — is handled automatically by the platform. But that last piece is still a manual step.

Which means every time a new service is deployed, someone has to remember to add `OTEL_SERVICE_NAME`. And 'remember to do this thing' is how you end up with service names like `my-service` in production. I've seen it more times than I want to admit.

There's a better way."

---

### OPERATOR DEMO (1:02–1:10)

**What's on screen:** Terminal. Have the helm commands pre-typed in a notes file — copy-paste them. Do not type these live.

---

"The Dash0 Kubernetes Operator.

It's a controller that runs in your cluster and watches for new workloads. When a new pod starts in a labeled namespace, the operator uses a mutating admission webhook to inject OTel configuration automatically — before the container even runs. No code changes. No YAML edits. The developer deploys a service; the platform instruments it."

[paste and run the helm commands]

```bash
helm repo add dash0-operator https://dash0hq.github.io/dash0-operator
helm repo update

helm install dash0-operator dash0-operator/dash0-operator \
  --namespace dash0-system \
  --create-namespace
```

"This deploys the operator itself into the `dash0-system` namespace. It's running but not doing anything yet — it has no backend configured and no namespaces to watch."

[while helm installs — usually 30-60 seconds]

"While this runs. Let me tell you about the alternative to this operator.

The alternative is a Confluence page. Or a Notion doc. Or a README section that says 'to add OTel to your service, add the following environment variables.' And at first it works great. The first team reads it, follows the instructions, everything looks good. Then the second team mostly reads it. Then the third team copy-pastes from the second team's YAML. And at some point someone changes the Collector endpoint and forgets to update the doc. And now half your services are pointing to the old endpoint and nobody notices because the Collector is still running and still showing data from the services that updated and the ones that didn't just look quiet.

The operator is the wiki page that actually runs."

[helm finishes]

"Now tell the operator where to send data — this is the backend configuration:"

```bash
source .env
envsubst < k8s/operator/dash0-operator-configuration.yaml | kubectl apply -f -
```

"And tell it to watch the meridian namespace:"

```bash
kubectl label namespace meridian dash0.com/instrumentWorkloads=all
kubectl apply -f k8s/operator/dash0-monitoring.yaml
```

"From this point on, any pod that starts in the `meridian` namespace will be automatically instrumented. Let's prove it."

[pause for effect]

"shipping-service. It's a Node.js Express app that's been running in this cluster the entire time. You haven't seen it in Dash0. You know why? It has zero OTel configuration. No `require` line, no env vars, nothing. Look."

[switch to `services/shipping-service/index.js` briefly]

"Plain Express app. Not even the auto-instrumentation package in the require statements. The developer who wrote this either didn't know about OTel, didn't have time, or was told 'the platform will handle it.'

Let's restart it."

```bash
kubectl rollout restart deployment/shipping-service -n meridian
```

[while it restarts — usually 20-30 seconds]

"The operator intercepts the pod creation via the admission webhook. Before the container starts, it injects an init container that installs the auto-instrumentation library, then adds the environment variables the SDK needs. The original container image is completely unchanged. The original Dockerfile is completely unchanged. The developer's code is completely unchanged.

Let's see what it injected."

```bash
kubectl describe pod -n meridian -l app=shipping-service
```

[scroll through the output — point at three things]

"Three things to notice.

First — the labels. `dash0.com/instrumented=true`, `dash0.com/instrumented-by=controller`. The operator stamped these on the pod when the webhook fired. You can use these to audit which workloads are instrumented across a cluster.

Second — the init container. `dash0-instrumentation` ran before the main container started, installed the OTel SDK into a shared volume at `/__otel_auto_instrumentation`, and then exited. The main container inherited that volume. The original image is completely unchanged.

Third — the env block. Look at `LD_PRELOAD` pointing to `libotelinject.so`. That's a dynamic library hook — it runs at process startup and wires up the OTel instrumentation before the application code runs. No require line. No Dockerfile edit. No code change of any kind.

And `OTEL_EXPORTER_OTLP_ENDPOINT` is pointing to `http://$(DASH0_NODE_IP):40318`. That's not our otel-collector service — that's the operator's own node-local DaemonSet collector running on each node at port 40318. The operator is fully self-contained. It deployed its own telemetry pipeline. shipping-service doesn't reference otel-platform-config at all — look at the deployment YAML, it has one env var: PORT.

The service name is derived from Kubernetes metadata at runtime — the pod name, namespace, and labels feed into the injector config. The developer didn't set it. The platform didn't set it. The operator figured it out from what was already there."

[switch to Dash0 — shipping-service should be appearing within a minute]

"There it is."

[let that land]

"shipping-service. Zero OTel code. Zero platform config. Now fully visible in Dash0.

This is the end state of platform observability: you deploy a service, it's observable. Not eventually. Not after someone files a ticket. Immediately, automatically, by default."

**Questions you'll get here:**

**Q: Will the operator conflict with OTel configuration a developer already set?**
A: The operator routes through its own DaemonSet collector (port 40318) and injects its own endpoint. If a service already has `OTEL_EXPORTER_OTLP_ENDPOINT` set — like order-service and inventory-service, which inherit it from `otel-platform-config` — that value takes precedence over `envFrom` but the operator's injected env vars sit at the container spec level. In practice: services using `otel-platform-config` go through your custom otel-collector; services with no OTel config that the operator instruments go through the operator's own pipeline. Both end up in Dash0. If you want all services through one pipeline, point the operator's export to your otel-collector instead of directly to Dash0.

**Q: What happens if the operator is down when a new pod starts?**
A: The operator uses a mutating admission webhook with `failurePolicy: Ignore` by default. If the webhook is unavailable, the pod starts without the injection — it just won't have OTel config. In production you'd run the operator with multiple replicas for availability. `failurePolicy: Fail` is also an option if you'd rather block unobserved deploys than allow them, but that's a strong policy choice.

**Q: Does it work with all languages?**
A: For Node.js, Java, and Python — full injection. The operator installs the appropriate agent via init container and adds the env vars. For Go, it can only inject the env vars, not the agent itself, because Go binaries are compiled and can't be patched at runtime. Go services get the platform config (endpoint, resource attributes) but still need manual SDK instrumentation code. That's a Go limitation, not an operator limitation.

**Q: What if we're not on Kubernetes?**
A: The ConfigMap pattern translates everywhere. ECS Task Definitions have environment blocks. Docker Compose has `env_file`. VM setups have configuration management. The principle is the same: one place defines the platform defaults, services inherit. Kubernetes is just the most natural environment for this because `envFrom` makes the inheritance explicit and automatic.

---

### AGENT0 ALERT + DASHBOARD (1:10–1:18)

**What's on screen:** Dash0 — all three services showing.

---

"One last thing.

The incident we spent this workshop investigating? It happened because there were no alerts. Orders were slow and failing. On-call didn't get paged. The CTO found out from a customer.

Let's fix that. And we're going to fix it the smart way, not the 'write a PromQL query and guess at the threshold' way."

[open Agent0]

"'Create an alert that fires when order-service p95 latency exceeds 500ms for more than 2 minutes.'"

[submit — let it run]

[while it generates]

"Most alert creation workflows go like this: you pick a metric, write a query, pick a threshold based on gut feeling or a Stack Overflow answer, deploy it, and find out two weeks later that it either never fires because the threshold was too high or pages you every night at 3am because it was too low.

Agent0 does something different. It validates the alert against your actual live telemetry before saving it. It asks: would this alert have fired in the last hour? If yes — on what? Was that a real incident or noise? Is 500ms a reasonable threshold given your actual traffic patterns, or are you going to get paged every time there's a network hiccup?

You get to see that before the alert goes live."

[once it generates and shows the preview]

"Look at that. It shows you the historical firing — here's when this alert would have fired in the last hour, here's what the latency looked like at that moment. You can look at those moments and decide: yes, that's real, I want to be paged for that. Or: that's noise, let me raise the threshold.

This is the difference between an alert system that protects you and one that trains you to ignore alerts."

[save the alert]

"Now let's build the dashboard that the platform team should have had the whole time."

[type: `Create a service health dashboard for Meridian with error rate, p50/p95/p99 latency, and request volume for each service`]

[let it generate]

[while waiting]

"Every service that ships to production should come with a service health dashboard. Not built by the individual service team — built by the platform team as a template. The service team can customize it, add service-specific panels, whatever. But the baseline — error rate, latency percentiles, request volume — should be there by default.

Right now, most platform teams either don't do this, or they do it once and it gets stale, or they have a Confluence page with instructions for how developers should build their own. None of those work at scale."

[dashboard appears]

"And there it is. Three services, error rate, p50/p95/p99 latency, volume. Ready to share. Ready to pin to your incident runbook.

You used to need a Grafana expert to build this. Now you need a sentence."

**Questions you'll get here:**

**Q: What model does Agent0 use?**
A: We don't publish the model. The architecture that matters: Agent0 has structured access to your live telemetry — it queries span indexes, metric time series, log aggregations directly. It's not generating SQL from natural language and hoping; it has a telemetry query layer and uses LLM reasoning to synthesize over results. The grounding in real data is what makes it actually useful for incident investigation vs. a general chatbot.

**Q: Can Agent0 write PromQL I can use in Grafana?**
A: Dashboards and alerts are native to Dash0 today. Cross-tool query export is a reasonable product request — worth raising directly.

**Q: Does it work with logs?**
A: Yes, all three signals if you're sending them. Log correlation is particularly powerful once you've identified a problematic span — you can ask Agent0 to show you the log lines from the same request. The more complete your telemetry pipeline, the more Agent0 can cross-correlate.

---

### CLOSING (1:18–1:22 virtual / 0:55–1:00 in-person)

**What's on screen:** Dash0 — all three services visible, alert active, dashboard live.

---

"Look at where we started.

Two services. Both dark. We opened Dash0 and saw nothing useful. The CTO had a message in Slack and no one could answer it.

What was actually broken? Three things. All of them in the platform layer. None of them in the application code.

A misconfigured endpoint in a ConfigMap that pointed at a hostname that doesn't exist. One line, wrong. Both services dropped all their traces silently for — we don't know how long, because we had no observability. Could have been days.

A missing `OTEL_RESOURCE_ATTRIBUTES` in that same ConfigMap. No `service.version`. No `deployment.environment`. Spans were arriving at Dash0 but completely context-free. You couldn't filter by environment. You couldn't track regressions by version. The data was there and useless.

A Collector with no persistent queue and no retry. Every time that pod restarted — during a node rotation, during a deploy — all in-flight telemetry vanished. Silently.

Three things. Two files. One rollout restart. Fixed."

[pause]

"Three things I want you to actually leave here knowing.

One."

[raise one finger]

"Resource attributes are not optional. `service.name`, `service.version`, `deployment.environment`. These are how you find things when something breaks at 2am. Put them in a ConfigMap. Make them the platform default. If you do nothing else from this workshop, do this."

"Two."

[raise second finger]

"The Collector config is platform infrastructure. It deserves the same attention as your ingress config, your network policies, your RBAC setup. Persistent queue, retry on failure, backing storage — these aren't advanced features, they're the minimum for a production-grade pipeline. A Collector without these is a hope-based observability strategy."

"Three."

[raise third finger]

"Your AI is only as good as your telemetry. Agent0, whatever tool you use — Copilot for your SRE workflows, whatever comes next — all of it is downstream of the quality of data your platform ships. Clean, attributed, complete telemetry makes the AI useful. Missing spans, wrong service names, dropped data — that makes the AI confidently wrong. Which is worse than no AI at all.

Good observability isn't just for humans anymore."

[pause]

"The developer did their job. One require statement. One line of code. They put it there and trusted that the platform would take care of the rest.

Make sure the platform does its job.

Repo is in the chat — `github.com/dash0hq/dash0-examples`, platform-observability-workshop folder. Free Dash0 account at app.dash0.com.

Find me on X and LinkedIn at `@juliafmorgado`. I genuinely love hearing what people build from workshops — DM me, show me what you deployed, tell me what broke and what you fixed.

Thank you."

---

### VIRTUAL ONLY — ARCHITECTURE BREAKOUT (1:22–1:50)

**What's on screen:** Scenario card on screen + breakout room instructions.

---

**Before breaking out:**

"Ok — virtual folks, you've got 30 more minutes and I am not letting you spend them listening to me talk.

I'm splitting you into groups of 3 or 4. Each group gets the same scenario: a fictional company called Nexus Platform. Your job is to design their OTel Collector topology.

There's no single right answer. I want to see your reasoning. Why that topology? What tradeoffs did you make? What would you do differently with more budget or more time?

You've got 15 minutes in breakout rooms. Use Miro, FigJam, a Google doc, a photo of a whiteboard — whatever works. Then two groups will present back.

Here's the scenario."

[display scenario card]

> **Nexus Platform**
> 6 engineering teams. 4 languages: Java, Node.js, Python, Go.
> Two teams export directly to their own backends — one to Datadog, one to self-hosted Jaeger. They won't change.
> One team has zero observability at all.
> Two Kubernetes clusters in different regions.
> Compliance: PII must be stripped from logs before export.
> Budget for the Collector fleet: $300/month.
>
> Design your Collector topology:
> - DaemonSet, Deployment, or both?
> - Where does PII scrubbing happen?
> - How do you handle Datadog and Jaeger without changing those teams' backends?
> - One shared `otel-platform-config` or per-team configs?

"Go."

[send to breakouts]

---

**Debrief after groups present:**

"Let's talk through the design space.

DaemonSet or Deployment? The correct answer for this scenario is both. DaemonSet runs one Collector per node — you need this for host-level metrics like CPU utilization, disk I/O, kubelet stats. Those require host-level access that a Deployment doesn't have. But a Deployment is better for the aggregation and processing layer — you can scale it independently, it's not tied to node count, and it's where you put the expensive processors like PII scrubbing and fan-out. One isn't better — they solve different problems.

PII scrubbing. This should happen in the Collector pipeline, not in the application. Why? Because if you put it in the app, you're trusting every team to implement it correctly, consistently, and to not skip it when they're under deadline pressure. The platform can't trust that. A `transform` processor in the Collector pipeline scrubs it centrally — every log that passes through gets cleaned, regardless of which team wrote the service. The ConfigMap pattern from today scales directly here: all services route to the Collector, the Collector enforces the policy.

Datadog and Jaeger. You don't have to make those teams change anything. The OTel Collector supports multiple exporters in a single pipeline. You point both teams at your Collector — same endpoint, same configuration as everyone else — and the Collector fans out. It sends to Datadog AND Jaeger AND Dash0 from one pipeline. They keep their backend. You get consistency. Nobody files a ticket.

One ConfigMap or per-team. One shared base. Per-team overrides if needed. Maintaining six separate Collector configs for six teams is how you end up with six configs that have quietly diverged and nobody knows which one is right. A shared base with namespace-level overrides via the operator — exactly what we built today — is the pattern that scales."

**Scenario card to display:**

> **Nexus Platform**
> 6 engineering teams. 4 languages: Java, Node.js, Python, Go.
> Two teams already export directly to their own backends — one to Datadog, one to self-hosted Jaeger.
> One team has zero observability.
> The platform runs across two Kubernetes clusters in different regions.
> Compliance requires PII stripped from logs before export.
> Budget for the Collector fleet: $300/month.
>
> Design your Collector topology. Answer:
> - DaemonSet, Deployment, or both? Why?
> - Where does PII scrubbing happen?
> - How do you handle the Datadog and Jaeger teams without asking them to change backends?
> - One shared `otel-platform-config` or per-team configs?

---

## PART 3 — TIMING CHEATSHEETS

### 90 min virtual

| Time | Block | Mode |
|------|-------|------|
| 0:00–0:13 | Opening — frontend demo, instrumentation, send to work | You talk + show |
| 0:13–0:35 | Act 1 hands-on | They work |
| 0:35–0:40 | Act 1 debrief — "you fixed the platform" | You show |
| 0:40–0:42 | Act 2 intro, trigger issues | You run script |
| 0:42–0:52 | Agent0 demo | You show |
| 0:52–1:00 | Act 2 trace exploration | They work |
| 1:00–1:02 | Act 3 intro | You talk |
| 1:02–1:10 | Operator demo + shipping-service moment | You show |
| 1:10–1:18 | Agent0 alert + dashboard | You show |
| 1:18–1:22 | Closing | You talk |
| 1:22–1:50 | Architecture breakout | Groups work |

### 60 min in-person

| Time | Block | Mode |
|------|-------|------|
| 0:00–0:13 | Opening — frontend demo, instrumentation, send to work | You talk + show |
| 0:13–0:30 | Act 1 hands-on (tighter) | They work |
| 0:30–0:35 | Act 1 debrief | You show |
| 0:35–0:37 | Act 2 intro | You run script |
| 0:37–0:45 | Agent0 demo | You show |
| 0:45–0:48 | Act 2 traces — walk through on screen, no hands-on | You show |
| 0:48–0:50 | Act 3 intro | You talk |
| 0:50–0:55 | Operator demo + shipping-service moment | You show |
| 0:55–0:58 | Agent0 alert + dashboard | You show |
| 0:58–1:00 | Closing | You talk |

---

## PART 4 — TIPS, BACKUP PLANS, THINGS THAT WILL GO WRONG

### Things that will definitely go wrong

**Someone's Kind cluster won't start**
"If Kind is failing, pair up with a neighbor and follow along on one machine — the important thing is the concepts, not running every command yourself."

**Agent0 takes longer than expected or gives a weird answer**
Don't fill the silence nervously. "This is realistic — sometimes the investigation takes a minute. Watch the hypothesis tree, that's the interesting part." If the answer is unexpected, lean in: "Interesting — let's look at why it concluded that. This is exactly the 'show your work' part."

**Someone fixes all three bugs before the timer**
Have a bonus challenge ready: "If you're done — try eliminating the last hardcoded value. Every service still has `OTEL_SERVICE_NAME` in its deployment YAML. There's a Kubernetes Downward API trick that derives it from the pod's own `app` label automatically. It's in the Bonus section of the README. Try it."

**Virtual: nobody talks in the debrief**
Have two specific questions ready: "Who found Bug 3 the hardest? And — what was the first moment you realized the problem was in the ConfigMap and not the service YAML?" People answer specific questions, not open ones.

**The operator takes more than 2 minutes to install**
Keep talking while it installs. Have a story ready: "First time I used the operator in a production cluster, a team was so confused that their service appeared in Dash0 — they had never configured it — that they filed a ticket thinking they'd been hacked."

**Someone points out that `emptyDir` isn't really persistent**
Good catch — that's correct. In the fixed state we use a PVC, which actually survives pod restarts. The broken state has no queue at all — `emptyDir` in that context just illustrates the concept. For a real production Collector you'd use a PVC on a reliable storage class.

---

### Before you go on stage checklist

- [ ] Kind cluster running with broken app deployed
- [ ] Traffic generating for 15+ min (`./scripts/generate-traffic.sh`, no flags)
- [ ] Dash0 showing broken state — screenshot it as backup
- [ ] VS Code open with `services/order-service/index.js`, font size 20+
- [ ] `k8s/broken/otel-platform-config.yaml` open in second tab
- [ ] `k8s/broken/otel-collector.yaml` open in third tab
- [ ] All helm/kubectl commands pre-typed in a notes file — copy-paste, never type live (includes helm install, Dash0OperatorConfiguration apply, Dash0Monitoring apply, kubectl label, rollout restart)
- [ ] `./scripts/generate-traffic.sh --with-issues` ready to run with one keypress
- [ ] Participant guide URL in a short link, ready to paste
- [ ] Water bottle
- [ ] Backup: screen recording of the Agent0 demo in case wifi dies

---

### Anecdotes and stories to use naturally

**On silent data loss (Bug 3 hint):**
"The Collector will not tell you it's dropping spans. It just drops them. No error, no warning — unless you've set up Collector self-observability, which nobody does the first time. A persistent queue with retry prevents this — it buffers and retries instead of fire-and-forget."

**On the ConfigMap pattern (Bug 1+2 debrief):**
"I once consulted for a team that had three services pointing to `http://collector.default:4317` from the wrong namespace. All three were silently dropping everything. The fix was one line in a ConfigMap. The debug session took four hours because everyone kept looking at the service code."

**On resource attributes (Bug 2 debrief):**
"I once saw a team with 47 services all labeled `my-service` in production because someone copy-pasted the deployment YAML and changed everything except `OTEL_SERVICE_NAME`. Perfect traces. No idea which service any of them belonged to. The ConfigMap approach eliminates that class of mistake entirely — `OTEL_RESOURCE_ATTRIBUTES` is the one thing you can't accidentally forget per-service."

**On the operator (Act 3):**
"The alternative to the operator is a wiki page that says 'remember to set `OTEL_SERVICE_NAME` in your deployment.' How's that going? The operator is the wiki page that actually runs."

**On Agent0 and data quality:**
"I think about it like this — you wouldn't ask a doctor to diagnose you from a partial x-ray. Agent0 is pattern recognition over clean data. You control the data quality. That's the platform team's job."

---

**Post-workshop questions (closing + hallway track):**

**Q: What's Dash0's pricing?**
A: Usage-based — you pay for the data you ingest. There's a free tier. Best answer: "Check app.dash0.com/settings/billing — the free tier covers what you'd need for a team just getting started, and the paid tiers scale with volume. Happy to connect you with someone if you're evaluating for a larger deployment."

**Q: Can I use this setup with a different backend — Grafana Cloud, Honeycomb, New Relic?**
A: Yes. The ConfigMap pattern, the Collector config, and the operator are all standard OTel — completely backend-agnostic. The only Dash0-specific parts are the exporter endpoint, the auth token, and Agent0. Swap the exporter and the rest works identically. That's the whole point of OTel.

**Q: Is there a Helm chart or Terraform module for the whole platform setup?**
A: Not in this repo — the workshop is deliberately raw YAML so you can see every moving part. In production you'd wrap this in Helm: a chart with `values.yaml` for the endpoint and token, templates for the ConfigMap and Collector, and a subchart dependency on the operator. That's a good next step after the workshop.

**Q: How do you handle multiple environments — staging vs. production — with the same ConfigMap approach?**
A: Separate namespaces, separate ConfigMaps. `otel-platform-config` in the `meridian-staging` namespace has `deployment.environment=staging`. Same manifest, different value. If you're using GitOps, Kustomize overlays handle this cleanly — a base ConfigMap and a per-environment patch file that overrides just the `OTEL_RESOURCE_ATTRIBUTES` value.

**Q: What about multi-cluster? Does the ConfigMap approach scale?**
A: The ConfigMap is per-namespace, so it works the same way in every cluster — apply it once per namespace, services inherit it. The Collector config is what changes at cluster level: you'd typically run a Collector DaemonSet per cluster and aggregate in a central Collector Deployment, with the `otel-platform-config` in each cluster pointing to its local DaemonSet. That's the Nexus Platform topology from the architecture breakout.

**Q: Why OpenTelemetry and not just Prometheus + Jaeger directly?**
A: Prometheus and Jaeger are great, but they're separate instrumentation systems — you're maintaining two SDKs, two data models, two sets of labels. OTel is one SDK, one data model, backend-agnostic. You instrument once and route to Prometheus, Jaeger, Dash0, or all three from the Collector. The consolidation also matters for context: OTel can correlate a trace span to the metric that was anomalous at the same moment, because they share the same resource attributes. Separate systems can't do that without significant work.

**Q: Should the Collector be a DaemonSet or a Deployment?**
A: Depends on what you need. DaemonSet runs one Collector per node — necessary if you're collecting node-level metrics (CPU, disk, kubelet stats) or reading host logs directly. Deployment runs N replicas cluster-wide — better for central aggregation, processing, and fan-out. For application telemetry (what we built today), a Deployment is fine. For a full platform setup, you often want both: DaemonSet for host-level signals, Deployment as the aggregation layer.

---

*Built for Julia Furst Morgado — PlatformCon 2026*
