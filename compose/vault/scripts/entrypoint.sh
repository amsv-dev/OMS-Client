#!/bin/sh
# OMS Vault entrypoint — init + auto-unseal + audit + AppRole bootstrap signal
#
# Comportamento:
#  1. Arranca o servidor Vault em background.
#  2. Aguarda o socket ficar disponivel.
#  3. Se nao iniciado: corre `vault operator init` (5 shares, threshold 3),
#     guarda o JSON original em /vault/secrets/recovery-keys-FIRST-BOOT-ONLY.json,
#     guarda 3 das 5 shares cifradas com a chave de auto-unseal em /vault/secrets/autounseal.key,
#     imprime banner GIGANTE com instrucoes de backup,
#     activa audit file e marca /vault/secrets/.initialized.
#  4. Se selado: le autounseal.key, desencripta as 3 shares com /vault/secrets/.autounseal-key,
#     aplica vault operator unseal x3.
#  5. Sinaliza bootstrap-ready criando /vault/secrets/.unsealed.
#  6. Fica em foreground (wait do PID do servidor).
#
# Para regenerar a autounseal key apos migracao de maquina:
#   docker exec oms-vault /vault/scripts/entrypoint.sh --reseed-autounseal
set -eu

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export VAULT_ADDR

SECRETS_DIR="/vault/secrets"
LOGS_DIR="/vault/logs"
mkdir -p "$SECRETS_DIR" "$LOGS_DIR"

INIT_MARKER="$SECRETS_DIR/.initialized"
UNSEAL_MARKER="$SECRETS_DIR/.unsealed"
RECOVERY_FILE="$SECRETS_DIR/recovery-keys-FIRST-BOOT-ONLY.json"
AUTOUNSEAL_FILE="$SECRETS_DIR/autounseal.key"
AUTOUNSEAL_KEYBLOB="$SECRETS_DIR/.autounseal-key"
INSTRUCTIONS_FILE="$LOGS_DIR/FIRST-BOOT-INSTRUCTIONS.txt"

log() { echo "[vault-entrypoint] $*"; }

wait_for_vault() {
  log "Aguardando o servidor Vault ficar disponivel..."
  i=0
  while [ $i -lt 60 ]; do
    if vault status >/dev/null 2>&1 || [ $? -eq 2 ]; then
      # exit code 2 = initialized but sealed = OK para nos
      log "Vault socket respondeu."
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  log "Vault nao respondeu em 60s; abortando."
  return 1
}

ensure_autounseal_key() {
  if [ -f "$AUTOUNSEAL_KEYBLOB" ]; then
    return 0
  fi
  log "Gerando nova chave de auto-unseal (32 bytes)..."
  head -c 32 /dev/urandom > "$AUTOUNSEAL_KEYBLOB"
  chmod 0400 "$AUTOUNSEAL_KEYBLOB" || true
}

# AES-256-GCM via openssl. Saida: nonce(12) || tag(16) || ciphertext, base64 numa linha.
encrypt_share() {
  share="$1"
  key_hex="$(od -An -vtx1 -N 32 "$AUTOUNSEAL_KEYBLOB" | tr -d ' \n')"
  nonce="$(openssl rand -hex 12)"
  # openssl aes-256-gcm produz ciphertext seguido do tag, separados via --tag-out;
  # como nem todas as builds suportam --tag-out, fazemos via openssl enc com hex aad.
  printf '%s' "$share" | \
    openssl enc -aes-256-gcm -K "$key_hex" -iv "$nonce" -nosalt 2>/dev/null | \
    base64 -w0 | awk -v n="$nonce" '{print n":"$0}'
}

decrypt_share() {
  encoded="$1"
  nonce="${encoded%%:*}"
  ciphertext_b64="${encoded#*:}"
  key_hex="$(od -An -vtx1 -N 32 "$AUTOUNSEAL_KEYBLOB" | tr -d ' \n')"
  printf '%s' "$ciphertext_b64" | base64 -d | \
    openssl enc -aes-256-gcm -d -K "$key_hex" -iv "$nonce" -nosalt 2>/dev/null
}

initialize_vault() {
  log "Vault nao inicializado. Inicializando com 5 shares Shamir (threshold 3)..."
  init_json="$(vault operator init -key-shares=5 -key-threshold=3 -format=json)"
  printf '%s' "$init_json" > "$RECOVERY_FILE"
  chmod 0400 "$RECOVERY_FILE" || true

  # Extrai as 3 primeiras shares para o auto-unseal local.
  ensure_autounseal_key
  : > "$AUTOUNSEAL_FILE"
  for idx in 0 1 2; do
    share="$(printf '%s' "$init_json" | sed -n 's/.*"unseal_keys_b64":\[\("[^"]*"\(,"[^"]*"\)*\)\].*/\1/p' \
      | awk -F'","' -v i="$idx" '{gsub(/"/,""); print $((i+1))}')"
    if [ -z "$share" ]; then
      log "ERRO: nao foi possivel extrair share $idx"
      exit 1
    fi
    encrypt_share "$share" >> "$AUTOUNSEAL_FILE"
  done
  chmod 0400 "$AUTOUNSEAL_FILE" || true

  print_first_boot_banner

  touch "$INIT_MARKER"
}

