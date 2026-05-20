#!/bin/sh
# Re-imprime o banner de primeiro arranque (caso o cliente o tenha perdido nos logs).
# Usage: docker exec oms-vault /vault/scripts/print-recovery-banner.sh
set -eu

INSTRUCTIONS_FILE="/vault/logs/FIRST-BOOT-INSTRUCTIONS.txt"
RECOVERY_FILE="/vault/secrets/recovery-keys-FIRST-BOOT-ONLY.json"

if [ -f "$INSTRUCTIONS_FILE" ]; then
  cat "$INSTRUCTIONS_FILE"
else
  echo "[print-recovery-banner] Sem instrucoes guardadas. O Vault ja foi inicializado antes desta versao do script."
fi

if [ -f "$RECOVERY_FILE" ]; then
  echo ""
  echo "ATENCAO: o ficheiro recovery-keys-FIRST-BOOT-ONLY.json ainda existe em:"
  echo "  $RECOVERY_FILE"
  echo "Copia-o para um cofre offline e apaga-o do disco quando confirmares."
else
  echo ""
  echo "OK: recovery-keys-FIRST-BOOT-ONLY.json ja foi removido (esperado apos o backup)."
fi
