#!/usr/bin/env bash
# OMS Client - Update (apos git pull)
# Corrige LOKI_URL e faz refresh das imagens/containers do runtime.
set -euo pipefail

usage() {
  cat <<'EOF'
OMS Client - Update (apos git pull)

Uso:
  bash scripts/update-oms-client.sh

Corrige LOKI_URL quando SOLACE_HOST e Cloud (api-proxy :8443) mas .env tinha :3100.
Depois força pull das imagens e recria os containers do runtime para evitar cache antiga.

Executar apos: git pull && bash scripts/update-oms-client.sh
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

# Detectar compose dir: scripts/../compose (OMSv2: client/scripts->client/compose; OMS-Client: scripts->compose)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-$SCRIPT_DIR/../compose}"
ENV_FILE="${COMPOSE_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[update] .env nao encontrado em $ENV_FILE. Nada a fazer." >&2
  exit 0
fi

# Carregar .env
set +u
# shellcheck source=/dev/null
source "$ENV_FILE" 2>/dev/null || true
set -u

# Hard guard: update nao deve seguir com self-service incompleto.
for required in CENTRAL_API_URL ASSESSMENT_TOKEN ASSET_ID RUNTIME_ASSET_ID; do
  value="${!required:-}"
  if [[ -z "$value" ]]; then
    echo "[update][erro] ${required} vazio em $ENV_FILE." >&2
    echo "[update][erro] Corrija com o fluxo padrao:" >&2
    echo "  bash scripts/install-oms-client.sh <TOKEN> <API_URL> [--site-code <code>]" >&2
    exit 1
  fi
done

TOKEN_FILE_PATH="${COMPOSE_DIR}/secrets/assessment-token.txt"
mkdir -p "${COMPOSE_DIR}/secrets"
if [[ ! -f "$TOKEN_FILE_PATH" || ! -s "$TOKEN_FILE_PATH" ]]; then
  printf '%s' "${ASSESSMENT_TOKEN}" > "$TOKEN_FILE_PATH"
  chmod 600 "$TOKEN_FILE_PATH" 2>/dev/null || true
fi
if ! grep -q '^ASSESSMENT_TOKEN_FILE=' "$ENV_FILE"; then
  echo "ASSESSMENT_TOKEN_FILE=/app/secrets/assessment-token.txt" >> "$ENV_FILE"
fi
if ! grep -q '^OMS_COMPOSE_HOST_PROJECT_DIR=' "$ENV_FILE"; then
  echo "OMS_COMPOSE_HOST_PROJECT_DIR=$COMPOSE_DIR" >> "$ENV_FILE"
fi

# Opcional: corrigir LOKI_URL (Cloud: :3100 -> api-proxy :8443). Nunca abortar antes do pull das imagens.
SOLACE_HOST="${SOLACE__HOST:-$SOLACE_HOST}"
if [[ -z "$SOLACE_HOST" ]]; then
  echo "[update] SOLACE__HOST nao definido. Skip correcao LOKI_URL."
elif [[ -z "${LOKI_URL:-}" ]]; then
  echo "[update] LOKI_URL nao definido. Skip correcao LOKI_URL."
else
  CURRENT_LOKI="${LOKI_URL}"
  LOKI_HOST="$(echo "$CURRENT_LOKI" | sed -E 's|https?://([^:/]+).*|\1|')"
  LOKI_PORT="$(echo "$CURRENT_LOKI" | sed -E 's|https?://[^:]+:([0-9]+).*|\1|')"

  if [[ "$LOKI_HOST" != "$SOLACE_HOST" ]]; then
    echo "[update] LOKI_URL host ($LOKI_HOST) != SOLACE_HOST ($SOLACE_HOST). Nada a corrigir."
  elif [[ "$LOKI_PORT" == "8443" ]]; then
    echo "[update] LOKI_URL ja correto (porta 8443)."
  elif [[ "$LOKI_PORT" == "3100" ]]; then
    NEW_LOKI="http://${SOLACE_HOST}:8443/loki/api/v1/push"
    echo "[update] Corrigir LOKI_URL: $CURRENT_LOKI -> $NEW_LOKI"
    if grep -q '^LOKI_URL=' "$ENV_FILE"; then
      sed -i "s|^LOKI_URL=.*|LOKI_URL=$NEW_LOKI|" "$ENV_FILE"
    else
      echo "LOKI_URL=$NEW_LOKI" >> "$ENV_FILE"
    fi
  else
    echo "[update] LOKI_URL porta $LOKI_PORT inesperada. Revise manualmente (Cloud: :8443). Pull de imagens segue em frente." >&2
  fi
fi

# Refresh runtime completo
OMS_COMPOSE_PROJECT_NAME="${OMS_COMPOSE_PROJECT_NAME:-compose}"

echo "[update] Pull de imagens do runtime..."
cd "$(dirname "$COMPOSE_DIR")"
docker compose -p "$OMS_COMPOSE_PROJECT_NAME" -f "$(basename "$COMPOSE_DIR")/docker-compose.yml" --env-file "$ENV_FILE" pull

echo "[update] Recriar stack do runtime..."
docker compose -p "$OMS_COMPOSE_PROJECT_NAME" -f "$(basename "$COMPOSE_DIR")/docker-compose.yml" --env-file "$ENV_FILE" up -d --remove-orphans

echo "[update] Concluido."
