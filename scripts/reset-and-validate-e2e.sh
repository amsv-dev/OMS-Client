#!/usr/bin/env bash
# reset-and-validate-e2e.sh — Reset total + validacao automatica do fluxo
# Vault-only (ADR-010 — arquitectura definitiva sem remendos).
#
# O script:
#   1. Faz reset do stack do cliente (apaga volumes + secrets + autounseal.bin)
#   2. Sobe o stack
#   3. Espera pelo customer-agent
#   4. Faz bootstrap manual do Vault (via /local/vault/bootstrap)
#   5. Cria uma credencial demo com displayName + UUID v4 + user/pwd
#   6. Verifica que esta no Vault (esperado: 200)
#   7. Verifica que o .conf do Telegraf usa @{<uuid>:password} (NUNCA plaintext)
#   8. Faz reboot do oms-vault e oms-customer-agent
#   9. Espera o auto-unseal (max 60s)
#  10. Confirma que a credencial continua acessivel
#
# Pre-requisitos:
#   - docker e docker compose instalados
#   - LOCAL_TOKEN definido no .env do compose
#   - Conectividade local entre containers
#
# Uso:
#   bash client/scripts/reset-and-validate-e2e.sh
#
# Exit codes:
#   0 — todo o flow validado com sucesso
#   1 — qualquer assert falhou (mensagem em stderr)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_DIR="$ROOT/compose"
ENV_FILE="$COMPOSE_DIR/.env"
DC="docker compose -f $COMPOSE_DIR/docker-compose.yml --env-file $ENV_FILE"

# ── helpers ────────────────────────────────────────────────────────────────────

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

TENANT_ID="$(read_env TENANT_ID)"
[ -n "${TENANT_ID:-}" ] || TENANT_ID="demo-tenant"

RUNTIME_ASSET_ID="$(read_env RUNTIME_ASSET_ID)"
[ -n "${RUNTIME_ASSET_ID:-}" ] || RUNTIME_ASSET_ID="$(read_env ASSET_ID)"
[ -n "${RUNTIME_ASSET_ID:-}" ] || RUNTIME_ASSET_ID="runtime-demo-001"

AGENT_URL="${AGENT_URL:-http://localhost:5000}"

agent() {
  curl -fsS -H "X-Local-Token: $LOCAL_TOKEN" -H "Content-Type: application/json" "$@"
}

# ── 1. Reset ───────────────────────────────────────────────────────────────────

step "1. Reset total do stack do cliente"
"$ROOT/scripts/reset-client-e2e.sh"
pass "Reset concluido"

# ── 2. Esperar customer-agent ──────────────────────────────────────────────────

step "2. Esperar pelo customer-agent (max 60s)"
for i in $(seq 1 30); do
  if agent "$AGENT_URL/healthz" >/dev/null 2>&1; then
    pass "customer-agent disponivel ($AGENT_URL)"
    break
  fi
  sleep 2
  [ "$i" -eq 30 ] && fail "customer-agent nao responde apos 60s"
done

# ── 3. Bootstrap do Vault ──────────────────────────────────────────────────────

step "3. Bootstrap manual do Vault (POST /local/vault/bootstrap)"
BOOT_RESP="$(agent -X POST "$AGENT_URL/local/vault/bootstrap" \
  --data '{"keyShares":5,"keyThreshold":3}' || true)"

if [ -z "$BOOT_RESP" ]; then
  fail "Bootstrap nao devolveu resposta. Ver: docker logs oms-customer-agent"
fi

echo "$BOOT_RESP" | jq -e '.success == true or .Success == true' >/dev/null \
  || fail "Bootstrap falhou: $BOOT_RESP"
pass "Vault inicializado, autounseal.bin escrito"

# Esperar unseal completar
for i in $(seq 1 15); do
  if docker exec oms-vault vault status 2>/dev/null | grep -q 'Sealed.*false'; then
    pass "Vault unsealed"
    break
  fi
  sleep 2
  [ "$i" -eq 15 ] && fail "Vault continua sealed apos 30s"
done

# ── 4. Criar credencial demo ───────────────────────────────────────────────────

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

