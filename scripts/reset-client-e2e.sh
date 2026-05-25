#!/bin/bash
# Reset E2E do runtime client (demo). Apaga Vault, credenciais legacy, telegraf dynamic, influx local.
# Uso: bash scripts/reset-client-e2e.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_DIR="$ROOT/compose"
ENV_FILE="$COMPOSE_DIR/.env"

cd "$ROOT"

echo "[reset] Parar stack..."
docker compose -f "$COMPOSE_DIR/docker-compose.yml" --env-file "$ENV_FILE" down --remove-orphans 2>/dev/null || true

echo "[reset] Apagar volumes Vault + Influx..."
docker volume rm compose_vault-file compose_vault-logs 2>/dev/null || true
docker volume rm compose_influxdb-local-data 2>/dev/null || true
docker volume create compose_influxdb-local-data 2>/dev/null || true

echo "[reset] Limpar secrets (incl. ficheiros root via container alpine)..."
docker run --rm \
  -v "$COMPOSE_DIR/secrets:/s" \
  -v "$COMPOSE_DIR/telegraf/dynamic:/td" \
  alpine:3.20 sh -c '
    rm -f /s/vault/.autounseal-key /s/vault/autounseal.key /s/vault/.initialized /s/vault/.unsealed
    rm -f /s/vault/recovery-keys-FIRST-BOOT-ONLY.json /s/vault/.bootstrap-done 2>/dev/null || true
    rm -f /s/logical-secret-store.json /s/logical-secret-store.json.bak
    rm -rf /s/vault-approle /s/telegraf-vault-token /s/keys
    rm -f /s/assessment-token.txt
    rm -f /td/*.conf /td/runtime/*.conf 2>/dev/null || true
    find /td -name "*.conf" -delete 2>/dev/null || true
  '

echo "[reset] Garantir OMS_CREDSTORE_MODE=File no .env..."
if [ -f "$ENV_FILE" ]; then
  if grep -q '^OMS_CREDSTORE_MODE=' "$ENV_FILE"; then
    sed -i 's/^OMS_CREDSTORE_MODE=.*/OMS_CREDSTORE_MODE=File/' "$ENV_FILE"
  else
    echo 'OMS_CREDSTORE_MODE=File' >> "$ENV_FILE"
  fi
else
  echo "AVISO: $ENV_FILE nao existe; copiar de .env.example"
fi

echo "[reset] Subir stack..."
docker compose -f "$COMPOSE_DIR/docker-compose.yml" --env-file "$ENV_FILE" pull vault customer-agent telegraf oms-assessment-v2 2>/dev/null || true
docker compose -f "$COMPOSE_DIR/docker-compose.yml" --env-file "$ENV_FILE" up -d

echo "[reset] Aguardar Vault (max 120s)..."
for i in $(seq 1 24); do
  if docker exec oms-vault vault status 2>/dev/null | grep -q 'Sealed.*false'; then
    echo "[reset] Vault deselado e operacional."
    break
  fi
  sleep 5
  if [ "$i" -eq 24 ]; then
    echo "[reset] AVISO: Vault ainda selado ou unhealthy. Ver: docker logs oms-vault --tail 50"
  fi
done

docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E 'vault|customer-agent|assessment|telegraf|influx' || true
echo "[reset] Concluido. Proximo: criar tenant na Central, colar token em compose/secrets/assessment-token.txt, validar na UI."
