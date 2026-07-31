#!/usr/bin/env bash
# Reset + validacao automatica Vault-only (ADR-010). QA interno.
# Uso: bash scripts/reset-client.sh --validate
set -euo pipefail

E2E_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$E2E_DIR/../.." && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-$ROOT/compose}"
ENV_FILE="$COMPOSE_DIR/.env"
DC="docker compose -f $COMPOSE_DIR/docker-compose.yml --env-file $ENV_FILE"

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
blue()  { printf "\033[34m%s\033[0m\n" "$*"; }

fail() { red "✗ $*"; exit 1; }
pass() { green "✓ $*"; }
step() { blue "── $* ──"; }

require_tool() { command -v "$1" >/dev/null 2>&1 || fail "Falta a ferramenta: $1"; }

require_tool docker
require_tool curl
require_tool jq

read_env() {
  local k="$1"
  grep -E "^${k}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true
}

LOCAL_TOKEN="$(read_env LOCAL_TOKEN)"
[ -n "${LOCAL_TOKEN}" ] || fail "LOCAL_TOKEN nao definido em $ENV_FILE"

LOCAL_RUNTIME_API_PORT="$(read_env LOCAL_RUNTIME_API_PORT)"
[ -n "${LOCAL_RUNTIME_API_PORT:-}" ] || LOCAL_RUNTIME_API_PORT="5808"

TENANT_ID="$(read_env TENANT_ID)"
[ -n "${TENANT_ID:-}" ] || TENANT_ID="demo-tenant"

RUNTIME_ASSET_ID="$(read_env RUNTIME_ASSET_ID)"
[ -n "${RUNTIME_ASSET_ID:-}" ] || RUNTIME_ASSET_ID="$(read_env ASSET_ID)"
[ -n "${RUNTIME_ASSET_ID:-}" ] || RUNTIME_ASSET_ID="runtime-demo-001"

AGENT_URL="${AGENT_URL:-http://127.0.0.1:${LOCAL_RUNTIME_API_PORT}}"

agent() {
  curl -fsS -H "X-Customer-Token: $LOCAL_TOKEN" -H "Content-Type: application/json" "$@"
}

step "1. Reset total do stack do cliente"
"$E2E_DIR/reset-runtime.sh"
pass "Reset concluido"

step "2. Esperar pelo customer-agent (max 60s)"
for i in $(seq 1 30); do
  if agent "$AGENT_URL/healthz" >/dev/null 2>&1; then
    pass "customer-agent disponivel ($AGENT_URL)"
    break
  fi
  sleep 2
  [ "$i" -eq 30 ] && fail "customer-agent nao responde apos 60s"
done

step "3. Bootstrap do Vault (POST /local/vault/bootstrap)"
BOOT_RESP="$(agent -X POST "$AGENT_URL/local/vault/bootstrap" \
  --data '{"keyShares":5,"keyThreshold":3}' || true)"

if [ -z "$BOOT_RESP" ]; then
  fail "Bootstrap nao devolveu resposta. Ver: docker logs client-customer-agent"
fi

echo "$BOOT_RESP" | jq -e '.success == true or .Success == true' >/dev/null \
  || fail "Bootstrap falhou: $BOOT_RESP"
pass "Vault inicializado, autounseal.bin escrito"

for i in $(seq 1 15); do
  if docker exec oms-vault vault status 2>/dev/null | grep -qE 'Sealed[[:space:]]+false'; then
    pass "Vault unsealed"
    break
  fi
  sleep 2
  [ "$i" -eq 15 ] && fail "Vault continua sealed apos 30s"
done

step "4. Escrever credencial demo com secretRef UUID v4"
SECRET_REF="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())')"
DISPLAY_NAME="E2E Demo Postgres"
CRED_PAYLOAD=$(jq -nc \
  --arg ref "$SECRET_REF" \
  --arg dn "$DISPLAY_NAME" \
  --arg rt "$RUNTIME_ASSET_ID" \
  '{credentialReference:$ref, displayName:$dn, runtimeAssetId:$rt, serviceType:"postgresql", username:"e2e_user", password:"e2e_demo_password"}')