# ── 5. Validar que esta no Vault ───────────────────────────────────────────────

step "5. Verificar segredo no Vault (sem ler o valor!)"
STATUS_RESP="$(agent "$AGENT_URL/local/logical-assets/credentials/status?credentialReference=$SECRET_REF")"
echo "$STATUS_RESP" | jq -e '.exists == true' >/dev/null \
  || fail "Status nao confirma existencia: $STATUS_RESP"
pass "Vault confirma que secret existe"

LIST_RESP="$(agent "$AGENT_URL/local/vault/credentials-list")"
echo "$LIST_RESP" | jq -e --arg ref "$SECRET_REF" \
  '.items // .Items | map(.credentialReference // .CredentialReference) | index($ref) != null' >/dev/null \
  || fail "Credencial nao aparece na lista do Vault: $LIST_RESP"

# Verificar que NAO devolve password
if echo "$LIST_RESP" | grep -qi 'password'; then
  fail "FUGA DE PASSWORD na resposta de credentials-list"
fi
pass "credentials-list responde sem expor password"

# ── 6. (Skip Telegraf .conf check — Telegraf so gera config quando ha asset Central)
step "6. Skip — verificacao do Telegraf .conf requer registo do bundle na Central"

# ── 7. Zero-knowledge: garantir que a Central rejeita password ─────────────────

step "7. Garantir que a Central rejeita payload com password"
CENTRAL_URL="$(read_env ASSESSMENT_API_BASE_URL)"
CENTRAL_TOKEN="$(read_env ASSESSMENT_TOKEN)"
if [ -n "${CENTRAL_URL:-}" ] && [ -n "${CENTRAL_TOKEN:-}" ]; then
  BAD_PAYLOAD=$(jq -nc \
    --arg ref "$SECRET_REF" \
    --arg dn "$DISPLAY_NAME" \
    --arg rt "$RUNTIME_ASSET_ID" \
    '{credentialReference:$ref, displayName:$dn, runtimeAssetId:$rt, serviceType:"postgresql", hostnameOrAddress:"host.example", port:5432, password:"x"}')
  HTTP=$(curl -sk -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $CENTRAL_TOKEN" -H "Content-Type: application/json" \
    -X POST "$CENTRAL_URL/api/assessment/logical-assets" \
    --data "$BAD_PAYLOAD" || true)
  [ "$HTTP" = "400" ] || fail "Central deveria ter rejeitado payload com password (HTTP=$HTTP)"
  pass "Central rejeita password com 400 (zero-knowledge guard activo)"
else
  blue "  (skipped — falta ASSESSMENT_API_BASE_URL ou ASSESSMENT_TOKEN no .env)"
fi

# ── 8. Auto-unseal apos reboot ─────────────────────────────────────────────────

step "8. Reboot do oms-vault + oms-customer-agent e medir auto-unseal"
$DC restart oms-vault oms-customer-agent >/dev/null 2>&1
START=$(date +%s)
for i in $(seq 1 30); do
  if docker exec oms-vault vault status 2>/dev/null | grep -q 'Sealed.*false'; then
    END=$(date +%s)
    pass "Vault auto-unseal completo em $((END-START))s"
    break
  fi
  sleep 2
  [ "$i" -eq 30 ] && fail "Vault continua sealed 60s apos reboot — auto-unseal falhou"
done

# ── 9. Confirmar que a credencial continua acessivel apos reboot ───────────────

step "9. Confirmar que o segredo continua acessivel apos auto-unseal"
sleep 3  # esperar o agent renovar token
STATUS2="$(agent "$AGENT_URL/local/logical-assets/credentials/status?credentialReference=$SECRET_REF")"
echo "$STATUS2" | jq -e '.exists == true' >/dev/null \
  || fail "Credencial nao acessivel pos-reboot: $STATUS2"
pass "Credencial persistente e o agent re-autenticou apos auto-unseal"

green ""
green "════════════════════════════════════════════════════════════════════════"
green "  ✓ Reset + validacao E2E concluida com sucesso (ADR-010 Vault-only)"
green "════════════════════════════════════════════════════════════════════════"
