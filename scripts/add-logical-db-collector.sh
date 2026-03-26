#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Configura um collector remoto para logical asset DB (telegraf-first).

Uso:
  bash client/scripts/add-logical-db-collector.sh \
    --service-type postgresql|mysql|sqlserver|oracle \
    --logical-asset-id "<logical-asset-id>" \
    --runtime-asset-id "<runtime-asset-id>" \
    --host "<db-host>" \
    --port <db-port> \
    --credential-reference "<credential-reference>" \
    [--database-name "<database>"] \
    [--service-name "<oracle-service-name>"]

Este script:
  - gera snippet em client/compose/telegraf/conf.d
  - garante placeholders no client/compose/secrets/logical-assets.env
  - não envia segredos para OMS Central
EOF
}

SERVICE_TYPE=""
LOGICAL_ASSET_ID=""
RUNTIME_ASSET_ID=""
DB_HOST=""
DB_PORT=""
CREDENTIAL_REFERENCE=""
DATABASE_NAME=""
SERVICE_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service-type) SERVICE_TYPE="$2"; shift 2 ;;
    --logical-asset-id) LOGICAL_ASSET_ID="$2"; shift 2 ;;
    --runtime-asset-id) RUNTIME_ASSET_ID="$2"; shift 2 ;;
    --host) DB_HOST="$2"; shift 2 ;;
    --port) DB_PORT="$2"; shift 2 ;;
    --credential-reference) CREDENTIAL_REFERENCE="$2"; shift 2 ;;
    --database-name) DATABASE_NAME="$2"; shift 2 ;;
    --service-name) SERVICE_NAME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[collector][erro] Argumento desconhecido: $1" >&2; usage; exit 1 ;;
  esac
done

for req in SERVICE_TYPE LOGICAL_ASSET_ID RUNTIME_ASSET_ID DB_HOST DB_PORT CREDENTIAL_REFERENCE; do
  if [[ -z "${!req:-}" ]]; then
    echo "[collector][erro] Parametro obrigatório em falta: ${req}" >&2
    usage
    exit 1
  fi
done

case "$SERVICE_TYPE" in
  postgresql|mysql|sqlserver|oracle) ;;
  *) echo "[collector][erro] service-type inválido: $SERVICE_TYPE" >&2; exit 1 ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONF_DIR="${ROOT_DIR}/client/compose/telegraf/conf.d"
SECRETS_FILE="${ROOT_DIR}/client/compose/secrets/logical-assets.env"

mkdir -p "$CONF_DIR"
mkdir -p "$(dirname "$SECRETS_FILE")"
touch "$SECRETS_FILE"

REF_KEY="$(echo "$CREDENTIAL_REFERENCE" | tr '[:lower:]' '[:upper:]' | sed -E 's/[^A-Z0-9]+/_/g')"
USER_VAR="OMS_CRED_${REF_KEY}_USER"
PASS_VAR="OMS_CRED_${REF_KEY}_PASS"
SSL_VAR="OMS_CRED_${REF_KEY}_CONNSSL"
TLS_VAR="OMS_CRED_${REF_KEY}_TLS"

ensure_secret_placeholder() {
  local key="$1"
  local default_value="$2"
  if ! grep -q "^${key}=" "$SECRETS_FILE"; then
    printf '%s=%s\n' "$key" "$default_value" >> "$SECRETS_FILE"
  fi
}

ensure_secret_placeholder "$USER_VAR" "change_me_user"
ensure_secret_placeholder "$PASS_VAR" "change_me_password"
ensure_secret_placeholder "$SSL_VAR" "prefer"
ensure_secret_placeholder "$TLS_VAR" "false"

SNIPPET_FILE="${CONF_DIR}/logical-${LOGICAL_ASSET_ID}.conf"
COMMON_TAGS=$(cat <<EOF
  logical_asset_id = "${LOGICAL_ASSET_ID}"
  runtime_asset_id = "${RUNTIME_ASSET_ID}"
  collector_type = "${SERVICE_TYPE}"
  origin_scope = "remote"
  service_type = "${SERVICE_TYPE}"
EOF
)

case "$SERVICE_TYPE" in
  postgresql)
    DB_NAME="${DATABASE_NAME:-postgres}"
    cat > "$SNIPPET_FILE" <<EOF
[[inputs.postgresql]]
  address = "host=${DB_HOST} port=${DB_PORT} user=\${${USER_VAR}} password=\${${PASS_VAR}} dbname=${DB_NAME} sslmode=\${${SSL_VAR}}"
  outputaddress = "host=${DB_HOST}:${DB_PORT}"
  database_type = "PostgreSQL"

  [inputs.postgresql.tags]
${COMMON_TAGS}
EOF
    ;;
  mysql)
    DB_NAME="${DATABASE_NAME:-mysql}"
    cat > "$SNIPPET_FILE" <<EOF
[[inputs.mysql]]
  servers = ["\${${USER_VAR}}:\${${PASS_VAR}}@tcp(${DB_HOST}:${DB_PORT})/${DB_NAME}?tls=\${${TLS_VAR}}"]

  [inputs.mysql.tags]
${COMMON_TAGS}
EOF
    ;;
  sqlserver)
    DB_NAME="${DATABASE_NAME:-master}"
    cat > "$SNIPPET_FILE" <<EOF
[[inputs.sqlserver]]
  servers = ["Server=${DB_HOST},${DB_PORT};User Id=\${${USER_VAR}};Password=\${${PASS_VAR}};Database=${DB_NAME};encrypt=disable;"]

  [inputs.sqlserver.tags]
${COMMON_TAGS}
EOF
    ;;
  oracle)
    ORACLE_TARGET="${SERVICE_NAME:-orcl}"
    cat > "$SNIPPET_FILE" <<EOF
[[inputs.exec]]
  commands = ["bash /opt/oms-client/collectors/oracle-metrics.sh --host ${DB_HOST} --port ${DB_PORT} --service-name ${ORACLE_TARGET} --user \${${USER_VAR}} --password \${${PASS_VAR}}"]
  timeout = "10s"
  data_format = "influx"
  name_override = "oracle"

  [inputs.exec.tags]
${COMMON_TAGS}
EOF
    ;;
esac

echo "[collector] Snippet criado: $SNIPPET_FILE"
echo "[collector] Atualiza os placeholders no ficheiro: $SECRETS_FILE"
echo "[collector] Reinicia o telegraf:"
echo "  docker compose -f client/compose/docker-compose.yml --env-file client/compose/.env up -d telegraf"
