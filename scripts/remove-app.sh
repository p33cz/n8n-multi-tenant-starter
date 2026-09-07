#!/usr/bin/env bash
# remove-app.sh <klient> <appka> — zruší appku:
#   zálohu kódu appky do archivu, zastavení+smazání kontejneru,
#   odebrání Apache vhostu, vyřazení z apps.md.
# Kontejnery a síť klienta (n8n-{klient}, claude-{klient}, net-{klient})
# se NEDOTÝKÁ — to spravuje remove-client.sh.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh"
require_root

CLIENT="${1:-}"; APPKA="${2:-}"
[ -n "$CLIENT" ] && [ -n "$APPKA" ] || die "Použití: remove-app.sh <klient> <appka>"
validate_name "$CLIENT"
validate_name "$APPKA"
CDIR="$CLIENTS_DIR/$CLIENT"
ADIR="$CDIR/apps/$APPKA"
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE_ADIR="$ARCHIVE_DIR/${CLIENT}-app-${APPKA}-${STAMP}"

app_exists "$CLIENT" "$APPKA" || warn "Appka '$APPKA' (klient '$CLIENT') není v apps.md — pokusím se uklidit i tak."
mkdir -p "$ARCHIVE_ADIR"

# --- 1) záloha kódu appky ---
if [ -d "$ADIR/code" ]; then
  say "Zálohuji kód appky → $ARCHIVE_ADIR/code"
  cp -a "$ADIR/code" "$ARCHIVE_ADIR/code"
fi
[ -f "$ADIR/.env" ] && cp "$ADIR/.env" "$ARCHIVE_ADIR/.env.bak" || true

# --- 2) zastav a smaž kontejner appky ---
if [ -f "$ADIR/docker-compose.yml" ]; then
  say "Zastavuji a mažu kontejner appky"
  ( cd "$ADIR" && docker compose down -v >/dev/null 2>&1 ) || true
fi
docker rm -f "app-$CLIENT-$APPKA" >/dev/null 2>&1 || true

# --- 3) Apache vhost ---
if [ -f "/etc/apache2/sites-available/$CLIENT-$APPKA.conf" ]; then
  a2dissite "$CLIENT-$APPKA.conf" >/dev/null 2>&1 || true
  rm -f "/etc/apache2/sites-available/$CLIENT-$APPKA.conf" "/etc/apache2/sites-available/$CLIENT-$APPKA-le-ssl.conf"
  systemctl reload apache2 2>/dev/null || true
  ok "Apache vhost odstraněn (certifikát v /etc/letsencrypt ponechán)"
fi

# --- 4) vyřaď z apps.md, smaž adresář appky ---
if [ -f "$APPS_MD" ]; then
  grep -v "^| $CLIENT | $APPKA " "$APPS_MD" > "$APPS_MD.tmp" && mv "$APPS_MD.tmp" "$APPS_MD"
fi
rm -rf "$ADIR"

# --- 5) poznámka do klientova CLAUDE.md ---
if docker ps --format '{{.Names}}' | grep -qx "claude-$CLIENT"; then
  docker exec "claude-$CLIENT" sh -c "cat >> /workspace/CLAUDE.md" <<EOF

## Appka: $APPKA — ZRUŠENA ($(date +%F))
Appka '$APPKA' byla zrušena, adresář /apps/$APPKA/ už neexistuje.
EOF
fi

echo
ok "Appka '$APPKA' (klient '$CLIENT') zrušena. Záloha kódu: $ARCHIVE_ADIR"
