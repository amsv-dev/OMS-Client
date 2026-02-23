#!/usr/bin/env bash
# OMS Client — Instalação inicial (VM virgem)
# Executar ANTES do Assessment. Depois de obter o bundle no Assessment, correr bootstrap-runtime.sh
set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-}"
SOLACE_HOST="${SOLACE_HOST:-}"
OMS_CLIENT_DIR="${OMS_CLIENT_DIR:-$HOME/oms-client}"

usage() {
  cat <<'EOF'
OMS Client — Instalação inicial (VM virgem)

Uso:
  bash client/scripts/install-client.sh [opções]

Opções:
  --compose-dir DIR     Diretório do compose (default: $OMS_CLIENT_DIR/compose)
  --solace-host IP       IP do Solace/Cloud (obrigatório para arrancar)
  --oms-client-dir DIR   Raiz do projeto client (default: ~/oms-client)
  -h, --help             Mostrar esta ajuda

Fluxo:
  1) Obter o bundle client (Azure Artifacts, clone, ou scp) em ~/oms-client
  2) Executar este script: bash install-client.sh --solace-host <IP_CLOUD>
  3) Abrir Assessment em http://<IP_ESTA_VM>:3002
  4) Validar token, obter bundle, submeter assets
  5) Executar bootstrap-runtime.sh com o bundle
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compose-dir) COMPOSE_DIR="$2"; shift 2 ;;
    --solace-host) SOLACE_HOST="$2"; shift 2 ;;
    --oms-client-dir) OMS_CLIENT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[install][erro] Argumento desconhecido: $1" >&2; usage; exit 1 ;;
  esac
done

COMPOSE_DIR="${COMPOSE_DIR:-$OMS_CLIENT_DIR/compose}"

echo "[install] OMS Client — Instalação inicial"
echo "[install] Compose dir: $COMPOSE_DIR"

# 1. Verificar/instalar Docker
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
    echo "[install] Docker instalado. Faça logout e login para aplicar o grupo docker, depois execute novamente."
    exit 0
  else
    echo "[install][erro] Instalação automática de Docker só suportada em Debian/Ubuntu." >&2
    exit 1
  fi
fi

# 2. Verificar compose
if [[ ! -f "$COMPOSE_DIR/docker-compose.yml" ]]; then
  echo "[install][erro] docker-compose.yml não encontrado em $COMPOSE_DIR" >&2
  echo "[install] Obtenha o bundle client (compose, scripts, automation) e coloque em $OMS_CLIENT_DIR" >&2
  exit 1
fi

# 3. Telegraf config
if [[ ! -f "$COMPOSE_DIR/telegraf/telegraf.conf" ]]; then
  if [[ -f "$COMPOSE_DIR/telegraf.conf" ]]; then
    mkdir -p "$COMPOSE_DIR/telegraf"
    cp "$COMPOSE_DIR/telegraf.conf" "$COMPOSE_DIR/telegraf/telegraf.conf"
  else
    echo "[install][aviso] telegraf/telegraf.conf não encontrado; o telegraf pode falhar."
  fi
fi

# 4. Network e volume
docker network create oms-shared-network 2>/dev/null || true
docker volume create compose_influxdb-local-data 2>/dev/null || true

# 5. Arrancar com config mínima (para Assessment)
export TENANT_ID="${TENANT_ID:-unknown}"
export ASSET_ID="${ASSET_ID:-unknown}"
export SOLACE__HOST="${SOLACE_HOST:-192.168.56.30}"
export SOLACE__PORT="${SOLACE__PORT:-1883}"

if [[ -z "$SOLACE_HOST" ]] || [[ "$SOLACE_HOST" == "192.168.56.30" ]]; then
  echo "[install][aviso] SOLACE__HOST não definido. Use --solace-host <IP_CLOUD> para produção."
fi

echo "[install] A arrancar stack (config mínima para Assessment)..."
cd "$(dirname "$COMPOSE_DIR")"
docker compose -f "$(basename "$COMPOSE_DIR")/docker-compose.yml" up -d --remove-orphans

echo "[install] Concluído."
echo "[install] Abra o Assessment em: http://$(hostname -I 2>/dev/null | awk '{print $1}'):3002"
echo "[install] Após validar token e obter o bundle, execute:"
echo "  bash scripts/bootstrap-runtime.sh --api-url <URL_CENTRAL> --assessment-token <token> ..."
