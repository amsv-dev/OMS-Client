#!/usr/bin/env bash
# Operacoes do cofre HashiCorp Vault na VM cliente (CLI).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-$CLIENT_ROOT/compose}"
ENV_FILE="${COMPOSE_DIR}/.env"
TOKEN_FILE="${CONSOLE_TOKEN_FILE:-$COMPOSE_DIR/secrets/console-token.txt}"
RECOVERY_FILE="${COMPOSE_DIR}/secrets/vault/recovery-keys-FIRST-BOOT-ONLY.json"
VAULT_CONTAINER="${VAULT_CONTAINER:-oms-vault}"

read_env() {
  local k="$1"
  grep -E "^${k}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"\r' || true
}

LOCAL_RUNTIME_API_PORT="$(read_env LOCAL_RUNTIME_API_PORT)"
[[ -n "${LOCAL_RUNTIME_API_PORT:-}" ]] || LOCAL_RUNTIME_API_PORT="5808"
AGENT_URL="${CUSTOMER_AGENT_URL:-http://127.0.0.1:${LOCAL_RUNTIME_API_PORT}}"

usage() {
  cat <<'EOF'
OMS Client — Vault ops (cofre local)

Uso:
  bash scripts/vault-ops.sh <comando> [opcoes]

Comandos:
  check                                    Gate operacional: vault unsealed + telegrafCollectors OK (exit 0/1)
  bootstrap [--shares N] [--threshold M]   Inicializa Vault (1x); imprime recovery keys no stdout (ADR-011)
  ack-recovery                             Confirma backup offline; apaga ficheiro legacy se existir
  provision-approle                        Verifica AppRole do agent apenas (nao repara oms-telegraf)
  validate-telegraf                        Alias de check (compatibilidade)
  status                                   vault status + health JSON completo (informativo)
  unseal [recovery.json]                   Unseal manual com 3 primeiras keys (backup offline)
  recovery-path                            Estado legacy FIRST-BOOT / autounseal.bin

Variaveis:
  COMPOSE_DIR, CUSTOMER_AGENT_URL (default http://127.0.0.1:$LOCAL_RUNTIME_API_PORT do compose/.env),
  CONSOLE_TOKEN_FILE, VAULT_CONTAINER

Pre-requisito: customer-agent com porta LOCAL_RUNTIME_API_PORT publicada em 127.0.0.1 (docker-compose.yml).

Exemplos:
  bash scripts/vault-ops.sh check
  bash scripts/vault-ops.sh bootstrap
  bash scripts/vault-ops.sh status
  bash scripts/vault-ops.sh unseal
EOF
}

assert_agent_reachable() {
  if ! curl -sS -m 5 -o /dev/null -w '' "$AGENT_URL/health/live"; then
    echo "[vault-ops][erro] Customer-agent inacessivel em $AGENT_URL" >&2
    echo "[vault-ops] ACCAO: cd compose && docker compose up -d customer-agent" >&2
    echo "[vault-ops]        Verifique LOCAL_RUNTIME_API_PORT em compose/.env e binding 127.0.0.1 no docker-compose.yml." >&2
    return 1
  fi
}

assert_telegraf_collectors_health() {
  command -v curl >/dev/null 2>&1 || { echo "[vault-ops][erro] curl em falta" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "[vault-ops][erro] jq em falta (necessario para check)" >&2; return 1; }

  assert_agent_reachable || return 1

  local token
  token="$(read_token)" || return 1
  [[ -n "$token" ]] || { echo "[vault-ops][erro] token vazio" >&2; return 1; }

  local body
  body=$(curl -sS -H "X-Customer-Token: $token" "$AGENT_URL/local/vault/health")

  echo "$body" | jq '.telegrafCollectors // {filesPresent:false, approleLoginOk:false, detail:"missing"}'

  local files_ok login_ok detail
  files_ok=$(echo "$body" | jq -r '.telegrafCollectors.filesPresent // false')
  login_ok=$(echo "$body" | jq -r '.telegrafCollectors.approleLoginOk // false')
  detail=$(echo "$body" | jq -r '.telegrafCollectors.detail // empty')

  if [[ "$files_ok" == "true" && "$login_ok" == "true" ]]; then
    echo "[vault-ops] OK — telegrafCollectors (oms-telegraf AppRole) validos."
    return 0
  fi

  echo "[vault-ops][erro] telegrafCollectors invalidos ou em falta.${detail:+ ($detail)}" >&2
  echo "[vault-ops] ACCAO: Activar cofre (bootstrap) ou reset runtime limpo; depois bash scripts/vault-ops.sh check" >&2
  return 1
}

cmd_check() {
  echo "[vault-ops] docker exec $VAULT_CONTAINER vault status"
  if ! docker exec "$VAULT_CONTAINER" vault status 2>&1 | grep -qE 'Sealed[[:space:]]+false'; then
    echo "[vault-ops][erro] Vault selado ou inacessivel." >&2
    return 1
  fi
  echo "[vault-ops] Vault unsealed."
  assert_telegraf_collectors_health
}

read_token() {
  if [[ ! -f "$TOKEN_FILE" ]]; then
    echo "[vault-ops][erro] Token nao encontrado: $TOKEN_FILE" >&2
    return 1
  fi
  tr -d '\r\n' <"$TOKEN_FILE"
}

cmd_bootstrap() {
  local shares=5 threshold=3
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --shares) shares="$2"; shift 2 ;;
      --threshold) threshold="$2"; shift 2 ;;
      *) echo "[vault-ops][erro] Opcao desconhecida: $1" >&2; exit 2 ;;
    esac
  done

  command -v curl >/dev/null 2>&1 || { echo "[vault-ops][erro] curl em falta" >&2; exit 1; }

  local token
  token="$(read_token)" || exit 1
  [[ -n "$token" ]] || { echo "[vault-ops][erro] token vazio" >&2; exit 1; }

  assert_agent_reachable || exit 1

  echo "[vault-ops] POST $AGENT_URL/local/vault/bootstrap (shares=$shares threshold=$threshold)..."
  local http_code
  http_code=$(curl -sS -o /tmp/vault-ops-bootstrap.json -w '%{http_code}' \
    -X POST \
    -H "X-Customer-Token: $token" \
    -H "Content-Type: application/json" \
    -d "{\"keyShares\": $shares, \"keyThreshold\": $threshold}" \
    "$AGENT_URL/local/vault/bootstrap")

  if [[ "$http_code" != "200" ]]; then
    echo "[vault-ops][erro] HTTP $http_code" >&2
    cat /tmp/vault-ops-bootstrap.json >&2 2>/dev/null || true
    rm -f /tmp/vault-ops-bootstrap.json
    exit 1
  fi

  cat /tmp/vault-ops-bootstrap.json
  rm -f /tmp/vault-ops-bootstrap.json
  echo ""
  echo "[vault-ops] ACCAO: redireccione o JSON acima para cofre offline (2 locais)."
  echo "[vault-ops] Depois: bash scripts/vault-ops.sh ack-recovery (ou wizard Oramix Console → Concluir)."
  echo "[vault-ops] As keys NAO ficam gravadas em plaintext no host (ADR-011)."
}

