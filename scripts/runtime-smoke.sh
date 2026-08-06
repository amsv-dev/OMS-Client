#!/usr/bin/env bash
# OMS Client — Smoke gate pós-install/update (exit 0/1)
# Valida containers core, agent /health/live, console e telegraf.
# Vault unsealed NÃO é obrigatório no install: o bootstrap/unseal é no Oramix Console (wizard).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMS_CLIENT_DIR="${OMS_CLIENT_DIR:-$(dirname "$SCRIPT_DIR")}"
COMPOSE_DIR="${COMPOSE_DIR:-$OMS_CLIENT_DIR/compose}"
ENV_FILE="${COMPOSE_DIR}/.env"
VAULT_CONTAINER="${VAULT_CONTAINER:-oms-vault}"

SMOKE_STRICT_VAULT_CHECK="${SMOKE_STRICT_VAULT_CHECK:-0}"
# Só falha se Vault selado quando explicitamente pedido (pós-wizard / lab estrito).
SMOKE_REQUIRE_VAULT_UNSEALED="${SMOKE_REQUIRE_VAULT_UNSEALED:-0}"
SMOKE_WAIT_SECONDS="${SMOKE_WAIT_SECONDS:-90}"
# Espera curta só para reportar estado do Vault (não bloqueia o install).
SMOKE_VAULT_PROBE_SECONDS="${SMOKE_VAULT_PROBE_SECONDS:-6}"

usage() {
  cat <<'EOF'
OMS Client — runtime smoke gate

Uso:
  bash scripts/runtime-smoke.sh

Variáveis:
  COMPOSE_DIR, VAULT_CONTAINER
  SMOKE_WAIT_SECONDS              (default 90) — espera agent health
  SMOKE_VAULT_PROBE_SECONDS       (default 6)  — probe rápido do estado Vault
  SMOKE_REQUIRE_VAULT_UNSEALED    (0|1, default 0) — se 1, falha se Vault selado
  SMOKE_STRICT_VAULT_CHECK        (0|1, default 0) — se 1, exige vault-ops check
                                  (AppRole). Em install virgem: 0; após wizard Console: 1.
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

# Influx local: token do .env tem de autenticar (volume antigo + .env novo = 401 silencioso no pipeline).
INFLUX_PORT="$(read_env CLIENT_INFLUXDB_HTTP_PORT)"
[[ -n "${INFLUX_PORT:-}" ]] || INFLUX_PORT="8087"
INFLUX_TOKEN="$(read_env INFLUXDB_LOCAL_TOKEN)"
INFLUX_ORG="$(read_env INFLUXDB_LOCAL_ORG)"
[[ -n "${INFLUX_ORG:-}" ]] || INFLUX_ORG="client"
if docker ps --format '{{.Names}}' | grep -qx client-influxdb; then
  echo "[smoke] A validar auth Influx local (:${INFLUX_PORT})..."
  if [[ -z "${INFLUX_TOKEN:-}" ]]; then
    echo "[smoke][erro] INFLUXDB_LOCAL_TOKEN ausente em $ENV_FILE" >&2
    fail=1
  else
    influx_code="$(
      curl -sS -m 5 -o /tmp/oms-smoke-influx.json -w '%{http_code}' \
        -H "Authorization: Token ${INFLUX_TOKEN}" \
        "http://127.0.0.1:${INFLUX_PORT}/api/v2/buckets?org=${INFLUX_ORG}" \
        2>/dev/null || echo 000
    )"
    if [[ "$influx_code" == "200" ]]; then
      echo "[smoke] OK Influx auth."
    else
      echo "[smoke][erro] Influx unauthorized ou inacessivel (HTTP ${influx_code})." >&2
      echo "[smoke] Causa tipica: volume Influx de install anterior com token diferente do .env." >&2
      echo "[smoke] ACCAO: bash scripts/reset-client.sh --runtime" >&2
      echo "[smoke]        (apaga volumes Vault+Influx; depois bootstrap Vault no Console)." >&2
      echo "[smoke]        So Influx: docker compose rm -f influxdb-local && docker volume rm compose_influxdb-local-data && docker volume create compose_influxdb-local-data && docker compose -f compose/docker-compose.yml --env-file compose/.env up -d" >&2
      fail=1
    fi
  fi
fi

# Vault: no install virgem o cofre arranca selado; init/unseal é no Oramix Console.
echo "[smoke] A verificar estado do Vault (probe ${SMOKE_VAULT_PROBE_SECONDS}s)..."
vault_ok=0
vault_iters=$((SMOKE_VAULT_PROBE_SECONDS / 2))
[[ "$vault_iters" -lt 1 ]] && vault_iters=1
for _ in $(seq 1 "$vault_iters"); do
  if docker exec "$VAULT_CONTAINER" vault status 2>/dev/null | grep -qE 'Sealed[[:space:]]+false'; then
    vault_ok=1
    echo "[smoke] OK Vault unsealed."
    break
  fi
  sleep 2
done
if [[ "$vault_ok" -eq 0 ]]; then
  if [[ "$SMOKE_REQUIRE_VAULT_UNSEALED" == "1" || "$SMOKE_STRICT_VAULT_CHECK" == "1" ]]; then
    echo "[smoke][erro] Vault ainda selado ou inacessivel (SMOKE_REQUIRE_VAULT_UNSEALED/STRICT activo)." >&2
    echo "[smoke] ACCAO: completar bootstrap no Oramix Console (http://127.0.0.1:${CONSOLE_PORT}/)." >&2
    fail=1
  else
    echo "[smoke][aviso] Vault ainda selado — esperado no install. Bootstrap/unseal no Oramix Console (:${CONSOLE_PORT})."
  fi
fi

echo "[smoke] A aguardar customer-agent health/live em $AGENT_URL ..."
agent_ok=0
wait_iters=$((SMOKE_WAIT_SECONDS / 2))
[[ "$wait_iters" -lt 1 ]] && wait_iters=1
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
  echo "[smoke] vault-ops check omitido (cofre pode ainda nao ter bootstrap). Defina SMOKE_STRICT_VAULT_CHECK=1 apos wizard no Console."
fi

if [[ "$fail" -ne 0 ]]; then
  echo "[smoke] FALHOU — runtime doente." >&2
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' \
    | grep -E 'vault|customer-agent|oramix-console|telegraf|influx|promtail' || true
  exit 1
fi

echo "[smoke] OK — runtime saudavel."
exit 0
