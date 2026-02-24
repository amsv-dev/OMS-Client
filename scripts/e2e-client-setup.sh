#!/usr/bin/env bash
# OMS Client — Setup E2E (sem token, para testes)
# Cria compose/.env e arranca o stack com TENANT_ID/ASSET_ID e2e-test.
# Usar quando o client já existe e queres validar o fluxo E2E sem install-oms-client.sh.
set -euo pipefail

OMS_CLIENT_DIR="${OMS_CLIENT_DIR:-$HOME/oms-client}"
COMPOSE_DIR="${COMPOSE_DIR:-$OMS_CLIENT_DIR/compose}"
TENANT_ID="${TENANT_ID:-e2e-test}"
ASSET_ID="${ASSET_ID:-e2e-test-site1}"
SOLACE_HOST="${SOLACE_HOST:-}"

usage() {
  cat <<'EOF'
OMS Client — Setup E2E (testes sem token)

Uso:
  bash scripts/e2e-client-setup.sh [--solace-host IP]

  --solace-host IP   IP do Solace (obrigatório se SOLACE_HOST não estiver definido)
  --tenant-id ID     Tenant (default: e2e-test)
  --asset-id ID      Asset (default: e2e-test-site1)
  --oms-client-dir   Raiz do client (default: $HOME/oms-client). Para clone OMSv2: use client

Exemplo (repo público com compose/, scripts/ na raiz):
  cd ~/oms-client && bash scripts/e2e-client-setup.sh --solace-host 10.69.105.41

Exemplo (clone OMSv2 com client/):
  cd ~/oms-client && bash client/scripts/e2e-client-setup.sh --oms-client-dir client --solace-host 10.69.105.41
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --solace-host) SOLACE_HOST="$2"; shift 2 ;;
    --tenant-id) TENANT_ID="$2"; shift 2 ;;
    --asset-id) ASSET_ID="$2"; shift 2 ;;
    --oms-client-dir) OMS_CLIENT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[e2e-setup][erro] Argumento desconhecido: $1" >&2; usage; exit 1 ;;
  esac
done

COMPOSE_DIR="${COMPOSE_DIR:-$OMS_CLIENT_DIR/compose}"

if [[ -z "$SOLACE_HOST" ]]; then
  echo "[e2e-setup][erro] SOLACE_HOST obrigatório. Use --solace-host <IP> ou export SOLACE_HOST=<IP>" >&2
  exit 1
fi

if [[ ! -f "$COMPOSE_DIR/docker-compose.yml" ]]; then
  echo "[e2e-setup][erro] docker-compose.yml não encontrado em $COMPOSE_DIR" >&2
  echo "[e2e-setup] Execute a partir de ~/oms-client (compose/, scripts/, automation/)" >&2
  exit 1
fi

echo "[e2e-setup] Tenant: $TENANT_ID | Asset: $ASSET_ID | Solace: $SOLACE_HOST"

# LOKI_URL: Cloud proxy (:8443) ou directo à Central (:3100). Solace host = Cloud quando remoto.
if [[ -n "$LOKI_URL" ]]; then
  : # já definido
else
  LOKI_HOST="${LOKI_HOST:-$SOLACE_HOST}"
  LOKI_URL="${LOKI_URL:-http://${LOKI_HOST}:8443/loki/api/v1/push}"
fi

# Criar compose/.env
mkdir -p "$COMPOSE_DIR"
cat > "$COMPOSE_DIR/.env" <<EOF
TENANT_ID=$TENANT_ID
ASSET_ID=$ASSET_ID
SOLACE__HOST=$SOLACE_HOST
SOLACE__PORT=1883
SOLACE__VPN=default
SOLACE__USERNAME=default
SOLACE__PASSWORD=default
LOKI_URL=$LOKI_URL
ASPNETCORE_ENVIRONMENT=Production
CLIENT_IMAGE_REGISTRY=omsv2client.azurecr.io
OMS_IMAGE_TAG=latest
EOF

echo "[e2e-setup] Criado $COMPOSE_DIR/.env"

# Pré-requisitos
docker network create oms-shared-network 2>/dev/null || true
docker volume create compose_influxdb-local-data 2>/dev/null || true

# Arrancar
cd "$(dirname "$COMPOSE_DIR")"
docker compose -f "$(basename "$COMPOSE_DIR")/docker-compose.yml" --env-file "$COMPOSE_DIR/.env" pull
docker compose -f "$(basename "$COMPOSE_DIR")/docker-compose.yml" --env-file "$COMPOSE_DIR/.env" up -d --force-recreate

echo "[e2e-setup] Concluído. Verificar: docker logs client-customer-agent 2>&1 | head -8"
echo "[e2e-setup] Deve mostrar Tenant/Asset: $TENANT_ID/$ASSET_ID"
