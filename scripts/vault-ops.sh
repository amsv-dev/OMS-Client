#!/usr/bin/env bash
# Operacoes do cofre HashiCorp Vault na VM cliente (CLI).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-$CLIENT_ROOT/compose}"
TOKEN_FILE="${ASSESSMENT_TOKEN_FILE:-$COMPOSE_DIR/secrets/assessment-token.txt}"
AGENT_URL="${CUSTOMER_AGENT_URL:-http://127.0.0.1:5808}"
RECOVERY_FILE="${COMPOSE_DIR}/secrets/vault/recovery-keys-FIRST-BOOT-ONLY.json"
VAULT_CONTAINER="${VAULT_CONTAINER:-oms-vault}"

usage() {
  cat <<'EOF'
OMS Client — Vault ops (cofre local)

Uso:
  bash scripts/vault-ops.sh <comando> [opcoes]

Comandos:
  bootstrap [--shares N] [--threshold M]   Inicializa Vault (1x); imprime recovery keys no stdout (ADR-011)
  ack-recovery                             Confirma backup offline; apaga ficheiro legacy se existir
  provision-approle                        Verifica/repara AppRole (apos bootstrap)
  status                                   vault status + health via agent (se token disponivel)
  unseal [recovery.json]                   Unseal manual com 3 primeiras keys (backup offline)
  recovery-path                            Estado legacy FIRST-BOOT / autounseal.bin

Variaveis:
  COMPOSE_DIR, CUSTOMER_AGENT_URL, ASSESSMENT_TOKEN_FILE, VAULT_CONTAINER

Exemplos:
  bash scripts/vault-ops.sh bootstrap
  bash scripts/vault-ops.sh status
  bash scripts/vault-ops.sh unseal
EOF
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
  echo "[vault-ops] Depois: bash scripts/vault-ops.sh ack-recovery (ou wizard Assessment → Concluir)."
  echo "[vault-ops] As keys NAO ficam gravadas em plaintext no host (ADR-011)."
}

cmd_ack_recovery() {
  command -v curl >/dev/null 2>&1 || { echo "[vault-ops][erro] curl em falta" >&2; exit 1; }
  local token
  token="$(read_token)" || exit 1
  [[ -n "$token" ]] || { echo "[vault-ops][erro] token vazio" >&2; exit 1; }

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

cmd_status() {
  echo "[vault-ops] docker exec $VAULT_CONTAINER vault status"
  docker exec "$VAULT_CONTAINER" vault status 2>&1 || {
    echo "[vault-ops][aviso] Container Vault nao acessivel." >&2
    return 1
  }

  if [[ -f "$TOKEN_FILE" ]] && command -v curl >/dev/null 2>&1; then
    local token
    token="$(read_token)" 2>/dev/null || return 0
    if [[ -n "$token" ]]; then
      echo ""
      echo "[vault-ops] GET $AGENT_URL/local/vault/health"
      curl -sS -H "X-Customer-Token: $token" "$AGENT_URL/local/vault/health" 2>/dev/null | {
        if command -v jq >/dev/null 2>&1; then jq .; else cat; fi
      } || echo "[vault-ops][aviso] agent health indisponivel" >&2
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
  bootstrap) cmd_bootstrap "$@" ;;
  ack-recovery) cmd_ack_recovery "$@" ;;
  provision-approle) cmd_provision_approle "$@" ;;
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
