#!/bin/sh
# OMS Vault entrypoint (arquitectura definitiva).
#
# Responsabilidades minimas:
#   1. Arranca o servidor Vault em foreground.
#   2. Aguarda sinais de paragem (Docker, systemd).
#
# Tudo o resto e gerido pelo customer-agent:
#   - Auto-unseal: VaultUnsealService chama POST /v1/sys/unseal com chaves
#     descifradas com DPAPI/keyring + AES-GCM (Oms.CustomerAgent.Services.VaultAuth).
#   - Bootstrap inicial (operator init + AppRole): vault-bootstrap.sh chama o
#     endpoint /local/vault/bootstrap no agent (so funciona quando Vault nao
#     esta inicializado, idempotente).
#   - Audit logging: VaultBootstrap activa audit/file apos init.
#
# Esta separacao remove "remendos" antigos (base64 em shell, scripts a
# fazer crypto em sh, dependencias de openssl).
set -eu

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
export VAULT_ADDR

mkdir -p /vault/file /vault/logs

echo "[vault-entrypoint] Arquitectura definitiva: Vault apenas serve, auto-unseal e bootstrap geridos pelo customer-agent."
echo "[vault-entrypoint] A iniciar Vault server (config: /vault/config/vault.hcl)..."

exec vault server -config=/vault/config/vault.hcl
