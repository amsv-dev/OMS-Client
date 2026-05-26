#!/usr/bin/env bash
# Setup E2E sem token (laboratorio). Ver scripts/reset-client.sh para reset de producao.
set -euo pipefail

OMS_CLIENT_DIR="${OMS_CLIENT_DIR:-$HOME/oms-client}"
COMPOSE_DIR="${COMPOSE_DIR:-$OMS_CLIENT_DIR/compose}"
TENANT_ID="${TENANT_ID:-e2e-test}"
ASSET_ID="${ASSET_ID:-e2e-test-main}"
SOLACE_HOST="${SOLACE_HOST:-}"

usage() {
  cat <<'EOF'
OMS Client — Setup E2E (testes sem token)

Uso:
  bash scripts/e2e/e2e-client-setup.sh [--solace-host IP]

  --solace-host IP   IP do Solace (obrigatorio se SOLACE_HOST nao definido)
  --tenant-id ID     Tenant (default: e2e-test)
  --asset-id ID      Asset (default: e2e-test-main)
  --oms-client-dir   Raiz do projeto (default: $HOME/oms-client)

Exemplo:
  cd ~/oms-client && bash scripts/e2e/e2e-client-setup.sh --solace-host 10.69.105.41
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
  echo "[e2e-setup][erro] SOLACE_HOST obrigatorio. Use --solace-host <IP>" >&2
  exit 1
fi

if [[ ! -f "$COMPOSE_DIR/docker-compose.yml" ]]; then
  echo "[e2e-setup][erro] docker-compose.yml nao encontrado em $COMPOSE_DIR" >&2
  exit 1
fi

echo "[e2e-setup] Tenant: $TENANT_ID | Asset: $ASSET_ID | Solace: $SOLACE_HOST"

if [[ -z "${LOKI_URL:-}" ]]; then
  LOKI_HOST="${LOKI_HOST:-$SOLACE_HOST}"
  LOKI_URL="http://${LOKI_HOST}:8443/loki/api/v1/push"
fi

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
CLIENT_IMAGE_REGISTRY=ghcr.io/amsv-dev
OMS_IMAGE_TAG=latest
EOF

docker network create oms-shared-network 2>/dev/null || true
docker volume create compose_influxdb-local-data 2>/dev/null || true

cd "$OMS_CLIENT_DIR"
docker compose -f compose/docker-compose.yml --env-file compose/.env pull
docker compose -f compose/docker-compose.yml --env-file compose/.env up -d --force-recreate

echo "[e2e-setup] Concluido."
