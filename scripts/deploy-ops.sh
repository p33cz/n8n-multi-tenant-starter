#!/usr/bin/env bash
# deploy-ops.sh — zabalí ops vrstvu do trvale běžícího kontejneru
# claude-code-n8n-mts (docker.sock, remote-control, @reboot pojistka).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh"
require_root
ensure_dirs

# image claude-agent (základ) + ops-claude
docker image inspect n8n-mts/claude-agent:latest >/dev/null 2>&1 || {
  say "Buildím n8n-mts/claude-agent:latest"
  docker build -t n8n-mts/claude-agent:latest "$ROOT/docker/claude-agent" >/dev/null
}
say "Buildím n8n-mts/ops-claude:latest"
docker build -t n8n-mts/ops-claude:latest "$ROOT/docker/ops-claude" >/dev/null

say "Spouštím ops-claude (claude-code-n8n-mts)"
( cd "$ROOT/ops" && docker compose --env-file "$ROOT/.env" up -d ops-claude >/dev/null )

# host @reboot pojistka (kdyby restart policy selhala)
CRLINE="@reboot root cd $ROOT/ops && docker compose --env-file $ROOT/.env up -d >/dev/null 2>&1"
echo "$CRLINE" > /etc/cron.d/n8n-mts-ops
chmod 0644 /etc/cron.d/n8n-mts-ops

ok "Ops kontejner běží: docker exec -it claude-code-n8n-mts bash"
docker ps --filter name=claude-code-n8n-mts --format '  {{.Names}}  {{.Status}}'
