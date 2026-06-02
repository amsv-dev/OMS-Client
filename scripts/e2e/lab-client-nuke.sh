#!/usr/bin/env bash
set -euo pipefail
OMS_DIR="${OMS_DIR:-$HOME/oms-client}"
say() { printf '[nuke] %s\n' "$*"; }
if [[ -f "$OMS_DIR/compose/docker-compose.yml" ]]; then
  cd "$OMS_DIR" && docker compose -f compose/docker-compose.yml --env-file compose/.env down --remove-orphans -v 2>/dev/null || true
fi
docker ps -a --format '{{.Names}}' | grep -E '^(client-|oms-vault)' | xargs -r docker rm -f 2>/dev/null || true
docker volume ls -q | grep -E '^compose_' | xargs -r docker volume rm -f 2>/dev/null || true
if [[ -d "$OMS_DIR" ]]; then
  rm -rf "$OMS_DIR" 2>/dev/null || docker run --rm -v "$HOME:/w" alpine:3.20 rm -rf "/w/oms-client"
fi
[[ ! -d "$OMS_DIR" ]] && say "OK removed" || { say "FAIL still exists"; exit 1; }
