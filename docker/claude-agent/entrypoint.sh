#!/usr/bin/env bash
# entrypoint pro claude-{klient}. Spouští se při každém startu kontejneru.
# Úkoly:
#   1) připraví ~/.claude a případně převezme sdílené claude.ai přihlášení
#      (pro `claude remote-control`) z read-only mountu /auth
#   2) položí do /workspace CLAUDE.md popisující, jak mluvit s n8n API klienta
#   3) nastartuje cron (hodinový sběr spotřeby AI do usage.log)
#   4) spustí screen session s `claude remote-control` (retry smyčka)
#   5) drží kontejner naživu
set -euo pipefail

CLIENT="${CLIENT:-unknown}"
export HOME=/root
mkdir -p "$HOME/.claude"

# --- 1) sdílené claude.ai přihlášení pro remote-control (volitelné) ---
# remote-control funguje JEN s claude.ai subscription přihlášením, ne s API klíčem.
# Pokud operátor jednou provede `claude /login` a uloží credentials do
# /opt/n8n-mts/claude-auth/.credentials.json (mount → /auth), převezmeme je zde.
if [ -f /auth/.credentials.json ]; then
  cp /auth/.credentials.json "$HOME/.claude/.credentials.json"
  chmod 600 "$HOME/.claude/.credentials.json"
  echo "[entrypoint] převzato sdílené claude.ai přihlášení pro remote-control"
else
  echo "[entrypoint] /auth/.credentials.json nenalezeno — remote-control bude čekat na přihlášení (viz CLAUDE.md ops vrstvy)"
fi

# --- 2) instrukce pro klientův Claude Code ---
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
  echo "[entrypoint] zapsán /workspace/CLAUDE.md"
fi

# --- 3) cron: hodinový sběr spotřeby ---
cat > /usr/local/etc-usage.env <<EOF
CLIENT=${CLIENT}
USAGE_LOG=/client/usage.log
EOF
cat > /etc/cron.d/usage-collect <<'CRON'
# sběr spotřeby AI každou hodinu (v :07)
7 * * * * root /usr/local/bin/usage-collect.sh >> /var/log/usage-collect.log 2>&1
CRON
chmod 0644 /etc/cron.d/usage-collect
crontab /etc/cron.d/usage-collect 2>/dev/null || true
service cron start 2>/dev/null || cron || true
echo "[entrypoint] cron spuštěn (hodinový usage-collect)"

# --- 4) claude remote-control ve screen session (retry smyčka) ---
cat > /usr/local/bin/rc-loop.sh <<'RC'
#!/usr/bin/env bash
export HOME=/root
while true; do
  echo "[rc] $(date -u +%FT%TZ) startuji claude remote-control"
  claude remote-control 2>&1 || echo "[rc] remote-control skončil (kód $?) — nejspíš chybí claude.ai přihlášení"
  sleep 30
done
RC
chmod +x /usr/local/bin/rc-loop.sh
screen -dmS remote-control bash -lc '/usr/local/bin/rc-loop.sh >> /var/log/remote-control.log 2>&1'
echo "[entrypoint] screen session 'remote-control' spuštěna"

# --- 5) drž kontejner naživu ---
echo "[entrypoint] hotovo, kontejner běží. (docker exec -it claude-${CLIENT} bash)"
exec tail -F /var/log/remote-control.log /var/log/usage-collect.log 2>/dev/null
