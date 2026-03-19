#!/usr/bin/env bash
# OMS Client — Instalação self-service (só precisa do token)
# A Central devolve tudo (bundle, Solace, apiUrl). O client só precisa do token.
set -euo pipefail

# URLs e conexões — via parâmetro ou env (Azure variable groups, .env export, etc). Sem IPs hardcoded.
API_URL="${API_URL:-}"
API_PROXY_PORT="${API_PROXY_PORT:-8443}"
LOKI_PORT="${LOKI_PORT:-3100}"
CLIENT_IMAGE_REGISTRY="${CLIENT_IMAGE_REGISTRY:-ghcr.io/amsv-dev}"
OMS_IMAGE_TAG="${OMS_IMAGE_TAG:-latest}"
SOLACE_PORT="${SOLACE_PORT:-1883}"
SOLACE_VPN="${SOLACE_VPN:-default}"

TOKEN=""
SITE_CODE="${SITE_CODE:-}"
COMPOSE_DIR="${COMPOSE_DIR:-}"
OMS_CLIENT_DIR="${OMS_CLIENT_DIR:-$HOME/oms-client}"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo '')"
HOSTNAME_SHORT="${HOSTNAME_SHORT,,}"

usage() {
  cat <<'EOF'
OMS Client — Instalação self-service (token único)

Uso:
  bash install-oms-client.sh <TOKEN> [API_URL]

  TOKEN   — Token de onboarding (obrigatório, enviado pelo admin)
  API_URL — URL da API (parâmetro ou env API_URL; ex: Cloud proxy :8443 ou Central :5000)

Opções:
  --site-code CODE   Site code para assetId (ex: site1 → e2e-test-site1)
  --compose-dir DIR  Diretório do compose
  --oms-client-dir   Raiz do projeto client

Exemplo:
  API_URL=http://<cloud>:8443 bash install-oms-client.sh <TOKEN> --site-code site1
  bash install-oms-client.sh <TOKEN> http://<central>:5000 --site-code site1

A Central devolve: bundle (tenantId, assetId), Solace. O client só precisa do token.
EOF
}

normalize_site_code() {
  local raw="${1:-}"
  local normalized
  normalized="$(echo "$raw" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  [[ -n "$normalized" ]] && echo "$normalized" || echo "main"
}

detect_primary_ip() {
  local ip=""
  if command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  if [[ -z "$ip" ]] && command -v ip >/dev/null 2>&1; then
    ip="$(ip -o -4 route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i==\"src\") {print $(i+1); exit}}')"
  fi
  echo "$ip"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --site-code) SITE_CODE="$2"; shift 2 ;;
    --compose-dir) COMPOSE_DIR="$2"; shift 2 ;;
    --oms-client-dir) OMS_CLIENT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      [[ -z "$TOKEN" ]] && TOKEN="$1" || { [[ -z "$API_URL" ]] && [[ "${1:0:1}" != "-" ]] && API_URL="$1"; }
      shift
      ;;
  esac
done

# API_URL: parâmetro posicional ou env. Se vazio, pedir interativamente.

COMPOSE_DIR="${COMPOSE_DIR:-$OMS_CLIENT_DIR/compose}"
OMS_CLIENT_REPO="${OMS_CLIENT_REPO:-https://github.com/amsv-dev/OMS-Client.git}"

# Pré-requisitos: git, curl (instalar se Debian/Ubuntu)
if [[ -f /etc/debian_version ]]; then
  NEED_APT=
  command -v git >/dev/null 2>&1 || NEED_APT=1
  command -v curl >/dev/null 2>&1 || NEED_APT=1
  if [[ -n "$NEED_APT" ]]; then
    echo "[install] A instalar git e curl..."
    sudo apt-get update -y
    sudo apt-get install -y git curl ca-certificates
  fi
fi
command -v git >/dev/null 2>&1 || { echo "[erro] git não encontrado. Instale: sudo apt-get install git" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "[erro] curl não encontrado. Instale: sudo apt-get install curl" >&2; exit 1; }

# Se o repo não existe, clonar (bootstrap: script pode ser executado via curl sem clone prévio)
if [[ ! -f "$COMPOSE_DIR/docker-compose.yml" ]]; then
  echo "[install] Repo não encontrado. A clonar $OMS_CLIENT_REPO para $OMS_CLIENT_DIR..."
  mkdir -p "$(dirname "$OMS_CLIENT_DIR")"
  git clone --depth 1 "$OMS_CLIENT_REPO" "$OMS_CLIENT_DIR"
  echo "[install] Clone concluído."
fi

# Validar token
if [[ -z "$TOKEN" ]]; then
  echo -n "Token de onboarding: "
  read -r TOKEN
  [[ -z "$TOKEN" ]] && { echo "[erro] Token obrigatório." >&2; exit 1; }
fi

# API URL (necessário para chamar a Central)
if [[ -z "$API_URL" ]]; then
  echo -n "URL da API (Cloud proxy :8443 ou Central :5000): "
  read -r API_URL
  [[ -z "$API_URL" ]] && { echo "[erro] URL da API obrigatória." >&2; exit 1; }
