#!/usr/bin/env bash
# entrypoint pro app-{klient}-{appka}. Spouští se při každém startu kontejneru.
#
# Autodetekce (appka se nemusí předem "typovat"):
#   1) spustitelný $CODE_DIR/start.sh existuje → spustí se ten
#   2) jinak $CODE_DIR obsahuje cokoli         → Apache + PHP servíruje $CODE_DIR
#   3) jinak (appka je prázdná)                → placeholder stránka
# Ve všech třech případech appka poslouchá na portu 8080.
set -euo pipefail

CODE_DIR=/code

# --- volitelné SSH pro deploy zvenku (typicky n8n workflow), viz
# scripts/enable-app-ssh.sh. Vypnuté, dokud appka ENABLE_SSH nemá nastavené.
# claude-{klient} tohle nepotřebuje — ten má $CODE_DIR přímo přes bind mount.
#
# Bez chrootu: appka je sama ve vlastním kontejneru, žádný jiný
# klient/appka tu nic nemá, takže tu není co dalšího (kromě $CODE_DIR)
# chránit — appdeploy dostane normální shell, ať fungují i příkazy z
# workflow (mkdir, chmod, php -l), ne jen upload souborů.
if [ "${ENABLE_SSH:-0}" = "1" ] && [ -n "${APP_SSH_PASSWORD:-}" ]; then
  echo "[entrypoint] SSH deploy přístup zapnutý (uživatel appdeploy, jen tenhle kontejner)"
  echo "appdeploy:${APP_SSH_PASSWORD}" | chpasswd
  # $CODE_DIR je bind mount z hostitele (vlastník root, viz new-app.sh) —
  # appdeploy do něj jinak nemá zapisovat, proto mu ho tady přiřadíme.
  chown -R appdeploy:appdeploy "$CODE_DIR"
  cat > /etc/ssh/sshd_config.d/appdeploy.conf <<'EOF'
Match User appdeploy
    AllowTcpForwarding no
    X11Forwarding no
    PasswordAuthentication yes
EOF
  ssh-keygen -A >/dev/null 2>&1
  mkdir -p /run/sshd
  /usr/sbin/sshd
fi

if [ -x "$CODE_DIR/start.sh" ]; then
  echo "[entrypoint] spouštím $CODE_DIR/start.sh"
  cd "$CODE_DIR"
  exec "$CODE_DIR/start.sh"
fi

if [ -f "$CODE_DIR/start.sh" ]; then
  echo "[entrypoint] $CODE_DIR/start.sh existuje, ale není spustitelný (chmod +x) — zkouším dál"
fi

if [ -n "$(find "$CODE_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]; then
  echo "[entrypoint] $CODE_DIR není prázdný — spouštím Apache + PHP na portu 8080"
  exec apache2ctl -D FOREGROUND
fi

echo "[entrypoint] $CODE_DIR zatím neexistuje/je prázdný — běží placeholder na portu 8080"
exec python3 -m http.server 8080 --directory /placeholder
