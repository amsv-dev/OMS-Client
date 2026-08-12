#!/usr/bin/env bash
# Preparar VM remota (bases de dados) para modo distributed-logical-hosts.
# Autenticação SSH exclusiva por chave PEM (sem password).
#
# Uso recomendado (interactivo, gera par de chaves):
#   curl -fsSLO https://raw.githubusercontent.com/amsv-dev/OMS-Client/main/scripts/bootstrap-logical-host.sh
#   sudo bash bootstrap-logical-host.sh --generate-keypair
#
# Uso com chave pública existente:
#   sudo bash bootstrap-logical-host.sh --authorized-key-file /path/to/key.pub
#
set -euo pipefail

SERVICE_USER="${SERVICE_USER:-oms-telegraf}"
CONFIG_DIR="${CONFIG_DIR:-/opt/oms/telegraf}"
KEY_DIR="${KEY_DIR:-/etc/oms/bootstrap-keys}"
GENERATE_KEYPAIR=0
AUTHORIZED_KEY=""
AUTHORIZED_KEY_FILE=""
NON_INTERACTIVE=0

say() { printf '[bootstrap-logical-host] %s\n' "$*"; }
fail() { printf '[bootstrap-logical-host][erro] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Preparar host lógico Linux para OMS (SSH + PEM + Telegraf nativo).
Instala o pacote telegraf se ainda não existir (apt/dnf/yum). Não exige Docker.

Opções:
  --service-user NAME       Utilizador de serviço (default: oms-telegraf)
  --config-dir PATH         Pasta de config Telegraf (default: /opt/oms/telegraf)
  --generate-keypair        Gera par ed25519 e imprime chave privada para o Oramix Console
  --authorized-key TEXT     Linha authorized_keys (ssh-ed25519 AAAA... user@host)
  --authorized-key-file PATH  Ficheiro .pub com a chave pública
  --non-interactive         Sem menus (exige --generate-keypair ou --authorized-key*)
  -h, --help                Ajuda

Exemplos:
  sudo bash bootstrap-logical-host.sh --generate-keypair
  sudo bash bootstrap-logical-host.sh --authorized-key-file ./oms-lab.pub
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service-user) SERVICE_USER="$2"; shift 2 ;;
    --config-dir) CONFIG_DIR="$2"; shift 2 ;;
    --generate-keypair) GENERATE_KEYPAIR=1; shift ;;
    --authorized-key) AUTHORIZED_KEY="$2"; shift 2 ;;
    --authorized-key-file) AUTHORIZED_KEY_FILE="$2"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Opção desconhecida: $1 (use --help)" ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  fail "Execute com sudo nesta VM remota."
fi

ensure_telegraf() {
  if command -v telegraf >/dev/null 2>&1 || [[ -x /usr/bin/telegraf ]]; then
    say "Telegraf nativo já disponível."
    return 0
  fi

  say "A instalar Telegraf nativo (serviço no host — sem Docker)…"
  export DEBIAN_FRONTEND=noninteractive

  if command -v apt-get >/dev/null 2>&1; then
    if ! timeout 90 apt-get update -qq; then
      say "AVISO: apt-get update falhou/timeout. Sem Internet/proxy, instale telegraf offline e volte a correr este script."
      return 1
    fi
    timeout 240 apt-get install -y -qq telegraf || true
  elif command -v dnf >/dev/null 2>&1; then
    timeout 240 dnf install -y telegraf 2>/dev/null || true
  elif command -v yum >/dev/null 2>&1; then
    timeout 240 yum install -y telegraf 2>/dev/null || true
  fi

  if command -v telegraf >/dev/null 2>&1 || [[ -x /usr/bin/telegraf ]]; then
    say "Telegraf nativo instalado."
    return 0
  fi

  say "AVISO: Telegraf não ficou instalado. O acesso SSH pode ser registado na mesma; instale o pacote telegraf e volte a Validar no Console."
  return 1
}

ensure_telegraf || true

# --- Utilizador e permissões ---
id "$SERVICE_USER" &>/dev/null || useradd --system --create-home --shell /bin/bash "$SERVICE_USER"
mkdir -p "$CONFIG_DIR" "$KEY_DIR" /opt/oms
chown -R "$SERVICE_USER:$SERVICE_USER" /opt/oms
chown -R "$SERVICE_USER:$SERVICE_USER" "$CONFIG_DIR"

HOME_DIR="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
SSH_DIR="$HOME_DIR/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
touch "$SSH_DIR/authorized_keys"
chmod 600 "$SSH_DIR/authorized_keys"
chown -R "$SERVICE_USER:$SERVICE_USER" "$SSH_DIR"

install_authorized_key() {
  local line="$1"
  [[ -z "$line" ]] && return 0
  if grep -qxF "$line" "$SSH_DIR/authorized_keys" 2>/dev/null; then
    say "Chave pública já presente em authorized_keys."
  else
    echo "$line" >> "$SSH_DIR/authorized_keys"
    say "Chave pública adicionada a $SSH_DIR/authorized_keys"
  fi
}

print_private_key_banner() {
  local priv="$1"
  say ""
  say "======== COLE ESTA CHAVE PRIVADA NO ASSESSMENT (passo Acesso à máquina) ========"
  cat "$priv"
  say "======== FIM DA CHAVE PRIVADA — guarde em local seguro e apague deste terminal ========"
  say ""
}