cmd_ack_recovery() {
  command -v curl >/dev/null 2>&1 || { echo "[vault-ops][erro] curl em falta" >&2; exit 1; }
  local token
  token="$(read_token)" || exit 1
  [[ -n "$token" ]] || { echo "[vault-ops][erro] token vazio" >&2; exit 1; }

  assert_agent_reachable || exit 1

  echo "[vault-ops] POST $AGENT_URL/local/vault/ack-recovery-backup ..."
  local http_code
  http_code=$(curl -sS -o /tmp/vault-ops-ack.json -w '%{http_code}' \
    -X POST \
    -H "X-Customer-Token: $token" \
    "$AGENT_URL/local/vault/ack-recovery-backup")

  cat /tmp/vault-ops-ack.json
  echo ""
  rm -f /tmp/vault-ops-ack.json
  if [[ "$http_code" != "200" ]]; then
    echo "[vault-ops][erro] HTTP $http_code" >&2
    exit 1
  fi
}

cmd_provision_approle() {
  command -v curl >/dev/null 2>&1 || { echo "[vault-ops][erro] curl em falta" >&2; exit 1; }
  local token
  token="$(read_token)" || exit 1
  [[ -n "$token" ]] || { echo "[vault-ops][erro] token vazio" >&2; exit 1; }

  assert_agent_reachable || exit 1

  echo "[vault-ops] POST $AGENT_URL/local/vault/provision-approle ..."
  local http_code
  http_code=$(curl -sS -o /tmp/vault-ops-provision.json -w '%{http_code}' \
    -X POST \
    -H "X-Customer-Token: $token" \
    "$AGENT_URL/local/vault/provision-approle")

  cat /tmp/vault-ops-provision.json
  echo ""
  rm -f /tmp/vault-ops-provision.json
  if [[ "$http_code" != "200" ]]; then
    echo "[vault-ops][erro] HTTP $http_code (Vault unsealed? bootstrap completo?)" >&2
    exit 1
  fi
}

