#!/usr/bin/env bash
set -euo pipefail

TOKEN="${1:-}"
KEY_FILE="${OMS_BOOTSTRAP_KEY:-/etc/oms/bootstrap-keys/oms-telegraf-oms-bootstrap}"

if [[ -z "$TOKEN" ]]; then
  TOKEN_FILE=~/oms-client/compose/secrets/assessment-token.txt
  TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null | tr -d '[:space:]') || { echo "ERRO: token nao encontrado"; exit 1; }
fi

if [[ ! -f "$KEY_FILE" ]]; then
  echo "ERRO: chave PEM nao encontrada em $KEY_FILE"
  echo "Execute na VM logica: sudo bash bootstrap-logical-host.sh --generate-keypair"
  exit 1
fi

ASSET_ID=$(docker exec client-customer-agent printenv ASSET_ID 2>/dev/null | tr -d '[:space:]')
AGENT_URL="http://127.0.0.1:5808"

echo "=== Probe readiness test (SSH + PEM) ==="
echo "Token: ${TOKEN:0:8}..."
echo "AssetId: $ASSET_ID"
echo "Key: $KEY_FILE"
echo ""

probe_pem() {
  local label="$1"
  local user="$2"
  local host="${3:-10.69.105.50}"

  echo "--- $label ---"
  PAYLOAD=$(python3 - <<PY
import json
key = open("$KEY_FILE", encoding="utf-8", newline="\n").read().replace("\r\n", "\n").replace("\r", "\n").strip()
print(json.dumps({
  "hostname": "$host",
  "osFamily": "linux",
  "username": "$user",
  "privateKey": key,
  "sshPort": 22,
  "runtimeAssetId": "$ASSET_ID",
}))
PY
)
  RESP=$(curl -s -o /tmp/probe-out.json -w "%{http_code}" \
    -X POST "$AGENT_URL/local/logical-assets/host-access/probe" \
    -H "Content-Type: application/json" \
    -H "X-Customer-Token: $TOKEN" \
    --data "$PAYLOAD" \
    --max-time 60)
  echo "HTTP $RESP"
  cat /tmp/probe-out.json 2>/dev/null | python3 -m json.tool 2>/dev/null || cat /tmp/probe-out.json 2>/dev/null
  echo ""
}

probe_pem "POSITIVO: oms-telegraf + PEM" "oms-telegraf"
probe_pem "NEGATIVO: utilizador errado (SSH_AUTH_FAILED esperado)" "utilizador-inexistente"
