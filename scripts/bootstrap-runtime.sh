#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
OMS Client Runtime Bootstrap (Self-Service)

Usage:
  bash client/scripts/bootstrap-runtime.sh \
    --api-url "https://oms-central.example.com" \
    --assessment-token "<token>" \
    --tenant-id "<tenantId>" \
    --asset-id "<assetId>" \
    --issued-at "<ISO8601>" \
    --expires-at "<ISO8601>" \
    --nonce "<nonce>" \
    --signature "<signature>" \
    --solace-host "<host>" \
    --solace-username "<username>" \
    --solace-password "<password>" \
    [--site-code "<siteCode>"] \
    [--image-registry "omsv2client.azurecr.io"] \
    [--image-tag "latest"] \
    [--compose-dir "global/client/compose"]
EOF
}

API_URL=""
ASSESSMENT_TOKEN=""
TENANT_ID=""
ASSET_ID=""
SITE_CODE=""
ISSUED_AT=""
EXPIRES_AT=""
NONCE=""
SIGNATURE=""
SOLACE_HOST=""
SOLACE_USERNAME=""
SOLACE_PASSWORD=""
CLIENT_IMAGE_REGISTRY="omsv2client.azurecr.io"
IMAGE_TAG="latest"
COMPOSE_DIR="global/client/compose"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-url) API_URL="$2"; shift 2 ;;
    --assessment-token) ASSESSMENT_TOKEN="$2"; shift 2 ;;
    --tenant-id) TENANT_ID="$2"; shift 2 ;;
    --asset-id) ASSET_ID="$2"; shift 2 ;;
    --site-code) SITE_CODE="$2"; shift 2 ;;
    --issued-at) ISSUED_AT="$2"; shift 2 ;;
    --expires-at) EXPIRES_AT="$2"; shift 2 ;;
    --nonce) NONCE="$2"; shift 2 ;;
    --signature) SIGNATURE="$2"; shift 2 ;;
    --solace-host) SOLACE_HOST="$2"; shift 2 ;;
    --solace-username) SOLACE_USERNAME="$2"; shift 2 ;;
    --solace-password) SOLACE_PASSWORD="$2"; shift 2 ;;
    --acr-login-server) CLIENT_IMAGE_REGISTRY="$2"; shift 2 ;;
    --image-registry) CLIENT_IMAGE_REGISTRY="$2"; shift 2 ;;
    --image-tag) IMAGE_TAG="$2"; shift 2 ;;
    --compose-dir) COMPOSE_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[bootstrap][erro] Argumento desconhecido: $1" >&2; usage; exit 1 ;;
  esac
done

required_vars=(
  API_URL
  ASSESSMENT_TOKEN
  TENANT_ID
  ASSET_ID
  ISSUED_AT
  EXPIRES_AT
  NONCE
  SIGNATURE
  SOLACE_HOST
  SOLACE_USERNAME
  SOLACE_PASSWORD
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "[bootstrap][erro] Parametro obrigatório em falta: ${var_name}" >&2
    usage
    exit 1
  fi
done

command -v curl >/dev/null 2>&1 || { echo "[bootstrap][erro] curl não encontrado."; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "[bootstrap][erro] docker não encontrado."; exit 1; }

if [[ ! -f "${COMPOSE_DIR}/docker-compose.yml" ]]; then
  echo "[bootstrap][erro] docker-compose.yml não encontrado em ${COMPOSE_DIR}" >&2
  exit 1
fi

echo "[bootstrap] Validar runtime identity bundle com OMS Central..."
validation_payload="$(cat <<EOF
{
  "assessmentToken": "${ASSESSMENT_TOKEN}",
  "bundle": {
    "tenantId": "${TENANT_ID}",
    "assetId": "${ASSET_ID}",
    "siteCode": "${SITE_CODE}",
    "issuedAtUtc": "${ISSUED_AT}",
    "expiresAtUtc": "${EXPIRES_AT}",
    "nonce": "${NONCE}",
    "signatureVersion": "hmac-sha256-v1",
    "signature": "${SIGNATURE}"
  }
}
EOF
)"

validation_response="$(curl -fsS \
  -X POST "${API_URL%/}/api/assessment/runtime/validate-bundle" \
  -H "Content-Type: application/json" \
  --data "${validation_payload}")"

echo "[bootstrap] Bundle validado: ${validation_response}"

cat > "${COMPOSE_DIR}/.env" <<EOF
TENANT_ID=${TENANT_ID}
ASSET_ID=${ASSET_ID}
SOLACE__HOST=${SOLACE_HOST}
SOLACE__PORT=1883
SOLACE__VPN=default
SOLACE__USERNAME=${SOLACE_USERNAME}
SOLACE__PASSWORD=${SOLACE_PASSWORD}
ASPNETCORE_ENVIRONMENT=Production
CLIENT_IMAGE_REGISTRY=${CLIENT_IMAGE_REGISTRY}
OMS_IMAGE_TAG=${IMAGE_TAG}
EOF

echo "[bootstrap] Arrancar stack cliente..."
docker compose -f "${COMPOSE_DIR}/docker-compose.yml" --env-file "${COMPOSE_DIR}/.env" up -d --remove-orphans
echo "[bootstrap] Concluído."