cmd_validate_telegraf() {
  echo "[vault-ops][aviso] validate-telegraf e alias de check; prefira: bash scripts/vault-ops.sh check" >&2
  cmd_check
}

cmd_status() {
  echo "[vault-ops] docker exec $VAULT_CONTAINER vault status"
  docker exec "$VAULT_CONTAINER" vault status 2>&1 || {
    echo "[vault-ops][aviso] Container Vault nao acessivel." >&2
    return 1
  }

  if [[ -f "$TOKEN_FILE" ]] && command -v curl >/dev/null 2>&1; then
    local token
    token="$(read_token)" 2>/dev/null || return 0
    if [[ -n "$token" ]] && assert_agent_reachable 2>/dev/null; then
      echo ""
      echo "[vault-ops] GET $AGENT_URL/local/vault/health"
      curl -sS -H "X-Customer-Token: $token" "$AGENT_URL/local/vault/health" | {
        if command -v jq >/dev/null 2>&1; then jq .; else cat; fi
      }
    else
      echo "[vault-ops][aviso] agent health indisponivel em $AGENT_URL" >&2
    fi
  fi
}

cmd_unseal() {
  local recovery="${1:-$RECOVERY_FILE}"
  if [[ ! -f "$recovery" ]]; then
    echo "[vault-ops][erro] Ficheiro recovery nao encontrado: $recovery" >&2
    exit 1
  fi

  local dir base
  dir="$(dirname "$recovery")"
  base="$(basename "$recovery")"

  for i in 0 1 2; do
    local key
    key=$(docker run --rm -v "$dir:/v" alpine:3.20 sh -c \
      "apk add -q jq >/dev/null 2>&1 && jq -r '.unseal_keys_b64[$i]' /v/$base")
    echo "[vault-ops] Unseal share $((i + 1))..."
    docker exec "$VAULT_CONTAINER" vault operator unseal "$key"
  done
  docker exec "$VAULT_CONTAINER" vault status
}

cmd_recovery_path() {
  if [[ -f "$RECOVERY_FILE" ]]; then
    echo "[vault-ops] AVISO: ficheiro legacy FIRST-BOOT ainda no disco:"
    echo "  $RECOVERY_FILE"
    echo "  ACCAO: backup offline (se ainda nao fez) e bash scripts/vault-ops.sh ack-recovery"
  else
    echo "[vault-ops] Sem ficheiro legacy FIRST-BOOT (esperado apos ADR-011 / ack)."
    echo "  Instalacoes novas: keys so na resposta de bootstrap (UI ou CLI)."
  fi
  if [[ -f "${COMPOSE_DIR}/secrets/vault/autounseal.bin" ]]; then
    echo "[vault-ops] autounseal.bin presente (auto-unseal no arranque do agent)."
  fi
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

CMD="$1"
shift

case "$CMD" in
  check) cmd_check "$@" ;;
  bootstrap) cmd_bootstrap "$@" ;;
  ack-recovery) cmd_ack_recovery "$@" ;;
  provision-approle) cmd_provision_approle "$@" ;;
  validate-telegraf) cmd_validate_telegraf "$@" ;;
  status) cmd_status "$@" ;;
  unseal) cmd_unseal "${1:-}" ;;
  recovery-path) cmd_recovery_path ;;
  -h|--help) usage ;;
  *)
    echo "[vault-ops][erro] Comando desconhecido: $CMD" >&2
    usage
    exit 2
    ;;
esac
