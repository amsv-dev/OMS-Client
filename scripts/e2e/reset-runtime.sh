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
    rm -rf /s/vault-approle /s/keys
    rm -f /s/telegraf-approle-role-id /s/telegraf-approle-secret-id
    rm -f /s/assessment-token.txt
    rm -f /td/*.conf /td/runtime/*.conf 2>/dev/null || true
    find /td -name "*.conf" -delete 2>/dev/null || true
  '

if [ -f "$ENV_FILE" ]; then
  sed -i '/^OMS_CREDSTORE_MODE=/d' "$ENV_FILE" 2>/dev/null || true
  # Restaurar assessment-token.txt a partir do .env (o wizard e o agent precisam dele).
  TOKEN_FROM_ENV="$(grep -E '^ASSESSMENT_TOKEN=' "$ENV_FILE" | head -1 | cut -d= -f2- || true)"
  if [ -n "${TOKEN_FROM_ENV:-}" ]; then
    printf '%s' "$TOKEN_FROM_ENV" > "$COMPOSE_DIR/secrets/assessment-token.txt"
    chmod 600 "$COMPOSE_DIR/secrets/assessment-token.txt" 2>/dev/null || true
    echo "[reset-runtime] assessment-token.txt restaurado a partir do .env"
  else
    echo "[reset-runtime] AVISO: ASSESSMENT_TOKEN em falta no .env — cole o token no wizard." >&2
  fi
fi

echo "[reset-runtime] Subir stack (vault + customer-agent + oramix-console)..."
docker compose -f "$COMPOSE_DIR/docker-compose.yml" --env-file "$ENV_FILE" pull vault customer-agent oramix-console 2>/dev/null || true
docker compose -f "$COMPOSE_DIR/docker-compose.yml" --env-file "$ENV_FILE" up -d --force-recreate vault customer-agent oramix-console

echo "[reset-runtime] Aguardar contentores (vault/agent/console)..."
sleep 5

# Após reset o Vault fica NÃO inicializado — o bootstrap faz-se no wizard da Console.
# Só reportamos estado; não esperar "unsealed" (isso só aplica a Vault já init).
if docker exec oms-vault vault status 2>/dev/null | grep -qE 'Initialized[[:space:]]+true'; then
  echo "[reset-runtime] Vault já inicializado — a aguardar unseal (max 60s)..."
  for i in $(seq 1 12); do
    if docker exec oms-vault vault status 2>/dev/null | grep -qE 'Sealed[[:space:]]+false'; then
      echo "[reset-runtime] Vault deselado e operacional."
      break
    fi
    sleep 5
  done
else
  echo "[reset-runtime] Vault não inicializado (esperado). Bootstrap no wizard: Token → Cofre."
fi

CONSOLE_PORT="$(grep -E '^CLIENT_ORAMIX_CONSOLE_HTTP_PORT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
CONSOLE_PORT="${CONSOLE_PORT:-3122}"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E 'vault|customer-agent|oramix-console|telegraf|influx' || true
echo "[reset-runtime] Concluido. Console: http://<IP-desta-VM>:${CONSOLE_PORT}/"
