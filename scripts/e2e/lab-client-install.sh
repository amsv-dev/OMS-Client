#!/usr/bin/env bash
set -euo pipefail
TOKEN="${1:?token required}"
CLOUD_API="${CLOUD_API:-http://10.69.105.41:8443}"
SITE_CODE="${SITE_CODE:-lab}"
REPO="${OMS_CLIENT_REPO:-https://github.com/amsv-dev/OMS-Client.git}"

git clone "$REPO" "$HOME/oms-client"
cd "$HOME/oms-client"
find scripts -name '*.sh' -exec sed -i 's/\r$//' {} \; 2>/dev/null || true
find scripts -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true
API_URL="$CLOUD_API" bash scripts/install-oms-client.sh "$TOKEN" --site-code "$SITE_CODE"
