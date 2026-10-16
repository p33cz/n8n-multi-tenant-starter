#!/usr/bin/env bash
# deploy-ops.sh — packages the ops layer into a permanently running
# container claude-code-n8n-mts (docker.sock, remote-control, an
# @reboot safety net).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh"
require_root
ensure_dirs

MSG_CS[deploy_ops.building_ops]='Buildím n8n-mts/ops-claude:latest'
MSG_EN[deploy_ops.building_ops]='Building n8n-mts/ops-claude:latest'
MSG_CS[deploy_ops.starting]='Spouštím ops-claude (claude-code-n8n-mts)'
MSG_EN[deploy_ops.starting]='Starting ops-claude (claude-code-n8n-mts)'
MSG_CS[deploy_ops.running]='Ops kontejner běží: docker exec -it claude-code-n8n-mts bash'
MSG_EN[deploy_ops.running]='Ops container is running: docker exec -it claude-code-n8n-mts bash'

# claude-agent image (the base) + ops-claude
ensure_image "n8n-mts/claude-agent" "$ROOT/docker/claude-agent"
say "$(msg deploy_ops.building_ops)"
docker build -t n8n-mts/ops-claude:latest "$ROOT/docker/ops-claude" >/dev/null

say "$(msg deploy_ops.starting)"
( cd "$ROOT/ops" && docker compose --env-file "$ROOT/.env" up -d ops-claude >/dev/null )

# host @reboot safety net (in case the restart policy fails)
CRLINE="@reboot root cd $ROOT/ops && docker compose --env-file $ROOT/.env up -d >/dev/null 2>&1"
echo "$CRLINE" > /etc/cron.d/n8n-mts-ops
chmod 0644 /etc/cron.d/n8n-mts-ops

ok "$(msg deploy_ops.running)"
docker ps --filter name=claude-code-n8n-mts --format '  {{.Names}}  {{.Status}}'
