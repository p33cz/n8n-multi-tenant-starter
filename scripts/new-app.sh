#!/usr/bin/env bash
# new-app.sh <klient> <appka> — založí appku pro existujícího klienta:
#   (retrofit bind mountu ./apps:/apps u claude-{klient}, pokud tam ještě není),
#   kontejner app-{klient}-{appka} ve stejné síti net-{klient}, sdílený kód
#   s claude-{klient} přes /apps, n8n API klíč, Apache vhost + HTTPS,
#   záznam do apps.md, doplnění klientova CLAUDE.md.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh"
require_root

CLIENT="${1:-}"; APPKA="${2:-}"
[ -n "$CLIENT" ] && [ -n "$APPKA" ] || die "Použití: new-app.sh <klient> <appka>"
validate_name "$CLIENT"
validate_name "$APPKA"
ensure_apps_md
client_exists "$CLIENT" || die "Klient '$CLIENT' neexistuje — nejdřív ./scripts/new-client.sh $CLIENT"
app_exists "$CLIENT" "$APPKA" && die "Appka '$APPKA' u klienta '$CLIENT' už existuje v apps.md."
docker ps -a --format '{{.Names}}' | grep -qx "app-$CLIENT-$APPKA" && die "Kontejner app-$CLIENT-$APPKA už existuje."

CDIR="$CLIENTS_DIR/$CLIENT"
[ -f "$CDIR/.env" ] || die "Chybí $CDIR/.env — klient '$CLIENT' vypadá neúplně založený."
ADIR="$CDIR/apps/$APPKA"
APP_SUBDOMAIN="$CLIENT-$APPKA.$DOMAIN"
APP_PORT="$(find_free_app_port)"

# Klientovy vlastní hodnoty (SUBDOMAIN, N8N_PORT, N8N_OWNER_EMAIL/PASSWORD...) —
# načteme JEDNOU tady, ať se dál v skriptu nepřepisují opakovaným sourcováním.
# Pozor: $SUBDOMAIN odtud je KLIENTOVA subdoména, ne appky — ta je $APP_SUBDOMAIN.
set -a; . "$CDIR/.env"; set +a

say "Zakládám appku '$APPKA' pro klienta '$CLIENT'  →  https://$APP_SUBDOMAIN"

# --- 0) retrofit: claude-{klient} potřebuje bind mount ./apps:/apps ---
# Starší klienti (založení před touhle funkcí) mají docker-compose.yml
# vygenerovaný ze starší šablony bez mountu — přegenerujeme ho a jen
# claude-{klient} recreatneme (n8n-{klient} se tím nedotkne).
if ! grep -q '\./apps:/apps' "$CDIR/docker-compose.yml" 2>/dev/null; then
  say "claude-$CLIENT ještě nemá /apps mount — jednorázově doplňuji (retrofit)"
  CLIENT="$CLIENT" SUBDOMAIN="$SUBDOMAIN" N8N_PORT="$N8N_PORT" \
    envsubst '$CLIENT $SUBDOMAIN $N8N_PORT' \
    < "$TEMPLATES/docker-compose.yml.tmpl" > "$CDIR/docker-compose.yml"
  mkdir -p "$CDIR/apps"
  ( cd "$CDIR" && docker compose up -d --force-recreate "claude-$CLIENT" >/dev/null )
  ok "claude-$CLIENT přegenerován s /apps mountem (n8n-$CLIENT beze změny)"
fi

mkdir -p "$ADIR/code"

# --- 1) n8n API klíč pro appku (vlastní, ne sdílený s claude-{klient}) ---
say "Vytvářím appce vlastní n8n API klíč"
APP_N8N_API_KEY="$("$DIR/n8n-apikey.sh" "http://127.0.0.1:$N8N_PORT" "$N8N_OWNER_EMAIL" "$N8N_OWNER_PASSWORD" "ops-provisioned-appka-$CLIENT-$APPKA" || true)"
if [ -n "$APP_N8N_API_KEY" ]; then
  ok "API klíč pro appku vytvořen"
else
  warn "API klíč se nepodařilo vytvořit automaticky — appka poběží bez přístupu k n8n API."
fi

# --- 2) .env appky (mimo git) ---
# ENABLE_SSH/APP_SSH_PASSWORD jsou vypnuté defaultně — appku plní
# claude-CLIENT přes bind mount. Zapíná se zvlášť, viz enable-app-ssh.sh.
cat > "$ADIR/.env" <<ENV
CLIENT=$CLIENT
APPKA=$APPKA
N8N_API_KEY=$APP_N8N_API_KEY
ENABLE_SSH=0
APP_SSH_PASSWORD=
ENV
chmod 600 "$ADIR/.env"

# --- 3) docker-compose appky z šablony ---
CLIENT="$CLIENT" APPKA="$APPKA" APP_PORT="$APP_PORT" \
  envsubst '$CLIENT $APPKA $APP_PORT' \
  < "$TEMPLATES/app-docker-compose.yml.tmpl" > "$ADIR/docker-compose.yml"
