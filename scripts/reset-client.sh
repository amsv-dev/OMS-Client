#!/usr/bin/env bash
# Reset do runtime OMS Client na VM.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$SCRIPT_DIR/e2e"

usage() {
  cat <<'EOF'
OMS Client — Reset

Uso:
  bash scripts/reset-client.sh [--runtime | --validate | --vm-nuke]

Modos:
  --runtime   (default) Apaga volumes Vault/Influx e secrets; sobe vault+agent.
  --validate  QA: reset + bootstrap Vault + credencial demo + reboot + asserts.
  --vm-nuke   Apaga ~/oms-client inteiro (interactivo; requer script maintenance no repo OMSv2).

Exemplos:
  bash scripts/reset-client.sh
  bash scripts/reset-client.sh --validate
EOF
}

MODE="runtime"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime) MODE="runtime"; shift ;;
    --validate) MODE="validate"; shift ;;
    --vm-nuke) MODE="vm-nuke"; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "[reset-client][erro] Argumento desconhecido: $1" >&2
      usage
      exit 2
      ;;
  esac
done

case "$MODE" in
  runtime)
    exec "$E2E_DIR/reset-runtime.sh"
    ;;
  validate)
    exec "$E2E_DIR/reset-and-validate-e2e.sh"
    ;;
  vm-nuke)
    MAINT=""
    for candidate in \
      "$SCRIPT_DIR/../../scripts/maintenance/reset-client-vm.sh" \
      "$SCRIPT_DIR/../../../scripts/maintenance/reset-client-vm.sh"; do
      if [[ -f "$candidate" ]]; then
        MAINT="$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
        break
      fi
    done
    if [[ -z "$MAINT" ]]; then
      echo "[reset-client][erro] reset-client-vm.sh nao encontrado." >&2
      echo "[reset-client] Em clone OMS-Client apenas, use reset manual ou clone OMSv2 completo." >&2
      exit 1
    fi
    exec bash "$MAINT"
    ;;
esac
