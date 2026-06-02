#!/usr/bin/env bash
set -euo pipefail
API_URL="${API_URL:-http://127.0.0.1:5000}"
ADMIN_TOKEN=$(curl -sfS -X POST "$API_URL/api/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}' | jq -r .token)
BODY=$(curl -sfS -X POST "$API_URL/api/customers" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"OMS Lab Probe E2E\",\"email\":\"lab-probe-$(date +%s)@lab.local\",\"observabilityMode\":\"distributed-logical-hosts\"}")
echo "$BODY" | jq -r .apiToken
