#!/usr/bin/env bash
# entrypoint ops kontejneru claude-code-n8n-mts.
# Spustí screen session s `claude remote-control` (retry smyčka), přidá
# @reboot cron pojistku a drží kontejner naživu. Pracovní adresář = /workspace
# (mount /opt/n8n-mts), řízení serveru přes /var/run/docker.sock.
set -euo pipefail
export HOME=/root
mkdir -p "$HOME/.claude"

# sdílené claude.ai přihlášení pro remote-control (viz CLAUDE.md)
if [ -f /auth/.credentials.json ]; then
  cp /auth/.credentials.json "$HOME/.claude/.credentials.json"
  chmod 600 "$HOME/.claude/.credentials.json"
  echo "[ops] převzato sdílené claude.ai přihlášení"
else
  echo "[ops] /auth/.credentials.json nenalezeno — remote-control čeká na 'claude /login'"
fi

# remote-control retry smyčka
cat > /usr/local/bin/rc-loop.sh <<'RC'
#!/usr/bin/env bash
export HOME=/root
cd /workspace || cd /root
while true; do
  echo "[rc] $(date -u +%FT%TZ) startuji claude remote-control"
  claude remote-control 2>&1 || echo "[rc] remote-control skončil (kód $?) — nejspíš chybí claude.ai přihlášení"
  sleep 30
done
RC
chmod +x /usr/local/bin/rc-loop.sh

start_rc() { screen -S remote-control -Q select . >/dev/null 2>&1 || \
  screen -dmS remote-control bash -lc '/usr/local/bin/rc-loop.sh >> /var/log/remote-control.log 2>&1'; }
start_rc
echo "[ops] screen session 'remote-control' spuštěna"

# @reboot cron pojistka: kdyby screen session po startu chyběla, obnov ji
cat > /etc/cron.d/ops-rc <<'CRON'
@reboot root screen -dmS remote-control bash -lc '/usr/local/bin/rc-loop.sh >> /var/log/remote-control.log 2>&1'
CRON
chmod 0644 /etc/cron.d/ops-rc
service cron start 2>/dev/null || cron || true

echo "[ops] hotovo. Ovládej: docker exec -it claude-code-n8n-mts bash"
exec tail -F /var/log/remote-control.log 2>/dev/null
