#!/usr/bin/env bash
# E2E lab: test host-access probe with provisioning readiness (run on oms-client VM).
set -euo pipefail

TOKEN_FILE="${TOKEN_FILE:-$HOME/oms-client/compose/secrets/assessment-token.txt}"
ENV_FILE="${ENV_FILE:-$HOME/oms-client/compose/.env}"
API_PORT="${API_PORT:-5808}"

TOKEN="$(cat "$TOKEN_FILE")"
RUNTIME="$(grep -E '^RUNTIME_ASSET_ID=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"')"
HOST="${LOGICAL_HOST:-10.69.105.50}"
API="http://127.0.0.1:${API_PORT}/local/logical-assets/host-access/probe"

probe() {
  local label="$1"
  local user="$2"
  local pass="$3"
  echo ""
  echo "=== $label (user=$user) ==="
  curl -sS -w "\nHTTP %{http_code}\n" -X POST "$API" \
    -H "X-Customer-Token: $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"runtimeAssetId\":\"$RUNTIME\",\"hostname\":\"$HOST\",\"osFamily\":\"linux\",\"username\":\"$user\",\"password\":\"$pass\",\"sshPort\":22}"
}

probe "Positive: oms-telegraf após bootstrap" "oms-telegraf" "${SSH_PASS:-webweb123}"
probe "Negative: joaofernandes sem escrita (dir owned by oms-telegraf)" "joaofernandes" "${SSH_PASS:-webweb123}"