CRED_RESP="$(agent -X POST "$AGENT_URL/local/logical-assets/credentials" \
  --data "$CRED_PAYLOAD")"
echo "$CRED_RESP" | jq -e '.saved == true' >/dev/null \
  || fail "Upsert da credencial falhou: $CRED_RESP"
pass "Credencial gravada no Vault (secretRef=$SECRET_REF)"

step "5. Verificar segredo no Vault"
STATUS_RESP="$(agent "$AGENT_URL/local/logical-assets/credentials/status?credentialReference=$SECRET_REF")"
echo "$STATUS_RESP" | jq -e '.exists == true' >/dev/null \
  || fail "Status nao confirma existencia: $STATUS_RESP"
pass "Vault confirma que secret existe"

LIST_RESP="$(agent "$AGENT_URL/local/vault/credentials-list")"
echo "$LIST_RESP" | jq -e --arg ref "$SECRET_REF" \
  '.items // .Items | map(.credentialReference // .CredentialReference) | index($ref) != null' >/dev/null \
  || fail "Credencial nao aparece na lista do Vault: $LIST_RESP"

if echo "$LIST_RESP" | grep -qi 'password'; then
  fail "FUGA DE PASSWORD na resposta de credentials-list"
fi
pass "credentials-list responde sem expor password"

step "6. Validar telegrafCollectors (vault-ops check)"
bash "$ROOT/scripts/vault-ops.sh" check
pass "telegrafCollectors OK (oms-telegraf AppRole)"

step "7. Central rejeita payload com password"
CENTRAL_URL="$(read_env CONSOLE_API_BASE_URL)"
CENTRAL_TOKEN="$(read_env CONSOLE_TOKEN)"
if [ -n "${CENTRAL_URL:-}" ] && [ -n "${CENTRAL_TOKEN:-}" ]; then
  BAD_PAYLOAD=$(jq -nc \
    --arg ref "$SECRET_REF" \
    --arg dn "$DISPLAY_NAME" \
    --arg rt "$RUNTIME_ASSET_ID" \
    '{credentialReference:$ref, displayName:$dn, runtimeAssetId:$rt, serviceType:"postgresql", hostnameOrAddress:"host.example", port:5432, password:"x"}')
  HTTP=$(curl -sk -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $CENTRAL_TOKEN" -H "Content-Type: application/json" \
    -X POST "$CENTRAL_URLlogical-assets" \
    --data "$BAD_PAYLOAD" || true)
  [ "$HTTP" = "400" ] || fail "Central deveria ter rejeitado payload com password (HTTP=$HTTP)"
  pass "Central rejeita password com 400"
else
  blue "  (skipped — falta CONSOLE_API_BASE_URL ou CONSOLE_TOKEN no .env)"
fi

step "8. Reboot vault + customer-agent e medir auto-unseal"
$DC restart vault customer-agent >/dev/null 2>&1
START=$(date +%s)
for i in $(seq 1 30); do
  if docker exec oms-vault vault status 2>/dev/null | grep -qE 'Sealed[[:space:]]+false'; then
    END=$(date +%s)
    pass "Vault auto-unseal completo em $((END-START))s"
    break
  fi
  sleep 2
  [ "$i" -eq 30 ] && fail "Vault continua sealed 60s apos reboot"
done

step "9. Credencial acessivel apos reboot"
sleep 3
STATUS2="$(agent "$AGENT_URL/local/logical-assets/credentials/status?credentialReference=$SECRET_REF")"
echo "$STATUS2" | jq -e '.exists == true' >/dev/null \
  || fail "Credencial nao acessivel pos-reboot: $STATUS2"
pass "Credencial persistente apos auto-unseal"

green ""
green "════════════════════════════════════════════════════════════════════════"
green "  ✓ Reset + validacao E2E concluida (ADR-010 Vault-only)"
green "════════════════════════════════════════════════════════════════════════"