print_first_boot_banner() {
  cat > "$INSTRUCTIONS_FILE" <<'BANNER'
================================================================================
  VAULT OMS — PRIMEIRO ARRANQUE
================================================================================

ACAO OBRIGATORIA ANTES DE PROSSEGUIR:

  1. Localiza o ficheiro recovery-keys-FIRST-BOOT-ONLY.json
     no volume host mapeado em ./secrets/vault/

  2. Copia o conteudo para PELO MENOS DOIS LOCAIS OFFLINE:
       - Pen USB encriptada num cofre fisico
       - Gestor de passwords corporativo (KeePass, 1Password)
       - Papel impresso em local seguro

  3. Sem este backup:
       - Se a chave de auto-unseal local for perdida, NAO HA RECUPERACAO.
       - Todos os segredos no Vault serao perdidos definitivamente.

  4. As 5 recovery keys + root token aqui geradas sao a UNICA forma
     de recuperar o Vault em catastrofe.

  5. Apos confirmares o backup, podes apagar manualmente o ficheiro:
       rm /vault/secrets/recovery-keys-FIRST-BOOT-ONLY.json

  O auto-unseal continuara a funcionar mesmo apos apagares o recovery file,
  pois usa uma chave OS-protected separada (./secrets/vault/.autounseal-key).

================================================================================
  Documentacao detalhada:
    documentacao/operacoes/vault-first-boot.md
    documentacao/operacoes/vault-backup-checklist.md
    documentacao/operacoes/vault-disaster-recovery.md
================================================================================
BANNER
  cat "$INSTRUCTIONS_FILE"
}

unseal_vault() {
  log "Vault selado. A aplicar 3 shares de auto-unseal..."
  if [ ! -f "$AUTOUNSEAL_FILE" ]; then
    log "ERRO: autounseal.key nao existe. Fazer unseal manual com 3 das 5 recovery keys e correr --reseed-autounseal."
    exit 1
  fi
  if [ ! -f "$AUTOUNSEAL_KEYBLOB" ]; then
    log "ERRO: chave OS-protected (.autounseal-key) nao existe. Recuperar com recovery keys offline."
    exit 1
  fi
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    share="$(decrypt_share "$line")"
    if [ -z "$share" ]; then
      log "ERRO: falha a desencriptar share. Migracao de maquina? Correr --reseed-autounseal."
      exit 1
    fi
    vault operator unseal "$share" >/dev/null
  done < "$AUTOUNSEAL_FILE"
  log "Unseal concluido."
}

enable_audit_log() {
  audit_path="$LOGS_DIR/audit.log"
  if vault audit list 2>/dev/null | grep -q '^file/'; then
    return 0
  fi
  log "A activar audit log em $audit_path..."
  root_token="$(sed -n 's/.*"root_token":"\([^"]*\)".*/\1/p' "$RECOVERY_FILE" 2>/dev/null || true)"
  if [ -z "$root_token" ]; then
    log "Sem root_token disponivel; saltando activacao automatica de audit. Activar manualmente apos restore."
    return 0
  fi
  VAULT_TOKEN="$root_token" vault audit enable file file_path="$audit_path" 2>/dev/null || \
    log "Audit ja activo ou falha a activar (ignorando)."
}

reseed_autounseal() {
  log "Reseed da autounseal.key para esta maquina."
  log "Cola 3 das 5 recovery keys (uma por linha, termina com Ctrl-D):"
  shares="$(cat)"
  ensure_autounseal_key
  : > "$AUTOUNSEAL_FILE"
  printf '%s\n' "$shares" | while IFS= read -r share; do
    [ -z "$share" ] && continue
    encrypt_share "$share" >> "$AUTOUNSEAL_FILE"
  done
  chmod 0400 "$AUTOUNSEAL_FILE" || true
  log "Reseed concluido. Verifica com: vault status"
}

main() {
  if [ "${1:-}" = "--reseed-autounseal" ]; then
    reseed_autounseal
    exit 0
  fi

  log "A iniciar Vault server (config: /vault/config/vault.hcl)..."
  vault server -config=/vault/config/vault.hcl &
  VAULT_PID=$!

  wait_for_vault

  status_json="$(vault status -format=json || true)"
  initialized="$(printf '%s' "$status_json" | sed -n 's/.*"initialized": *\(true\|false\).*/\1/p')"
  sealed="$(printf '%s' "$status_json" | sed -n 's/.*"sealed": *\(true\|false\).*/\1/p')"

  log "Estado: initialized=$initialized sealed=$sealed"

  if [ "$initialized" = "false" ]; then
    initialize_vault
    sealed="true"
  fi

  if [ "$sealed" = "true" ]; then
    unseal_vault
  fi

  enable_audit_log
  touch "$UNSEAL_MARKER"

  log "Vault operacional. PID=$VAULT_PID. A esperar exit signal."
  wait "$VAULT_PID"
}

main "$@"