generate_keypair() {
  local priv="$KEY_DIR/${SERVICE_USER}-oms-bootstrap"
  local pub="${priv}.pub"
  if [[ -f "$priv" && -f "$pub" ]]; then
    say "Par de chaves já existe em $KEY_DIR (reutilizar)."
  else
    ssh-keygen -t ed25519 -f "$priv" -N "" -C "oms-bootstrap-${SERVICE_USER}@$(hostname -s 2>/dev/null || echo host)"
    chmod 600 "$priv"
    chmod 644 "$pub"
  fi
  install_authorized_key "$(cat "$pub")"
  print_private_key_banner "$priv"
}

resolve_auth_mode() {
  if [[ "$GENERATE_KEYPAIR" -eq 1 ]]; then
    generate_keypair
    return
  fi
  if [[ -n "$AUTHORIZED_KEY" ]]; then
    install_authorized_key "$AUTHORIZED_KEY"
    say "Chave pública configurada. Use a chave privada correspondente no Oramix Console."
    return
  fi
  if [[ -n "$AUTHORIZED_KEY_FILE" ]]; then
    [[ -f "$AUTHORIZED_KEY_FILE" ]] || fail "Ficheiro não encontrado: $AUTHORIZED_KEY_FILE"
    install_authorized_key "$(cat "$AUTHORIZED_KEY_FILE")"
    say "Chave pública de $AUTHORIZED_KEY_FILE configurada."
    return
  fi

  if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    fail "Modo não-interactivo: use --generate-keypair ou --authorized-key / --authorized-key-file"
  fi

  # Interactivo via /dev/tty (funciona mesmo com curl | sudo bash)
  local choice=""
  if [[ -r /dev/tty ]]; then
    say "Como configurar autenticação SSH para $SERVICE_USER?"
    say "  1) Gerar novo par de chaves (recomendado) — imprime PEM para colar no Oramix Console"
    say "  2) Fornecer ficheiro de chave pública (.pub)"
    say "  3) Colar linha authorized_keys"
    printf "Escolha [1]: " >/dev/tty
    read -r choice </dev/tty || choice="1"
  else
    choice="1"
    say "Sem TTY: a gerar par de chaves por omissão."
  fi

  case "${choice:-1}" in
    1) generate_keypair ;;
    2)
      local path=""
      printf "Caminho para ficheiro .pub: " >/dev/tty
      read -r path </dev/tty
      [[ -f "$path" ]] || fail "Ficheiro não encontrado: $path"
      install_authorized_key "$(cat "$path")"
      say "Chave pública configurada."
      ;;
    3)
      local line=""
      say "Cole a linha authorized_keys e prima Enter, depois Ctrl+D:"
      line="$(cat </dev/tty)"
      install_authorized_key "$line"
      ;;
    *) fail "Opção inválida." ;;
  esac
}

resolve_auth_mode

# --- Sudo NOPASSWD para remediação OMS (systemctl + unit oms-telegraf) ---
SUDOERS_FILE="/etc/sudoers.d/oms-${SERVICE_USER}-remediation"
# shellcheck disable=SC2086
printf '%s\n' \
  "# OMS remediation (systemctl + unit file)" \
  "${SERVICE_USER} ALL=(root) NOPASSWD: /bin/systemctl, /usr/bin/systemctl, /sbin/reboot, /usr/sbin/reboot, /sbin/shutdown, /usr/sbin/shutdown, /usr/bin/tee /etc/systemd/system/oms-telegraf.service, /bin/tee /etc/systemd/system/oms-telegraf.service" \
  > "$SUDOERS_FILE"
chmod 440 "$SUDOERS_FILE"
if ! visudo -cf "$SUDOERS_FILE" >/dev/null 2>&1; then
  rm -f "$SUDOERS_FILE"
  fail "sudoers inválido — não foi possível configurar NOPASSWD para $SERVICE_USER."
fi
say "OK: sudo NOPASSWD de remediação em $SUDOERS_FILE"

# Validação rápida
if command -v telegraf >/dev/null 2>&1 || [[ -x /usr/bin/telegraf ]]; then
  say "OK: binário telegraf presente."
else
  say "AVISO: telegraf ainda em falta — o Console pode registar o acesso SSH; instale o pacote e volte a Validar."
fi
if sudo -u "$SERVICE_USER" test -w "$CONFIG_DIR" 2>/dev/null; then
  say "OK: $SERVICE_USER pode escrever em $CONFIG_DIR."
else
  fail "$SERVICE_USER não consegue escrever em $CONFIG_DIR."
fi
if sudo -u "$SERVICE_USER" sudo -n /usr/bin/systemctl --version >/dev/null 2>&1 \
  || sudo -u "$SERVICE_USER" sudo -n /bin/systemctl --version >/dev/null 2>&1; then
  say "OK: $SERVICE_USER pode usar systemctl com sudo -n (remediação)."
else
  say "AVISO: $SERVICE_USER ainda não passa «sudo -n systemctl» — verifique $SUDOERS_FILE."
fi

say "Concluído. No Oramix Console use utilizador «$SERVICE_USER», porta SSH 22 e a chave PEM privada."
say "O CustomerAgent aplica a config e o serviço oms-telegraf (Telegraf nativo — sem Docker)."
