#!/usr/bin/env bash
# entrypoint for the ops container claude-code-n8n-mts.
# Starts a screen session running `claude remote-control` (retry
# loop), adds an @reboot cron safety net, and keeps the container
# alive. Working directory = /workspace (mount of /opt/n8n-mts),
# server control via /var/run/docker.sock.
set -euo pipefail
export HOME=/root
mkdir -p "$HOME/.claude"

# Standalone entrypoint — no access to scripts/lib.sh inside the
# container, so it keeps its own tiny N8N_MTS_LANG switch (the value
# itself is passed in from the host via ops/docker-compose.yml).
N8N_MTS_LANG="${N8N_MTS_LANG:-cs}"
log() {
  local cs="$1" en="$2"
  local template="$cs"
  [ "$N8N_MTS_LANG" = "en" ] && template="$en"
  echo "[ops] $template"
}

# shared claude.ai login for remote-control (see OPS.md)
if [ -f /auth/.credentials.json ]; then
  cp /auth/.credentials.json "$HOME/.claude/.credentials.json"
  chmod 600 "$HOME/.claude/.credentials.json"
  log 'převzato sdílené claude.ai přihlášení' 'picked up the shared claude.ai login'
else
  log "/auth/.credentials.json nenalezeno — remote-control čeká na 'claude /login'" \
      "/auth/.credentials.json not found — remote-control is waiting for 'claude /login'"
fi

# remote-control retry loop
cat > /usr/local/bin/rc-loop.sh <<'RC'
#!/usr/bin/env bash
export HOME=/root
cd /workspace || cd /root
while true; do
  echo "[rc] $(date -u +%FT%TZ) starting claude remote-control"
  claude remote-control 2>&1 || echo "[rc] remote-control exited (code $?) — probably missing a claude.ai login"
  sleep 30
done
RC
chmod +x /usr/local/bin/rc-loop.sh

start_rc() { screen -S remote-control -Q select . >/dev/null 2>&1 || \
  screen -dmS remote-control bash -lc '/usr/local/bin/rc-loop.sh >> /var/log/remote-control.log 2>&1'; }
start_rc
log "screen session 'remote-control' spuštěna" "screen session 'remote-control' started"

# @reboot cron safety net: restore the screen session if it's missing after a restart
cat > /etc/cron.d/ops-rc <<'CRON'
@reboot root screen -dmS remote-control bash -lc '/usr/local/bin/rc-loop.sh >> /var/log/remote-control.log 2>&1'
CRON
chmod 0644 /etc/cron.d/ops-rc
service cron start 2>/dev/null || cron || true

log 'hotovo. Ovládej: docker exec -it claude-code-n8n-mts bash' \
    'done. Control it via: docker exec -it claude-code-n8n-mts bash'
exec tail -F /var/log/remote-control.log 2>/dev/null
