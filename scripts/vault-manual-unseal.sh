#!/bin/bash
# Desbloqueia Vault com as 3 primeiras recovery keys do ficheiro FIRST-BOOT.
set -euo pipefail
RECOVERY="${1:-/home/alexandrevicente/oms-client/compose/secrets/vault/recovery-keys-FIRST-BOOT-ONLY.json}"
for i in 0 1 2; do
  KEY=$(docker run --rm -v "$(dirname "$RECOVERY"):/v" alpine:3.20 sh -c "apk add -q jq >/dev/null 2>&1 && jq -r '.unseal_keys_b64[$i]' /v/$(basename "$RECOVERY")")
  echo "Unseal share $((i+1))..."
  docker exec oms-vault vault operator unseal "$KEY"
done
docker exec oms-vault vault status
