#!/usr/bin/env bash
# Reset do runtime client (volumes Vault/Influx + secrets). Implementação de reset-client.sh --runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-$ROOT/compose}"
ENV_FILE="$COMPOSE_DIR/.env"

cd "$ROOT"

echo "[reset-runtime] Parar stack..."
docker compose -f "$COMPOSE_DIR/docker-compose.yml" --env-file "$ENV_FILE" down --remove-orphans 2>/dev/null || true

echo "[reset-runtime] Apagar volumes Vault + Influx..."
docker volume rm compose_vault-file compose_vault-logs 2>/dev/null || true
docker volume rm compose_influxdb-local-data 2>/dev/null || true
docker volume create compose_influxdb-local-data 2>/dev/null || true

echo "[reset-runtime] Limpar secrets..."
docker run --rm \
  -v "$COMPOSE_DIR/secrets:/s" \
  -v "$COMPOSE_DIR/telegraf/dynamic:/td" \
  alpine:3.20 sh -c '
    rm -f /s/vault/.autounseal-key /s/vault/autounseal.key /s/vault/autounseal.bin
    rm -f /s/vault/.initialized /s/vault/.unsealed
    rm -f /s/vault/recovery-keys-FIRST-BOOT-ONLY.json /s/vault/.bootstrap-done 2>/dev/null || true
    rm -f /s/logical-secret-store.json /s/logical-secret-store.json.bak
    rm -rf /s/vault-approle /s/telegraf-vault-token /s/keys
    rm -f /s/assessment-token.txt
    rm -f /td/*.conf /td/runtime/*.conf 2>/dev/null || true
    find /td -name "*.conf" -delete 2>/dev/null || true
  '

if [ -f "$ENV_FILE" ]; then
  sed -i '/^OMS_CREDSTORE_MODE=/d' "$ENV_FILE" 2>/dev/null || true
fi

echo "[reset-runtime] Subir stack (vault + customer-agent)..."
docker compose -f "$COMPOSE_DIR/docker-compose.yml" --env-file "$ENV_FILE" pull vault customer-agent 2>/dev/null || true
docker compose -f "$COMPOSE_DIR/docker-compose.yml" --env-file "$ENV_FILE" up -d --force-recreate vault customer-agent

echo "[reset-runtime] Aguardar Vault unsealed (max 120s)..."
for i in $(seq 1 24); do
  if docker exec oms-vault vault status 2>/dev/null | grep -qE 'Sealed[[:space:]]+false'; then
    echo "[reset-runtime] Vault deselado e operacional."
    break
  fi
  sleep 5
  if [ "$i" -eq 24 ]; then
    echo "[reset-runtime] AVISO: Vault ainda selado. Proximo: vault-ops.sh bootstrap ou logs do agent." >&2
  fi
done

docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E 'vault|customer-agent|assessment|telegraf|influx' || true
echo "[reset-runtime] Concluido."
