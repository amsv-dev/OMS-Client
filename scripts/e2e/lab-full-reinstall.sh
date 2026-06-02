#!/usr/bin/env bash
# Orquestração E2E lab: reset central, criar cliente, reset client VM, install, bootstrap lógico.
# Executar a partir de uma máquina com SSH oms-central / oms-client / oms-logical configurados.
set -euo pipefail

CLOUD_API="${CLOUD_API:-http://10.69.105.41:8443}"
CENTRAL_API="${CENTRAL_API:-http://127.0.0.1:5000}"
SITE_CODE="${SITE_CODE:-lab}"
SSH_PASS="${SSH_PASS:-webweb123}"
OMS_CLIENT_REPO="${OMS_CLIENT_REPO:-https://github.com/amsv-dev/OMS-Client.git}"

say() { printf '[lab-e2e] %s\n' "$*"; }

say "1/5 Reset Central (funcional + Grafana)..."
ssh oms-central "bash /opt/oms-central/scripts/maintenance/reset-central-functional-and-grafana.sh --yes"

say "2/5 Criar cliente distributed-logical-hosts..."
TOKEN=$(ssh oms-central "bash -s" <<'REMOTE'
set -euo pipefail
API_URL="${CENTRAL_API:-http://127.0.0.1:5000}"
ADMIN_TOKEN=$(curl -sfS -X POST "$API_URL/api/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}' | jq -r .token)
BODY=$(curl -sfS -X POST "$API_URL/api/customers" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"OMS Lab Probe E2E\",\"email\":\"lab-probe-$(date +%s)@lab.local\",\"observabilityMode\":\"distributed-logical-hosts\"}")
echo "$BODY" | jq -r .apiToken
REMOTE
)
[[ -n "$TOKEN" && "$TOKEN" != "null" ]] || { say "Falha ao obter token"; exit 1; }
say "Token obtido (${#TOKEN} chars)"

say "3/5 Reset total VM client..."
printf 'RESET\n' | ssh oms-client "bash -s" <<'REMOTE'
set -euo pipefail
OMS_DIR="$HOME/oms-client"
if [[ -f "$OMS_DIR/compose/docker-compose.yml" ]]; then
  cd "$OMS_DIR" && docker compose -f compose/docker-compose.yml --env-file compose/.env down --remove-orphans -v 2>/dev/null || true
fi
docker ps -a --format '{{.Names}}' | grep -E '^(client-|oms-vault)' | xargs -r docker rm -f 2>/dev/null || true
docker volume ls -q | grep -E '^compose_' | xargs -r docker volume rm -f 2>/dev/null || true
rm -rf "$OMS_DIR"
REMOTE

say "4/5 Instalar OMS Client (pull imagens latest)..."
ssh oms-client "bash -s" <<REMOTE
set -euo pipefail
git clone "$OMS_CLIENT_REPO" ~/oms-client
cd ~/oms-client
sed -i 's/\r$//' scripts/*.sh scripts/e2e/*.sh 2>/dev/null || true
chmod +x scripts/*.sh scripts/e2e/*.sh 2>/dev/null || true
API_URL="$CLOUD_API" bash scripts/install-oms-client.sh "$TOKEN" --site-code "$SITE_CODE"
REMOTE

say "5/5 Bootstrap VM lógica (.50)..."
scp -q "$(dirname "$0")/../bootstrap-logical-host.sh" oms-logical:~/bootstrap-logical-host.sh 2>/dev/null || \
  scp -q "$(dirname "$0")/../../scripts/bootstrap-logical-host.sh" oms-logical:~/bootstrap-logical-host.sh 2>/dev/null || \
  ssh oms-logical "curl -fsSL -o ~/bootstrap-logical-host.sh https://raw.githubusercontent.com/amsv-dev/OMS-Client/main/scripts/bootstrap-logical-host.sh" || true

ssh oms-logical "bash -s" <<REMOTE
set -euo pipefail
sed -i 's/\r$//' ~/bootstrap-logical-host.sh 2>/dev/null || true
echo "$SSH_PASS" | sudo -S bash ~/bootstrap-logical-host.sh --generate-keypair --non-interactive
REMOTE

say "Concluído. Próximo: Assessment http://10.69.105.43:3122/ — token de instalação acima."
say "TOKEN=$TOKEN"
