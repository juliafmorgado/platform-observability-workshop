#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN} $1${NC}"; }
fail() { echo -e "${RED} $1${NC}"; FAILED=1; }
warn() { echo -e "${YELLOW}  $1${NC}"; }

FAILED=0

echo ""
echo "=== Meridian Workshop — Preflight Check ==="
echo ""

# docker
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
  ok "docker is running ($(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'unknown version'))"
else
  fail "docker is not running — install Docker Desktop from https://www.docker.com/products/docker-desktop"
fi

# kind
if command -v kind &>/dev/null; then
  ok "kind $(kind version 2>/dev/null | awk '{print $2}')"
else
  fail "kind not found — install with: brew install kind  or  go install sigs.k8s.io/kind@latest"
fi

# kubectl
if command -v kubectl &>/dev/null; then
  ok "kubectl $(kubectl version --client --short 2>/dev/null | awk '{print $3}')"
else
  fail "kubectl not found — install with: brew install kubectl"
fi

# helm
if command -v helm &>/dev/null; then
  ok "helm $(helm version --short 2>/dev/null | awk '{print $1}')"
else
  fail "helm not found — install with: brew install helm"
fi

# curl
if command -v curl &>/dev/null; then
  ok "curl available"
else
  warn "curl not found — generate-traffic.sh won't work (install with: brew install curl)"
fi

# envsubst (needed for Act 3 operator setup)
if command -v envsubst &>/dev/null; then
  ok "envsubst available"
else
  fail "envsubst not found — needed for Act 3 operator setup (install with: brew install gettext && brew link --force gettext)"
fi

# .env file
if [ -f "$(dirname "$0")/../.env" ]; then
  ok ".env file found"
  # shellcheck source=/dev/null
  source "$(dirname "$0")/../.env"
  if [ -z "${DASH0_TOKEN:-}" ] || [ "${DASH0_TOKEN}" = "your-token-here" ]; then
    warn "DASH0_TOKEN in .env looks like a placeholder — update it before deploying"
  else
    ok "DASH0_TOKEN is set"
  fi
  if [ -z "${DASH0_OTLP_ENDPOINT:-}" ]; then
    warn "DASH0_OTLP_ENDPOINT is empty in .env"
  else
    ok "DASH0_OTLP_ENDPOINT=${DASH0_OTLP_ENDPOINT}"
  fi
else
  fail ".env not found — copy .env.template to .env and fill in your Dash0 credentials"
fi

echo ""
if [ "${FAILED}" -eq 0 ]; then
  echo -e "${GREEN}All checks passed. You're ready to run scripts/deploy-broken.sh${NC}"
else
  echo -e "${RED}Some checks failed. Fix the issues above before continuing.${NC}"
  exit 1
fi
