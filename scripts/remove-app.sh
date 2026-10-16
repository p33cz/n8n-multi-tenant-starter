#!/usr/bin/env bash
# remove-app.sh <client> <app> — removes an app:
#   backs up the app's code to the archive, stops+removes the
#   container, removes the Apache vhost and its Let's Encrypt
#   certificate, drops it from apps.md.
# Does NOT touch the client's own containers/network (n8n-{client},
# claude-{client}, net-{client}) — that's remove-client.sh's job.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh"
require_root

MSG_CS[remove_app.usage]='Použití: remove-app.sh <klient> <appka>'
MSG_EN[remove_app.usage]='Usage: remove-app.sh <client> <app>'
MSG_CS[remove_app.not_in_md]="Appka '%s' (klient '%s') není v apps.md — pokusím se uklidit i tak."
MSG_EN[remove_app.not_in_md]="App '%s' (client '%s') isn't in apps.md — I'll try to clean up anyway."
MSG_CS[remove_app.backing_up]='Zálohuji kód appky → %s'
MSG_EN[remove_app.backing_up]="Backing up the app's code → %s"
MSG_CS[remove_app.stopping]='Zastavuji a mažu kontejner appky'
MSG_EN[remove_app.stopping]="Stopping and removing the app's container"
MSG_CS[remove_app.vhost_removed]='Apache vhost odstraněn'
MSG_EN[remove_app.vhost_removed]='Apache vhost removed'
MSG_CS[remove_app.cert_removed]='Certifikát %s smazán (certbot delete)'
MSG_EN[remove_app.cert_removed]='Certificate %s removed (certbot delete)'
MSG_CS[remove_app.cert_remove_failed]='certbot delete pro %s selhalo — zkontroluj ručně (certbot certificates)'
MSG_EN[remove_app.cert_remove_failed]='certbot delete for %s failed — check manually (certbot certificates)'
MSG_CS[remove_app.done]="Appka '%s' (klient '%s') zrušena. Záloha kódu: %s"
MSG_EN[remove_app.done]="App '%s' (client '%s') removed. Code backup: %s"

CLIENT="${1:-}"; APPKA="${2:-}"
[ -n "$CLIENT" ] && [ -n "$APPKA" ] || die "$(msg remove_app.usage)"
validate_name "$CLIENT"
validate_name "$APPKA"
CDIR="$CLIENTS_DIR/$CLIENT"
ADIR="$CDIR/apps/$APPKA"
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE_ADIR="$ARCHIVE_DIR/${CLIENT}-app-${APPKA}-${STAMP}"

app_exists "$CLIENT" "$APPKA" || warn "$(msg remove_app.not_in_md "$APPKA" "$CLIENT")"
mkdir -p "$ARCHIVE_ADIR"

# --- 1) back up the app's code ---
if [ -d "$ADIR/code" ]; then
  say "$(msg remove_app.backing_up "$ARCHIVE_ADIR/code")"
  cp -a "$ADIR/code" "$ARCHIVE_ADIR/code"
fi
[ -f "$ADIR/.env" ] && cp "$ADIR/.env" "$ARCHIVE_ADIR/.env.bak" || true

# --- 2) stop and remove the app's container ---
if [ -f "$ADIR/docker-compose.yml" ]; then
  say "$(msg remove_app.stopping)"
  ( cd "$ADIR" && docker compose down -v >/dev/null 2>&1 ) || true
fi
docker rm -f "app-$CLIENT-$APPKA" >/dev/null 2>&1 || true

# --- 3) Apache vhost ---
if [ -f "/etc/apache2/sites-available/$CLIENT-$APPKA.conf" ]; then
  a2dissite "$CLIENT-$APPKA.conf" >/dev/null 2>&1 || true
  # same dangling-symlink issue as remove-client.sh — see the comment there.
  a2dissite "$CLIENT-$APPKA-le-ssl.conf" >/dev/null 2>&1 || true
  rm -f "/etc/apache2/sites-available/$CLIENT-$APPKA.conf" "/etc/apache2/sites-available/$CLIENT-$APPKA-le-ssl.conf"
  systemctl reload apache2 2>/dev/null || true
  ok "$(msg remove_app.vhost_removed)"
fi

# --- 3b) Let's Encrypt certificate (lineage named after $CLIENT-$APPKA.$DOMAIN, see remove-client.sh) ---
if certbot certificates --cert-name "$CLIENT-$APPKA.$DOMAIN" 2>/dev/null | grep -q "Certificate Name"; then
  if certbot delete --cert-name "$CLIENT-$APPKA.$DOMAIN" --non-interactive >/dev/null 2>&1; then
    ok "$(msg remove_app.cert_removed "$CLIENT-$APPKA.$DOMAIN")"
  else
    warn "$(msg remove_app.cert_remove_failed "$CLIENT-$APPKA.$DOMAIN")"
  fi
fi

# --- 4) drop from apps.md, remove the app directory ---
if [ -f "$APPS_MD" ]; then
  grep -v "^| $CLIENT | $APPKA " "$APPS_MD" > "$APPS_MD.tmp" && mv "$APPS_MD.tmp" "$APPS_MD"
fi
rm -rf "$ADIR"

# --- 5) note in the client's CLAUDE.md ---
if docker ps --format '{{.Names}}' | grep -qx "claude-$CLIENT"; then
  docker exec "claude-$CLIENT" sh -c "cat >> /workspace/CLAUDE.md" <<EOF

## Appka: $APPKA — ZRUŠENA ($(date +%F))
Appka '$APPKA' byla zrušena, adresář /apps/$APPKA/ už neexistuje.
EOF
fi

echo
ok "$(msg remove_app.done "$APPKA" "$CLIENT" "$ARCHIVE_ADIR")"
