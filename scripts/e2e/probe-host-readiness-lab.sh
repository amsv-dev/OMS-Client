#!/usr/bin/env bash
# E2E lab: test host-access probe with provisioning readiness (run on oms-client VM).
set -euo pipefail

TOKEN_FILE="${TOKEN_FILE:-$HOME/oms-client/compose/secrets/console-token.txt}"
ENV_FILE="${ENV_FILE:-$HOME/oms-client/compose/.env}"
API_PORT="${API_PORT:-5808}"
KEY_FILE="${OMS_BOOTSTRAP_KEY:-/etc/oms/bootstrap-keys/oms-telegraf-oms-bootstrap}"

TOKEN="$(cat "$TOKEN_FILE")"
RUNTIME="$(grep -E '^RUNTIME_ASSET_ID=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"')"
HOST="${LOGICAL_HOST:-10.69.105.50}"
API="http://127.0.0.1:${API_PORT}/local/logical-assets/host-access/probe"

if [[ ! -f "$KEY_FILE" ]]; then
  echo "ERRO: chave PEM em $KEY_FILE — corra bootstrap-logical-host.sh --generate-keypair na VM logica"
  exit 1
fi

probe() {
  local label="$1"
  local user="$2"
  echo ""
  echo "=== $label (user=$user) ==="
  PAYLOAD=$(python3 - <<PY
import json
key = open("$KEY_FILE", encoding="utf-8", newline="\n").read().replace("\r\n", "\n").replace("\r", "\n").strip()
print(json.dumps({
  "runtimeAssetId": "$RUNTIME",
  "hostname": "$HOST",
  "osFamily": "linux",
  "username": "$user",
  "privateKey": key,
  "sshPort": 22,
}))
PY
)
  curl -sS -w "\nHTTP %{http_code}\n" -X POST "$API" \
    -H "X-Customer-Token: $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD"
}

probe "Positive: oms-telegraf + PEM após bootstrap" "oms-telegraf"
probe "Negative: utilizador invalido (SSH_AUTH_FAILED esperado)" "nao-existe-ssh"
