#!/usr/bin/env bash
# entrypoint for claude-{client}. Runs on every container start.
# Tasks:
#   1) prepares ~/.claude and, if present, picks up the shared claude.ai
#      login (for `claude remote-control`) from the read-only /auth mount
#   2) writes /workspace/CLAUDE.md describing how to talk to the client's n8n API
#   3) starts cron (hourly AI usage collection into usage.log)
#   4) starts a screen session running `claude remote-control` (retry loop)
#   5) keeps the container alive
set -euo pipefail

CLIENT="${CLIENT:-unknown}"
export HOME=/root
mkdir -p "$HOME/.claude"

# Standalone entrypoint — no access to scripts/lib.sh inside the
# container, so it keeps its own tiny N8N_MTS_LANG switch (the value
# itself is passed in from the host via docker-compose, see
# templates/docker-compose.yml.tmpl).
N8N_MTS_LANG="${N8N_MTS_LANG:-cs}"
log() {
  local cs="$1" en="$2"
  local template="$cs"
  [ "$N8N_MTS_LANG" = "en" ] && template="$en"
  echo "[entrypoint] $template"
}

# --- 1) shared claude.ai login for remote-control (optional) ---
# remote-control only works with a claude.ai subscription login, not an
# API key. Once the operator runs `claude /login` and saves the
# credentials to /opt/n8n-mts/claude-auth/.credentials.json (mounted
# as /auth), we pick them up here.
if [ -f /auth/.credentials.json ]; then
  cp /auth/.credentials.json "$HOME/.claude/.credentials.json"
  chmod 600 "$HOME/.claude/.credentials.json"
  log 'převzato sdílené claude.ai přihlášení pro remote-control' \
      'picked up the shared claude.ai login for remote-control'
else
  log '/auth/.credentials.json nenalezeno — remote-control bude čekat na přihlášení (viz OPS.md ops vrstvy)' \
      '/auth/.credentials.json not found — remote-control will wait for a login (see the ops layer OPS.md)'
fi

# --- 2) instructions for the client's Claude Code ---
if [ ! -f /workspace/CLAUDE.md ]; then
  cat > /workspace/CLAUDE.md <<EOF
# Claude Code pro klienta: ${CLIENT}

Jsi asistent JEDNOHO klienta n8n hostingu. Mluvíš VÝHRADNĚ s n8n instancí
tohoto klienta přes její REST API. Nevidíš a nesmíš se pokoušet vidět žádného
jiného klienta ani hostitele — jsi síťově izolovaný, docker.sock nemáš.

## n8n REST API tohoto klienta
- Base URL: \${N8N_API_URL}         (interní hostname v síti net-${CLIENT})
- Autentizace: hlavička  X-N8N-API-KEY: \${N8N_API_KEY}

Příklady:
\`\`\`bash
# seznam workflow
curl -s -H "X-N8N-API-KEY: \$N8N_API_KEY" "\$N8N_API_URL/workflows" | jq .
# detail workflow
curl -s -H "X-N8N-API-KEY: \$N8N_API_KEY" "\$N8N_API_URL/workflows/<id>" | jq .
\`\`\`

Klíč i URL máš v proměnných prostředí \$N8N_API_KEY a \$N8N_API_URL.
Tvým úkolem je klientovi vytvářet a upravovat workflow a agenty přes toto API.
EOF
  log 'zapsán /workspace/CLAUDE.md' 'wrote /workspace/CLAUDE.md'
fi

# --- 3) cron: hourly usage collection ---
cat > /usr/local/etc-usage.env <<EOF
CLIENT=${CLIENT}
USAGE_LOG=/client/usage.log
EOF
cat > /etc/cron.d/usage-collect <<'CRON'
# collect AI usage every hour (at :07)
7 * * * * root /usr/local/bin/usage-collect.sh >> /var/log/usage-collect.log 2>&1
CRON
chmod 0644 /etc/cron.d/usage-collect
crontab /etc/cron.d/usage-collect 2>/dev/null || true
service cron start 2>/dev/null || cron || true
log 'cron spuštěn (hodinový usage-collect)' 'cron started (hourly usage-collect)'

# --- 4) claude remote-control in a screen session (retry loop) ---
cat > /usr/local/bin/rc-loop.sh <<'RC'
#!/usr/bin/env bash
export HOME=/root
while true; do
  echo "[rc] $(date -u +%FT%TZ) starting claude remote-control"
  claude remote-control 2>&1 || echo "[rc] remote-control exited (code $?) — probably missing a claude.ai login"
  sleep 30
done
RC
chmod +x /usr/local/bin/rc-loop.sh
screen -dmS remote-control bash -lc '/usr/local/bin/rc-loop.sh >> /var/log/remote-control.log 2>&1'
log "screen session 'remote-control' spuštěna" "screen session 'remote-control' started"

# --- 5) keep the container alive ---
log "hotovo, kontejner běží. (docker exec -it claude-${CLIENT} bash)" \
    "done, the container is running. (docker exec -it claude-${CLIENT} bash)"
exec tail -F /var/log/remote-control.log /var/log/usage-collect.log 2>/dev/null
