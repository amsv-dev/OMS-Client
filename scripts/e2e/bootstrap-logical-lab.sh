#!/usr/bin/env bash
set -euo pipefail
PASS="${SSH_PASS:-webweb123}"
sudo -S bash ~/bootstrap-logical-host.sh <<<"$PASS"
echo "oms-telegraf:$PASS" | sudo chpasswd
ls -la /opt/oms/telegraf | head -5
