#!/bin/bash
# Vault bootstrap manual — corre UMA UNICA VEZ por install.
#
# Operacao:
#   1. Confirma que Vault esta em execucao mas NAO inicializado.
#   2. Chama /local/vault/bootstrap no customer-agent (que vai:
#        - POST sys/init com 5 shares + threshold 3
#        - Cifrar 3 unseal keys com DPAPI/keyring + AES-GCM em autounseal.bin
#        - Guardar recovery-keys-FIRST-BOOT-ONLY.json com root_token + 5 keys
#        - Devolver paths + warning de backup).
#   3. Imprime banner GIGANTE com instrucoes para o operador.
#
# Apos isto, o agent unsela o Vault automaticamente em cada arranque.
# As 5 recovery keys devem ser backed up offline e o file FIRST-BOOT apagado.
#
# Uso:
#   bash client/scripts/vault-bootstrap.sh [--shares 5 --threshold 3]
#
# Variaveis (de .env ou exportadas):
#   COMPOSE_DIR              (default: client/compose)
#   CUSTOMER_AGENT_URL       (default: http://localhost:5808)
#   ASSESSMENT_TOKEN_FILE    (default: $COMPOSE_DIR/secrets/assessment-token.txt)

set -euo pipefail

SHARES=5
THRESHOLD=3
while [ $# -gt 0 ]; do
  case "$1" in
    --shares)    SHARES="$2"; shift 2 ;;
    --threshold) THRESHOLD="$2"; shift 2 ;;
    -h|--help)
      grep -E '^# ' "$0" | sed 's/^# //'
      exit 0 ;;
    *) echo "[vault-bootstrap] arg desconhecido: $1" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_DIR="${COMPOSE_DIR:-$ROOT/compose}"
TOKEN_FILE="${ASSESSMENT_TOKEN_FILE:-$COMPOSE_DIR/secrets/assessment-token.txt}"
AGENT_URL="${CUSTOMER_AGENT_URL:-http://localhost:5808}"

echo "[vault-bootstrap] verificando pre-requisitos..."

if ! command -v curl >/dev/null 2>&1; then
  echo "[vault-bootstrap] ERRO: curl em falta. Instale curl antes de continuar." >&2
  exit 1
fi

if [ ! -f "$TOKEN_FILE" ]; then
  echo "[vault-bootstrap] ERRO: token nao encontrado em $TOKEN_FILE" >&2
  echo "[vault-bootstrap] Crie um tenant na Central e cole o token no ficheiro." >&2
  exit 1
fi

TOKEN="$(tr -d '\r\n' < "$TOKEN_FILE")"
if [ -z "$TOKEN" ]; then
  echo "[vault-bootstrap] ERRO: token vazio em $TOKEN_FILE" >&2
  exit 1
fi

echo "[vault-bootstrap] chamando $AGENT_URL/local/vault/bootstrap..."
HTTP_CODE=$(curl -sS -o /tmp/vault-bootstrap-resp.json -w '%{http_code}' \
  -X POST \
  -H "X-Customer-Token: $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"keyShares\": $SHARES, \"keyThreshold\": $THRESHOLD}" \
  "$AGENT_URL/local/vault/bootstrap")

if [ "$HTTP_CODE" != "200" ]; then
  echo "[vault-bootstrap] ERRO HTTP $HTTP_CODE" >&2
  cat /tmp/vault-bootstrap-resp.json >&2 || true
  exit 1
fi

cat /tmp/vault-bootstrap-resp.json

echo ""
echo "================================================================================"
echo "  VAULT OMS — PRIMEIRO ARRANQUE CONCLUIDO"
echo "================================================================================"
echo ""
echo "  ACCAO OBRIGATORIA — backup das 5 recovery keys offline:"
echo "    1. Localize: $COMPOSE_DIR/secrets/vault/recovery-keys-FIRST-BOOT-ONLY.json"
echo "    2. Copie root_token + 5 unseal_keys_b64 para PELO MENOS DOIS locais offline:"
echo "         - Gestor de passwords corporativo (KeePass, 1Password)"
echo "         - Papel impresso em cofre fisico"
echo "         - Pen USB encriptada"
echo "    3. APOS confirmar o backup, apague o ficheiro:"
echo "         rm $COMPOSE_DIR/secrets/vault/recovery-keys-FIRST-BOOT-ONLY.json"
echo ""
echo "  O auto-unseal continuara a funcionar (usa autounseal.bin com chave OS-protected)."
echo "  As recovery keys SO sao necessarias em catastrofe:"
echo "    - Perda da maquina (DPAPI/keyring local irrecuperavel)"
echo "    - Restore num host diferente"
echo "    - Apagar accidental do autounseal.bin"
echo ""
echo "  Documentacao detalhada:"
echo "    documentacao/runbook/vault-operations.md"
echo "    documentacao/runbook/vault-disaster-recovery.md"
echo "================================================================================"

rm -f /tmp/vault-bootstrap-resp.json