ok "clients/$CLIENT/apps/$APPKA/docker-compose.yml vygenerován"

# --- 4) image app-runtime (postav, pokud chybí) ---
if ! docker image inspect n8n-mts/app-runtime:latest >/dev/null 2>&1; then
  say "Buildím image n8n-mts/app-runtime:latest (jednorázově)"
  docker build -t n8n-mts/app-runtime:latest "$ROOT/docker/app-runtime" >/dev/null
  ok "Image postaven"
fi

# --- 5) spusť appku ---
say "Spouštím app-$CLIENT-$APPKA"
( cd "$ADIR" && docker compose up -d >/dev/null )
ok "app-$CLIENT-$APPKA běží (zatím placeholder, dokud nevznikne code/start.sh)"

# --- 6) Apache vhost + certifikát ---
say "Apache vhost pro $APP_SUBDOMAIN"
VHOST="/etc/apache2/sites-available/$CLIENT-$APPKA.conf"
CLIENT="$CLIENT" APPKA="$APPKA" SUBDOMAIN="$APP_SUBDOMAIN" APP_PORT="$APP_PORT" \
  envsubst '$CLIENT $APPKA $SUBDOMAIN $APP_PORT' \
  < "$TEMPLATES/app-vhost.conf.tmpl" > "$VHOST"
a2ensite "$CLIENT-$APPKA.conf" >/dev/null
apache2ctl configtest && systemctl reload apache2
ok "vhost aktivní (HTTP)"

say "Vydávám HTTPS certifikát (certbot --apache)"
if certbot --apache -d "$APP_SUBDOMAIN" --non-interactive --agree-tos \
      -m "$CERTBOT_EMAIL" --no-redirect >/tmp/certbot-$CLIENT-$APPKA.log 2>&1; then
  ok "Certifikát vydán, HTTPS + redirect aktivní"
  CERT_OK=1
else
  warn "certbot selhal. Zkontroluj: dig +short $APP_SUBDOMAIN — musí ukazovat na tento server."
  warn "Detail: /tmp/certbot-$CLIENT-$APPKA.log"
  CERT_OK=0
fi

# --- 7) evidence v apps.md ---
TODAY="$(date +%F)"
printf '| %s | %s | %s | %s | %s | %s |\n' \
  "$CLIENT" "$APPKA" "$APP_SUBDOMAIN" "$APP_PORT" "$TODAY" "active" >> "$APPS_MD"
ok "Zapsáno do apps.md"

# --- 8) doplň klientův CLAUDE.md (persistentní workspace volume, appka se v něm objeví natrvalo) ---
docker exec "claude-$CLIENT" sh -c "cat >> /workspace/CLAUDE.md" <<EOF

## Appka: $APPKA
- Kód appky: /apps/$APPKA/code/ (sdílené s kontejnerem app-$CLIENT-$APPKA)
- Appka se sama za běhu podle obsahu code/ rozhodne, jak se spustit —
  nic se nevybírá předem:
  1. spustitelný code/start.sh naslouchající na portu 8080 → spustí se ten
  2. jinak code/ obsahuje cokoli → appka to servíruje sama přes Apache (PHP
     i statické HTML/CSS fungují bez dalšího nastavení); Apache servíruje
     jen známé bezpečné typy souborů (HTML/CSS/JS/obrázky/fonty/PHP), cokoli
     jiného (.json, .db, bez přípony...) přes URL nedostupné, ať se appka
     jmenuje jakkoli — necháš tam klidně nastavení/hesla, nejsou stažitelná
  3. code/ je prázdný → běží jen placeholder
  Appka může mít víc "webů" jako podsložky (code/web-a/, code/web-b/) —
  každá se objeví na https://$APP_SUBDOMAIN/web-a atd., čistě podle struktury
  souborů, nic se pro to nekonfiguruje.
- Appka standardně nemá SSH (spravuješ ji ty přes tenhle bind mount). Pokud
  ji potřebuje plnit něco zvenku (typicky n8n workflow), zapni to:
  scripts/enable-app-ssh.sh $CLIENT $APPKA
- Veřejná adresa: https://$APP_SUBDOMAIN
- n8n API téhle appky (pokud ho appka sama potřebuje): stejné \$N8N_API_URL
  jako máš ty, appka má svůj vlastní N8N_API_KEY (jiný než tvůj).
EOF
ok "claude-$CLIENT má appku zapsanou v CLAUDE.md"

# --- shrnutí ---
echo
echo "──────────────────────────────────────────────"
ok "Appka '$APPKA' (klient '$CLIENT') založena."
echo "  URL appky   : $([ "${CERT_OK:-0}" = 1 ] && echo https || echo http)://$APP_SUBDOMAIN"
echo "  Appka port  : 127.0.0.1:$APP_PORT (jen loopback, ven přes Apache)"
echo "  Kód appky   : $ADIR/code/  (uvnitř claude-$CLIENT na /apps/$APPKA/code/)"
echo "  Spuštění    : napiš spustitelný code/start.sh, appka se sama vezme"
echo "──────────────────────────────────────────────"
