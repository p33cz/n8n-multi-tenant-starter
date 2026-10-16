#!/usr/bin/env bash
# entrypoint for the ops container claude-code-n8n-mts.
# Starts a screen session running `claude remote-control` (retry
# loop) and keeps the container alive. Working directory = /workspace
# (mount of /opt/n8n-mts), server control via /var/run/docker.sock.
# Claude state (login, settings, session history) lives in
# CLAUDE_CONFIG_DIR, a named volume (ops/docker-compose.yml), so it
# survives the container being recreated by `docker compose up`.
set -euo pipefail
export HOME=/root
export CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
mkdir -p "$CLAUDE_CONFIG_DIR"

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

# shared claude.ai login for remote-control (see OPS.md). Only taken
# over when there is no local login yet or the shared one is newer —
# OAuth refresh rotates tokens, so blindly overwriting the persisted
# login with an older copy would log the container out.
CREDS="$CLAUDE_CONFIG_DIR/.credentials.json"
if [ -f /auth/.credentials.json ] && { [ ! -f "$CREDS" ] || [ /auth/.credentials.json -nt "$CREDS" ]; }; then
  cp /auth/.credentials.json "$CREDS"
  chmod 600 "$CREDS"
  log 'převzato sdílené claude.ai přihlášení' 'picked up the shared claude.ai login'
elif [ -f "$CREDS" ]; then
  log 'používám uložené claude.ai přihlášení' 'using the persisted claude.ai login'
else
  log "/auth/.credentials.json nenalezeno — remote-control čeká na 'claude /login'" \
      "/auth/.credentials.json not found — remote-control is waiting for 'claude /login'"
fi

# remote-control retry loop. Remote Control refuses API-key auth, so
# ANTHROPIC_API_KEY (still used by the rest of the container) is unset
# here; the fixed --name keeps the session recognisable in claude.ai and
# --spawn skips the interactive spawn-mode question on first launch.
# First run on a fresh volume still needs, once: `claude auth login`,
# trusting /workspace, and answering "Enable Remote Control? y".
cat > /usr/local/bin/rc-loop.sh <<RC
#!/usr/bin/env bash
export HOME=/root
export CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR"
unset ANTHROPIC_API_KEY
cd /workspace || cd /root
while true; do
  echo "[rc] \$(date -u +%FT%TZ) starting claude remote-control"
  claude remote-control --name claude-code-n8n-mts --spawn=same-dir 2>&1 || echo "[rc] remote-control exited (code \$?) — probably missing a claude.ai login (claude auth login)"
  sleep 30
done
RC
chmod +x /usr/local/bin/rc-loop.sh

# Single instance only: the entrypoint runs on every container start
# (restart policy), so no extra @reboot cron is needed — it used to
# start a second, competing loop.
rm -f /etc/cron.d/ops-rc
start_rc() { screen -S remote-control -Q select . >/dev/null 2>&1 || \
  screen -dmS remote-control bash -lc '/usr/local/bin/rc-loop.sh >> /var/log/remote-control.log 2>&1'; }
start_rc
log "screen session 'remote-control' spuštěna" "screen session 'remote-control' started"
service cron start 2>/dev/null || cron || true

log 'hotovo. Ovládej: docker exec -it claude-code-n8n-mts bash' \
    'done. Control it via: docker exec -it claude-code-n8n-mts bash'
exec tail -F /var/log/remote-control.log 2>/dev/null
