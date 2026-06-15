#!/usr/bin/env bash
set -euo pipefail

ORDER_API="${ORDER_API:-http://localhost:3000}/orders"
INTERVAL="${INTERVAL:-2}"
WITH_ISSUES=0

for arg in "$@"; do
  [ "${arg}" = "--with-issues" ] && WITH_ISSUES=1
done

NORMAL_ITEMS=("widget" "gadget" "widget" "gadget" "widget")
ISSUE_ITEMS=("slow-item" "broken-item")

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${CYAN}Sending traffic to ${ORDER_API}${NC}"
echo -e "  Normal items: ${NORMAL_ITEMS[*]}"
if [ "${WITH_ISSUES}" -eq 1 ]; then
  echo -e "  Issue items:  ${ISSUE_ITEMS[*]}  ${YELLOW}(--with-issues enabled)${NC}"
fi
echo -e "  Interval: ${INTERVAL}s   |   Ctrl-C to stop\n"

counter=0
while true; do
  # Pick item — every 3rd request is a problem item when --with-issues is set
  if [ "${WITH_ISSUES}" -eq 1 ] && [ $(( counter % 3 )) -eq 2 ]; then
    item="${ISSUE_ITEMS[$(( counter % ${#ISSUE_ITEMS[@]} ))]}"
  else
    item="${NORMAL_ITEMS[$(( counter % ${#NORMAL_ITEMS[@]} ))]}"
  fi

  qty=$(( (RANDOM % 5) + 1 ))

  response=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${ORDER_API}" \
    -H "Content-Type: application/json" \
    -d "{\"item\":\"${item}\",\"quantity\":${qty}}" 2>/dev/null || echo "000")

  ts=$(date '+%H:%M:%S')
  if [ "${response}" = "200" ]; then
    echo -e "${ts}  ${GREEN}✅ ${item} ×${qty}  →  ${response}${NC}"
  elif [ "${response}" = "000" ]; then
    echo -e "${ts}  ${RED}❌ ${item} ×${qty}  →  connection refused (is order-service running?)${NC}"
  else
    echo -e "${ts}  ${RED}❌ ${item} ×${qty}  →  ${response}${NC}"
  fi

  counter=$(( counter + 1 ))
  sleep "${INTERVAL}"
done
