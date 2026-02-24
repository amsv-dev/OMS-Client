#!/usr/bin/env bash
# OMS Client — Update (após git pull)
# Corrige LOKI_URL e reinicia containers. Executar após git pull para aplicar correções.
set -euo pipefail

usage() {
  cat <<'EOF'
OMS Client — Update (após git pull)

Uso:
  bash scripts/update-oms-client.sh

Corrige LOKI_URL quando SOLACE_HOST é Cloud (api-proxy :8443) mas .env tinha :3100.
Reinicia Promtail para aplicar alterações.

Executar após: git pull && bash scripts/update-oms-client.sh
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

# Detectar compose dir: scripts/../compose (OMSv2: client/scripts->client/compose; OMS-Client: scripts->compose)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-$SCRIPT_DIR/../compose}"
ENV_FILE="${COMPOSE_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[update] .env não encontrado em $ENV_FILE. Nada a fazer." >&2
  exit 0
fi

# Carregar .env
set +u
# shellcheck source=/dev/null
source "$ENV_FILE" 2>/dev/null || true
set -u

SOLACE_HOST="${SOLACE__HOST:-$SOLACE_HOST}"
if [[ -z "$SOLACE_HOST" ]]; then
  echo "[update] SOLACE__HOST não definido. Skip correção LOKI_URL." >&2
  exit 0
fi

# Corrigir LOKI_URL: se aponta para SOLACE_HOST:3100, deve ser :8443 (api-proxy)
CURRENT_LOKI="${LOKI_URL:-}"
if [[ -z "$CURRENT_LOKI" ]]; then
  echo "[update] LOKI_URL não definido. Skip." >&2
  exit 0
fi

# Extrair host e port da LOKI_URL atual
LOKI_HOST="$(echo "$CURRENT_LOKI" | sed -E 's|https?://([^:/]+).*|\1|')"
LOKI_PORT="$(echo "$CURRENT_LOKI" | sed -E 's|https?://[^:]+:([0-9]+).*|\1|')"

if [[ "$LOKI_HOST" != "$SOLACE_HOST" ]]; then
  echo "[update] LOKI_URL host ($LOKI_HOST) != SOLACE_HOST ($SOLACE_HOST). Nada a corrigir."
  exit 0
fi

if [[ "$LOKI_PORT" == "8443" ]]; then
  echo "[update] LOKI_URL já correto (porta 8443)."
  exit 0
fi

if [[ "$LOKI_PORT" == "3100" ]]; then
  NEW_LOKI="http://${SOLACE_HOST}:8443/loki/api/v1/push"
  echo "[update] Corrigir LOKI_URL: $CURRENT_LOKI -> $NEW_LOKI"
  if grep -q '^LOKI_URL=' "$ENV_FILE"; then
    sed -i "s|^LOKI_URL=.*|LOKI_URL=$NEW_LOKI|" "$ENV_FILE"
  else
    echo "LOKI_URL=$NEW_LOKI" >> "$ENV_FILE"
  fi
else
  echo "[update] LOKI_URL porta $LOKI_PORT inesperada. Se Cloud, use :8443." >&2
  exit 1
fi

# Reiniciar Promtail
echo "[update] Reiniciar Promtail..."
cd "$(dirname "$COMPOSE_DIR")"
docker compose -f "$(basename "$COMPOSE_DIR")/docker-compose.yml" --env-file "$ENV_FILE" up -d promtail 2>/dev/null || true

echo "[update] Concluído."