fi
API_URL="${API_URL%/}"

if [[ -z "$SITE_CODE" ]]; then
  SITE_CODE="$(normalize_site_code "$HOSTNAME_SHORT")"
else
  SITE_CODE="$(normalize_site_code "${SITE_CODE,,}")"
fi
HOST_IP="$(detect_primary_ip)"

echo "[install] A obter dados da Central (token válido)..."
VALIDATE_URL="${API_URL}/api/assessment/validate"
[[ -n "$SITE_CODE" ]] && VALIDATE_URL="${VALIDATE_URL}?siteCode=${SITE_CODE}"
RESPONSE="$(curl -fsS -H "X-Customer-Token: $TOKEN" "$VALIDATE_URL")"

# Extrair campos do JSON (python3 ou jq)
extract() {
  local key="$1"
  if command -v jq &>/dev/null; then
    echo "$RESPONSE" | jq -r ".${key} // empty"
  else
    echo "$RESPONSE" | python3 -c "
import json,sys
d=json.load(sys.stdin)
keys='${key}'.split('.')
v=d
for k in keys:
  v=v.get(k) if isinstance(v,dict) else None
  if v is None: break
print(v or '')
" 2>/dev/null || echo ""
  fi
}

TENANT_ID="$(extract "runtimeIdentity.tenantId")"
ASSET_ID="$(extract "runtimeIdentity.assetId")"
ISSUED_AT="$(extract "runtimeIdentity.issuedAtUtc")"
EXPIRES_AT="$(extract "runtimeIdentity.expiresAtUtc")"
NONCE="$(extract "runtimeIdentity.nonce")"
SIGNATURE="$(extract "runtimeIdentity.signature")"
SITE_CODE="$(extract "runtimeIdentity.siteCode")"
SOLACE_HOST="$(extract "solace.host")"
SOLACE_USERNAME="$(extract "solace.username")"
SOLACE_PASSWORD="$(extract "solace.password")"
RESPONSE_API_URL="$(extract "apiUrl")"

# Usar apiUrl da resposta se disponível
[[ -n "$RESPONSE_API_URL" ]] && API_URL="${RESPONSE_API_URL%/}"

if [[ -z "$TENANT_ID" ]] || [[ -z "$ASSET_ID" ]]; then
  echo "[erro] Resposta inválida da API. Token pode estar expirado." >&2
  echo "$RESPONSE" | head -c 500
  exit 1
fi

# Validar bundle na API
echo "[install] A validar bundle..."
if command -v jq >/dev/null 2>&1; then
  VALIDATE_PAYLOAD="$(jq -cn \
    --arg token "$TOKEN" \
    --arg tenantId "$TENANT_ID" \
    --arg assetId "$ASSET_ID" \
    --arg siteCode "${SITE_CODE:-}" \
    --arg issuedAt "$ISSUED_AT" \
    --arg expiresAt "$EXPIRES_AT" \
    --arg nonce "$NONCE" \
    --arg signature "$SIGNATURE" \
    --arg hostname "${HOSTNAME_SHORT}" \
    --arg ipAddress "${HOST_IP}" \
    '{
      assessmentToken: $token,
      bundle: {
        tenantId: $tenantId,
        assetId: $assetId,
        siteCode: $siteCode,
        issuedAtUtc: $issuedAt,
        expiresAtUtc: $expiresAt,
        nonce: $nonce,
        signatureVersion: "hmac-sha256-v1",
        signature: $signature
      },
      hostname: $hostname,
      ipAddress: $ipAddress,
      assetName: $hostname,
      assetType: "server",
      instanceLabel: $hostname
    }')"
elif command -v python3 >/dev/null 2>&1; then
  VALIDATE_PAYLOAD="$(python3 - <<PY
import json
payload = {
  "assessmentToken": "$TOKEN",
  "bundle": {
    "tenantId": "$TENANT_ID",
    "assetId": "$ASSET_ID",
    "siteCode": "${SITE_CODE:-}",
    "issuedAtUtc": "$ISSUED_AT",
    "expiresAtUtc": "$EXPIRES_AT",
    "nonce": "$NONCE",
    "signatureVersion": "hmac-sha256-v1",
    "signature": "$SIGNATURE"
  },
  "hostname": "${HOSTNAME_SHORT}",
  "ipAddress": "${HOST_IP}",
  "assetName": "${HOSTNAME_SHORT}",
  "assetType": "server",
  "instanceLabel": "${HOSTNAME_SHORT}"
}
print(json.dumps(payload))
PY
)"
else
  echo "[erro] jq ou python3 é obrigatório para gerar payload JSON de validação." >&2
  exit 1
fi
curl -fsS -X POST "${API_URL}/api/assessment/runtime/validate-bundle" \
  -H "Content-Type: application/json" \
  -d "$VALIDATE_PAYLOAD" >/dev/null || { echo "[erro] Validação do bundle falhou." >&2; exit 1; }

