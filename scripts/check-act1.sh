#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { echo -e "${GREEN}✅ $1${NC}"; }
fail() { echo -e "${RED}❌ $1${NC}"; FAILED=$(( FAILED + 1 )); }

FAILED=0

echo ""
echo -e "${CYAN}=== Act 1 Verification — Three Platform Fixes ===${NC}"
echo ""

# ── Check 1: otel-platform-config protocol and endpoint match ─────────────────
echo -e "${CYAN}Check 1: otel-platform-config — OTEL_EXPORTER_OTLP_PROTOCOL + OTEL_EXPORTER_OTLP_ENDPOINT${NC}"
CM_PROTOCOL=$(kubectl get configmap otel-platform-config -n meridian \
  -o jsonpath='{.data.OTEL_EXPORTER_OTLP_PROTOCOL}' 2>/dev/null || echo "")
CM_ENDPOINT=$(kubectl get configmap otel-platform-config -n meridian \
  -o jsonpath='{.data.OTEL_EXPORTER_OTLP_ENDPOINT}' 2>/dev/null || echo "")

if [ "${CM_PROTOCOL}" = "grpc" ] && [ "${CM_ENDPOINT}" = "http://otel-collector:4317" ]; then
  pass "otel-platform-config protocol=grpc, endpoint=http://otel-collector:4317"
else
  fail "Protocol/port mismatch: OTEL_EXPORTER_OTLP_PROTOCOL='${CM_PROTOCOL}' OTEL_EXPORTER_OTLP_ENDPOINT='${CM_ENDPOINT}'"
  echo "     The Collector listens for gRPC on :4317 and HTTP/protobuf on :4318 — they are not interchangeable."
  echo "     Fix: set OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317 in k8s/broken/otel-platform-config.yaml, then:"
  echo "       kubectl apply -f k8s/broken/otel-platform-config.yaml"
  echo "       kubectl rollout restart deployment -n meridian"
fi

echo ""

# ── Check 2: otel-platform-config has OTEL_RESOURCE_ATTRIBUTES ────────────────
echo -e "${CYAN}Check 2: otel-platform-config — OTEL_RESOURCE_ATTRIBUTES${NC}"
CM_RES_ATTRS=$(kubectl get configmap otel-platform-config -n meridian \
  -o jsonpath='{.data.OTEL_RESOURCE_ATTRIBUTES}' 2>/dev/null || echo "")

if echo "${CM_RES_ATTRS}" | grep -q "service.version" && echo "${CM_RES_ATTRS}" | grep -q "deployment.environment"; then
  pass "otel-platform-config OTEL_RESOURCE_ATTRIBUTES contains service.version and deployment.environment"
else
  fail "otel-platform-config OTEL_RESOURCE_ATTRIBUTES is '${CM_RES_ATTRS:-<empty>}' — no version or environment on any span"
  echo "     Hint: add OTEL_RESOURCE_ATTRIBUTES to k8s/broken/otel-platform-config.yaml, then:"
  echo "       kubectl apply -f k8s/broken/otel-platform-config.yaml"
  echo "       kubectl rollout restart deployment -n meridian"
fi

echo ""

# ── Check 3: Collector has sending_queue with storage + retry_on_failure ──────
echo -e "${CYAN}Check 3: OTel Collector config — persistent queue and retry${NC}"
COLLECTOR_CONFIG=$(kubectl get configmap otel-collector-config -n meridian \
  -o jsonpath='{.data.config\.yaml}' 2>/dev/null || echo "")

if echo "${COLLECTOR_CONFIG}" | grep -q "sending_queue" && echo "${COLLECTOR_CONFIG}" | grep -q "storage:"; then
  pass "Collector sending_queue with persistent storage is configured"
else
  fail "Collector is missing sending_queue with persistent storage — data is lost on pod restart"
  echo "     Hint: add the file_storage extension and sending_queue to the otlp exporter in k8s/broken/otel-collector.yaml"
  echo "       kubectl apply -f k8s/broken/otel-collector.yaml"
  echo "       kubectl rollout restart deployment/otel-collector -n meridian"
fi

if echo "${COLLECTOR_CONFIG}" | grep -q "retry_on_failure"; then
  pass "Collector retry_on_failure is configured"
else
  fail "Collector is missing retry_on_failure — backend blips cause silent data loss"
  echo "     Hint: add retry_on_failure.enabled=true to the otlp exporter in k8s/broken/otel-collector.yaml"
fi

echo ""

# ── Summary ────────────────────────────────────────────────────────────────────
if [ "${FAILED}" -eq 0 ]; then
  echo -e "${GREEN}All three platform fixes verified.${NC}"
  echo ""
  echo "  You didn't fix order-service."
  echo "  You didn't fix inventory-service."
  echo "  You fixed the platform. That's the difference."
  echo ""
  echo "  Generate traffic with issues to see it working:"
  echo "    scripts/generate-traffic.sh --with-issues"
else
  echo -e "${RED}${FAILED} check(s) failed. Fix the issues above and re-run this script.${NC}"
  exit 1
fi
