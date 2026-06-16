#!/usr/bin/env bash
# OMS Client - Update (apos git pull)
# Corrige LOKI_URL, pull de imagens (incl. Vault) e recria containers do runtime.
set -euo pipefail

usage() {
  cat <<'EOF'
OMS Client - Update do runtime (VM)

Fluxo suportado (operador na VM):
  cd ~/oms-client
  git pull origin main
  bash scripts/update-oms-client.sh

O script:
  - Valida .env e token de assessment
  - Corrige LOKI_URL (Cloud :3100 -> api-proxy :8443) quando aplicavel
  - docker compose pull  (todas as imagens: vault, agent, oramix-console, telegraf, ...)
  - docker compose up -d --remove-orphans --force-recreate
  - Espera Vault unsealed (auto-unseal pelo customer-agent)

Nao faz reset do cofre nem apaga volumes. Para runtime limpo: bash scripts/reset-client.sh --runtime

Pre-requisito: imagens publicadas no registry (pipeline) e compose atualizado via git pull.
EOF
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMS_CLIENT_DIR="${OMS_CLIENT_DIR:-$(dirname "$SCRIPT_DIR")}"
COMPOSE_DIR="${COMPOSE_DIR:-$OMS_CLIENT_DIR/compose}"
ENV_FILE="${COMPOSE_DIR}/.env"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "[update] .env nao encontrado em $ENV_FILE. Nada a fazer." >&2
  exit 0
fi

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "[update][erro] docker-compose.yml nao encontrado em $COMPOSE_FILE" >&2
  exit 1
fi

set +u
# shellcheck source=/dev/null
source "$ENV_FILE" 2>/dev/null || true
set -u

for required in CENTRAL_API_URL ASSESSMENT_TOKEN ASSET_ID RUNTIME_ASSET_ID; do
  value="${!required:-}"
  if [[ -z "$value" ]]; then
    echo "[update][erro] ${required} vazio em $ENV_FILE." >&2
    echo "[update][erro] Corrija com: bash scripts/install-oms-client.sh <TOKEN> <API_URL>" >&2
    exit 1
  fi
done

# Aviso se o repo git esta desatualizado (nao aborta).
if command -v git >/dev/null 2>&1 && git -C "$OMS_CLIENT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$OMS_CLIENT_DIR" fetch origin main --quiet 2>/dev/null || true
  behind="$(git -C "$OMS_CLIENT_DIR" rev-list --count HEAD..origin/main 2>/dev/null || echo "?")"
  if [[ "$behind" =~ ^[0-9]+$ && "$behind" -gt 0 ]]; then
    echo "[update][aviso] O repo local esta $behind commit(s) atras de origin/main."
    echo "[update][aviso] Recomendado: git pull origin main  (antes ou depois deste script)."
  fi
fi

# Aviso se o mount do Vault no agent ainda for read-only.
if grep -qE './secrets/vault:/vault/secrets:ro' "$COMPOSE_FILE" 2>/dev/null; then
  echo "[update][aviso] compose ainda tem secrets/vault :ro — bootstrap do cofre vai falhar."
  echo "[update][aviso] Corrija com git pull (deve ser :rw no customer-agent)."
fi

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
    echo "[update] LOKI_URL porta $LOKI_PORT inesperada. Revise manualmente (Cloud: :8443)." >&2
  fi
fi

OMS_COMPOSE_PROJECT_NAME="${OMS_COMPOSE_PROJECT_NAME:-compose}"
OMS_IMAGE_TAG="${OMS_IMAGE_TAG:-latest}"
echo "[update] Tag de imagens OMS: ${OMS_IMAGE_TAG}"
echo "[update] Compose: $COMPOSE_FILE"

dc() {
  docker compose -p "$OMS_COMPOSE_PROJECT_NAME" \
    -f "$COMPOSE_FILE" \
    --env-file "$ENV_FILE" \
    "$@"
}

echo "[update] Pull de imagens (vault, customer-agent, oramix-console, telegraf, influx, promtail, ...)"
dc pull

echo "[update] Recriar stack (--force-recreate para aplicar imagens novas)..."
dc up -d --remove-orphans --force-recreate

echo "[update] Aguardar Vault unsealed (auto-unseal via customer-agent, max 90s)..."
vault_ok=0
for i in $(seq 1 45); do
  if docker exec oms-vault vault status 2>/dev/null | grep -qE 'Sealed[[:space:]]+false'; then
    vault_ok=1
    echo "[update] Vault unsealed."
    break
  fi
  sleep 2
done
if [[ "$vault_ok" -eq 0 ]]; then
  echo "[update][aviso] Vault ainda selado ou inacessivel. Ver: docker logs client-customer-agent | grep VaultUnseal" >&2
fi

echo "[update] Estado dos containers:"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' \
  | grep -E 'vault|customer-agent|oramix-console|telegraf|influx|promtail' || true

echo "[update] Concluido."
echo "[update] Oramix Console: http://<IP-VM>:${CLIENT_ORAMIX_CONSOLE_HTTP_PORT:-3122}/"