# Solace: pedir se a Central não devolveu (ou definir SOLACE_HOST via env)
if [[ -z "$SOLACE_HOST" ]]; then
  echo -n "Solace host (IP/hostname da Cloud): "
  read -r SOLACE_HOST
  [[ -z "$SOLACE_HOST" ]] && { echo "[erro] Solace host obrigatório." >&2; exit 1; }
fi
SOLACE_USERNAME="${SOLACE_USERNAME:-default}"
SOLACE_PASSWORD="${SOLACE_PASSWORD:-}"

if [[ -z "$SOLACE_PASSWORD" ]]; then
  echo -n "Solace password: "
  read -rs SOLACE_PASSWORD
  echo
fi

# Docker
if ! command -v docker &>/dev/null; then
  echo "[install] Docker não encontrado. A instalar..."
  if [[ -f /etc/debian_version ]]; then
    sudo apt-get update -y
    sudo apt-get install -y ca-certificates curl gnupg
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release 2>/dev/null && echo $VERSION_CODENAME || echo jammy) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo usermod -aG docker "$USER" 2>/dev/null || true
    echo "[install] Docker instalado."
    echo "[install] 1) Faça 'exit' nesta sessão SSH."
    echo "[install] 2) Volte a entrar na VM por SSH."
    echo "[install] 3) Execute o mesmo comando novamente (o script continuará a partir daqui)."
    exit 0
  else
    echo "[erro] Instalação automática só em Debian/Ubuntu." >&2
    exit 1
  fi
fi

# Compose
if [[ ! -f "$COMPOSE_DIR/docker-compose.yml" ]]; then
  echo "[erro] docker-compose.yml não encontrado em $COMPOSE_DIR" >&2
  echo "Obtenha o bundle client (compose, scripts, automation) em $OMS_CLIENT_DIR" >&2
  exit 1
fi

# Telegraf
if [[ ! -f "$COMPOSE_DIR/telegraf/telegraf.conf" ]] && [[ -f "$COMPOSE_DIR/telegraf.conf" ]]; then
  mkdir -p "$COMPOSE_DIR/telegraf"
  cp "$COMPOSE_DIR/telegraf.conf" "$COMPOSE_DIR/telegraf/telegraf.conf"
fi

# Network e volume
docker network create oms-shared-network 2>/dev/null || true
docker volume create compose_influxdb-local-data 2>/dev/null || true

# LOKI_URL: derivada do URL da Cloud/Central — o cliente NÃO fornece; Promtail envia logs por aqui.
# (Só se vier em env é que usamos; caso contrário derivamos do API_URL/SOLACE_HOST.)
if [[ -n "${LOKI_URL:-}" ]]; then
  : # já definido (env)
elif echo "$API_URL" | grep -qE ":${API_PROXY_PORT}/?$"; then
  LOKI_URL="${API_URL%/}/loki/api/v1/push"
else
  API_HOST="$(echo "$API_URL" | sed -E 's|https?://([^:/]+).*|\1|')"
  if [[ -n "$SOLACE_HOST" ]] && [[ "$API_HOST" == "$SOLACE_HOST" ]]; then
    LOKI_URL="http://${SOLACE_HOST}:${API_PROXY_PORT}/loki/api/v1/push"
  else
    LOKI_URL="http://${API_HOST}:${LOKI_PORT}/loki/api/v1/push"
  fi
fi
# Garantir que nunca fica vazia (fallback pelo mesmo host do API_URL)
if [[ -z "${LOKI_URL:-}" ]]; then
  API_HOST="$(echo "$API_URL" | sed -E 's|https?://([^:/]+).*|\1|')"
  LOKI_URL="http://${API_HOST}:${API_PROXY_PORT}/loki/api/v1/push"
fi

# .env
mkdir -p "$(dirname "$COMPOSE_DIR/.env")"
cat > "$COMPOSE_DIR/.env" <<EOF
TENANT_ID=$TENANT_ID
ASSET_ID=$ASSET_ID
LOKI_URL=$LOKI_URL
SOLACE__HOST=$SOLACE_HOST
SOLACE__PORT=$SOLACE_PORT
SOLACE__VPN=$SOLACE_VPN
SOLACE__USERNAME=$SOLACE_USERNAME
SOLACE__PASSWORD=$SOLACE_PASSWORD
ASPNETCORE_ENVIRONMENT=Production
CLIENT_IMAGE_REGISTRY=$CLIENT_IMAGE_REGISTRY
OMS_IMAGE_TAG=$OMS_IMAGE_TAG
EOF

echo "[install] A arrancar stack..."
cd "$(dirname "$COMPOSE_DIR")"
docker compose -f "$(basename "$COMPOSE_DIR")/docker-compose.yml" --env-file "$COMPOSE_DIR/.env" up -d --remove-orphans

echo "[install] Concluído."
echo "[install] Assessment: http://$(hostname -I 2>/dev/null | awk '{print $1}'):3002"
echo "[install] Tenant: $TENANT_ID | Asset: $ASSET_ID"
