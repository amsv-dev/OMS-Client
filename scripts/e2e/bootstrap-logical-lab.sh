#!/usr/bin/env bash
# Bootstrap PEM na VM lógica do lab (correr em oms-logical, não no client).
set -euo pipefail
PASS="${SSH_PASS:-webweb123}"
sed -i 's/\r$//' ~/bootstrap-logical-host.sh 2>/dev/null || true
echo "$PASS" | sudo -S bash ~/bootstrap-logical-host.sh --generate-keypair --non-interactive
say() { printf '[bootstrap-logical-lab] %s\n' "$*"; }
say "Chave privada impressa acima — cole no Assessment (passo Acesso à máquina)."
say "Cópia só para E2E entre Linux: sudo cat /etc/oms/bootstrap-keys/oms-telegraf-oms-bootstrap"
ls -la /opt/oms/telegraf | head -5
