#!/usr/bin/env bash
# Preparar VM remota (bases de dados) para modo distributed-logical-hosts.
# Executar UMA VEZ com sudo na VM onde correm PostgreSQL/MySQL/etc.
# Depois use a conta oms-telegraf no Assessment (passo «Acesso à máquina»).
set -euo pipefail

SERVICE_USER="${SERVICE_USER:-oms-telegraf}"
CONFIG_DIR="${CONFIG_DIR:-/opt/oms/telegraf}"

if ! command -v docker >/dev/null 2>&1; then
  echo "[bootstrap-logical-host][erro] Docker não encontrado. Instale Docker antes de continuar." >&2
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "[bootstrap-logical-host][erro] Execute com sudo nesta VM remota." >&2
  exit 1
fi

id "$SERVICE_USER" &>/dev/null || useradd --system --create-home --shell /bin/bash "$SERVICE_USER"
mkdir -p "$CONFIG_DIR"
chown -R "$SERVICE_USER:$SERVICE_USER" /opt/oms
usermod -aG docker "$SERVICE_USER" 2>/dev/null || true

echo "[bootstrap-logical-host] OK: $SERVICE_USER pode escrever em $CONFIG_DIR e usar Docker."
echo "[bootstrap-logical-host] Defina password ou chave SSH para $SERVICE_USER e use essa conta no Assessment."
