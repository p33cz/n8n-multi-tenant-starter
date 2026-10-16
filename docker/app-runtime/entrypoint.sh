#!/usr/bin/env bash
# entrypoint for app-{client}-{app}. Runs on every container start.
#
# Autodetection (an app never needs to be "typed" in advance):
#   1) an executable $CODE_DIR/start.sh exists → that one runs
#   2) otherwise $CODE_DIR has anything in it  → Apache + PHP serves $CODE_DIR
#   3) otherwise (the app is empty)            → the placeholder page
# In all three cases the app listens on port 8080.
set -euo pipefail

CODE_DIR=/code

# Standalone entrypoint — no access to scripts/lib.sh inside the
# container, so it keeps its own tiny N8N_MTS_LANG switch (the value
# itself is passed in from the host via templates/app-docker-compose.yml.tmpl).
N8N_MTS_LANG="${N8N_MTS_LANG:-cs}"
log() {
  local cs="$1" en="$2"
  local template="$cs"
  [ "$N8N_MTS_LANG" = "en" ] && template="$en"
  echo "[entrypoint] $template"
}

# --- optional SSH for external deploy (typically an n8n workflow), see
# scripts/enable-app-ssh.sh. Off until the app has ENABLE_SSH set.
# claude-{client} doesn't need this — it already has $CODE_DIR directly
# via a bind mount.
#
# No chroot: the app sits alone in its own container, no other
# client/app has anything in it, so there's nothing else (besides
# $CODE_DIR) to protect — appdeploy gets a normal shell, so commands
# from a workflow (mkdir, chmod, php -l) work too, not just file uploads.
if [ "${ENABLE_SSH:-0}" = "1" ] && [ -n "${APP_SSH_PASSWORD:-}" ]; then
  log 'SSH deploy přístup zapnutý (uživatel appdeploy, jen tenhle kontejner)' \
      'SSH deploy access turned on (user appdeploy, this container only)'
  echo "appdeploy:${APP_SSH_PASSWORD}" | chpasswd
  # $CODE_DIR is a bind mount from the host (owned by root, see
  # new-app.sh) — appdeploy otherwise has no write access to it, so we
  # assign it here.
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
  log "spouštím $CODE_DIR/start.sh" "running $CODE_DIR/start.sh"
  cd "$CODE_DIR"
  exec "$CODE_DIR/start.sh"
fi

if [ -f "$CODE_DIR/start.sh" ]; then
  log "$CODE_DIR/start.sh existuje, ale není spustitelný (chmod +x) — zkouším dál" \
      "$CODE_DIR/start.sh exists but isn't executable (chmod +x) — trying something else"
fi

if [ -n "$(find "$CODE_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]; then
  log "$CODE_DIR není prázdný — spouštím Apache + PHP na portu 8080" \
      "$CODE_DIR isn't empty — starting Apache + PHP on port 8080"
  exec apache2ctl -D FOREGROUND
fi

log "$CODE_DIR zatím neexistuje/je prázdný — běží placeholder na portu 8080" \
    "$CODE_DIR doesn't exist yet / is empty — running the placeholder on port 8080"
exec python3 -m http.server 8080 --directory /placeholder
