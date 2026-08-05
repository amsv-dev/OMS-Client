#!/usr/bin/env bash
# OMS Client — Smoke gate pós-install/update (exit 0/1)
# Valida containers core, Vault unsealed, agent /health/live e (quando possível) vault-ops check.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMS_CLIENT_DIR="${OMS_CLIENT_DIR:-$(dirname "$SCRIPT_DIR")}"
COMPOSE_DIR="${COMPOSE_DIR:-$OMS_CLIENT_DIR/compose}"
ENV_FILE="${COMPOSE_DIR}/.env"
VAULT_CONTAINER="${VAULT_CONTAINER:-oms-vault}"

SMOKE_STRICT_VAULT_CHECK="${SMOKE_STRICT_VAULT_CHECK:-0}"
SMOKE_WAIT_SECONDS="${SMOKE_WAIT_SECONDS:-90}"

usage() {
  cat <<'EOF'
OMS Client — runtime smoke gate

Uso:
  bash scripts/runtime-smoke.sh

Variáveis:
  COMPOSE_DIR, VAULT_CONTAINER
  SMOKE_WAIT_SECONDS          (default 90) — espera agent health
  SMOKE_STRICT_VAULT_CHECK    (0|1, default 0) — se 1, exige vault-ops check
                              (telegraf AppRole). Em install virgem o cofre
                              ainda não foi bootstrapado; use 0.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

read_env() {
  local k="$1"
  grep -E "^${k}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"\r' || true
}

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[smoke][erro] .env nao encontrado em $ENV_FILE" >&2
  exit 1
fi

LOCAL_RUNTIME_API_PORT="$(read_env LOCAL_RUNTIME_API_PORT)"
[[ -n "${LOCAL_RUNTIME_API_PORT:-}" ]] || LOCAL_RUNTIME_API_PORT="5808"
AGENT_URL="${CUSTOMER_AGENT_URL:-http://127.0.0.1:${LOCAL_RUNTIME_API_PORT}}"
CONSOLE_PORT="$(read_env CLIENT_ORAMIX_CONSOLE_HTTP_PORT)"
[[ -n "${CONSOLE_PORT:-}" ]] || CONSOLE_PORT="3122"

fail=0

require_container() {
  local name="$1"
  if ! docker ps --format '{{.Names}}' | grep -qx "$name"; then
    echo "[smoke][erro] Container em falta ou parado: $name" >&2
    fail=1
    return 1
  fi
  echo "[smoke] OK container: $name"
}

echo "[smoke] A validar containers core..."
require_container oms-vault || true
require_container client-influxdb || true
require_container client-telegraf || true
require_container client-customer-agent || true
require_container client-oramix-console || true

echo "[smoke] A aguardar Vault unsealed (max ${SMOKE_WAIT_SECONDS}s)..."
vault_ok=0
wait_iters=$((SMOKE_WAIT_SECONDS / 2))
[[ "$wait_iters" -lt 1 ]] && wait_iters=1
for _ in $(seq 1 "$wait_iters"); do
  if docker exec "$VAULT_CONTAINER" vault status 2>/dev/null | grep -qE 'Sealed[[:space:]]+false'; then
    vault_ok=1
    echo "[smoke] OK Vault unsealed."
    break
  fi
  sleep 2
done
if [[ "$vault_ok" -eq 0 ]]; then
  echo "[smoke][erro] Vault ainda selado ou inacessivel apos ${SMOKE_WAIT_SECONDS}s." >&2
  echo "[smoke] ACCAO: docker logs client-customer-agent | grep -i VaultUnseal" >&2
  fail=1
fi

echo "[smoke] A aguardar customer-agent health/live em $AGENT_URL ..."
agent_ok=0
for _ in $(seq 1 "$wait_iters"); do
  if curl -fsS -m 3 "$AGENT_URL/health/live" >/dev/null 2>&1; then
    agent_ok=1
    echo "[smoke] OK agent /health/live."
    break
  fi
  sleep 2
done
if [[ "$agent_ok" -eq 0 ]]; then
  echo "[smoke][erro] customer-agent inacessivel em $AGENT_URL/health/live" >&2
  fail=1
fi

# /health ASP.NET (MapHealthChecks) — best-effort se o endpoint existir
if curl -fsS -m 3 "$AGENT_URL/health" >/dev/null 2>&1; then
  echo "[smoke] OK agent /health."
else
  echo "[smoke][aviso] agent /health nao respondeu (continua se /health/live OK)."
fi

# Console HTTP (nginx) — resposta qualquer < 500
console_code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${CONSOLE_PORT}/" 2>/dev/null || echo 000)"
if [[ "$console_code" =~ ^[23] ]]; then
  echo "[smoke] OK oramix-console HTTP $console_code."
else
  echo "[smoke][erro] oramix-console HTTP $console_code em :${CONSOLE_PORT}" >&2
  fail=1
fi

# Telegraf processo vivo
if docker exec client-telegraf pgrep -x telegraf >/dev/null 2>&1 \
  || docker exec client-telegraf pidof telegraf >/dev/null 2>&1; then
  echo "[smoke] OK telegraf process."
else
  echo "[smoke][erro] processo telegraf nao encontrado no container." >&2
  fail=1
fi

if [[ "$SMOKE_STRICT_VAULT_CHECK" == "1" ]]; then
  echo "[smoke] SMOKE_STRICT_VAULT_CHECK=1 — a correr vault-ops check..."
  if ! bash "$SCRIPT_DIR/vault-ops.sh" check; then
    echo "[smoke][erro] vault-ops check falhou." >&2
    fail=1
  fi
else
  echo "[smoke] vault-ops check omitido (cofre pode ainda nao ter bootstrap). Defina SMOKE_STRICT_VAULT_CHECK=1 apos bootstrap."
fi

if [[ "$fail" -ne 0 ]]; then
  echo "[smoke] FALHOU — runtime doente." >&2
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' \
    | grep -E 'vault|customer-agent|oramix-console|telegraf|influx|promtail' || true
  exit 1
fi

echo "[smoke] OK — runtime saudavel."
exit 0
