#!/usr/bin/env bash
# new-app.sh <client> <app> — sets up an app for an existing client:
#   (retrofits the ./apps:/apps bind mount on claude-{client} if it's
#   not there yet), an app-{client}-{app} container in the same
#   network net-{client}, code shared with claude-{client} via /apps,
#   an n8n API key, an Apache vhost + HTTPS, a record in apps.md,
#   appending to the client's CLAUDE.md.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh"
require_root

MSG_CS[new_app.usage]='Použití: new-app.sh <klient> <appka>'
MSG_EN[new_app.usage]='Usage: new-app.sh <client> <app>'
MSG_CS[new_app.no_client]="Klient '%s' neexistuje — nejdřív ./scripts/new-client.sh %s"
MSG_EN[new_app.no_client]="Client '%s' doesn't exist — run ./scripts/new-client.sh %s first"
MSG_CS[new_app.already_exists]="Appka '%s' u klienta '%s' už existuje v apps.md."
MSG_EN[new_app.already_exists]="App '%s' for client '%s' already exists in apps.md."
MSG_CS[new_app.container_exists]='Kontejner app-%s-%s už existuje.'
MSG_EN[new_app.container_exists]='Container app-%s-%s already exists.'
MSG_CS[new_app.client_env_missing]="Chybí %s — klient '%s' vypadá neúplně založený."
MSG_EN[new_app.client_env_missing]="Missing %s — client '%s' looks like it wasn't fully set up."
MSG_CS[new_app.founding]="Zakládám appku '%s' pro klienta '%s'  →  %s"
MSG_EN[new_app.founding]="Setting up app '%s' for client '%s'  →  %s"
MSG_CS[new_app.retrofit_needed]='claude-%s ještě nemá /apps mount — jednorázově doplňuji (retrofit)'
MSG_EN[new_app.retrofit_needed]='claude-%s does not have the /apps mount yet — adding it (one-time retrofit)'
MSG_CS[new_app.retrofit_done]='claude-%s přegenerován s /apps mountem (n8n-%s beze změny)'
MSG_EN[new_app.retrofit_done]='claude-%s regenerated with the /apps mount (n8n-%s untouched)'
MSG_CS[new_app.creating_apikey]='Vytvářím appce vlastní n8n API klíč'
MSG_EN[new_app.creating_apikey]='Creating the app its own n8n API key'
MSG_CS[new_app.apikey_created]='API klíč pro appku vytvořen'
MSG_EN[new_app.apikey_created]='API key for the app created'
MSG_CS[new_app.apikey_failed]='API klíč se nepodařilo vytvořit automaticky — appka poběží bez přístupu k n8n API.'
MSG_EN[new_app.apikey_failed]='Could not create the API key automatically — the app will run without n8n API access.'
MSG_CS[new_app.compose_generated]='clients/%s/apps/%s/docker-compose.yml vygenerován'
MSG_EN[new_app.compose_generated]='clients/%s/apps/%s/docker-compose.yml generated'
MSG_CS[new_app.starting]='Spouštím app-%s-%s'
MSG_EN[new_app.starting]='Starting app-%s-%s'
MSG_CS[new_app.running]='app-%s-%s běží (zatím placeholder, dokud nevznikne code/start.sh)'
MSG_EN[new_app.running]='app-%s-%s is running (placeholder for now, until code/start.sh exists)'
MSG_CS[new_app.vhost_for]='Apache vhost pro %s'
MSG_EN[new_app.vhost_for]='Apache vhost for %s'
MSG_CS[new_app.vhost_active]='vhost aktivní (HTTP)'
MSG_EN[new_app.vhost_active]='vhost active (HTTP)'
MSG_CS[new_app.issuing_cert]='Vydávám HTTPS certifikát (certbot --apache)'
MSG_EN[new_app.issuing_cert]='Issuing an HTTPS certificate (certbot --apache)'
MSG_CS[new_app.cert_issued]='Certifikát vydán, HTTPS + redirect aktivní'
MSG_EN[new_app.cert_issued]='Certificate issued, HTTPS + redirect active'
MSG_CS[new_app.certbot_failed]='certbot selhal. Zkontroluj: dig +short %s — musí ukazovat na tento server.'
MSG_EN[new_app.certbot_failed]="certbot failed. Check: dig +short %s — it must point at this server."
MSG_CS[new_app.certbot_detail]='Detail: /tmp/certbot-%s-%s.log'
MSG_EN[new_app.certbot_detail]='Details: /tmp/certbot-%s-%s.log'
MSG_CS[new_app.written_to_apps_md]='Zapsáno do apps.md'
MSG_EN[new_app.written_to_apps_md]='Written to apps.md'
MSG_CS[new_app.claude_md_updated]='claude-%s má appku zapsanou v CLAUDE.md'
MSG_EN[new_app.claude_md_updated]="claude-%s has the app recorded in its CLAUDE.md"
MSG_CS[new_app.summary_title]="Appka '%s' (klient '%s') založena."
MSG_EN[new_app.summary_title]="App '%s' (client '%s') set up."
MSG_CS[new_app.summary_url]='  URL appky   : %s'
MSG_EN[new_app.summary_url]='  App URL       : %s'
MSG_CS[new_app.summary_port]='  Appka port  : 127.0.0.1:%s (jen loopback, ven přes Apache)'
MSG_EN[new_app.summary_port]='  App port      : 127.0.0.1:%s (loopback only, exposed via Apache)'
MSG_CS[new_app.summary_code]='  Kód appky   : %s/code/  (uvnitř claude-%s na /apps/%s/code/)'
MSG_EN[new_app.summary_code]='  App code      : %s/code/  (inside claude-%s at /apps/%s/code/)'
MSG_CS[new_app.summary_start]='  Spuštění    : napiš spustitelný code/start.sh, appka se sama vezme'
MSG_EN[new_app.summary_start]='  Starting it   : write an executable code/start.sh, the app picks it up itself'

CLIENT="${1:-}"; APPKA="${2:-}"
[ -n "$CLIENT" ] && [ -n "$APPKA" ] || die "$(msg new_app.usage)"
validate_name "$CLIENT"
validate_name "$APPKA"
ensure_apps_md
client_exists "$CLIENT" || die "$(msg new_app.no_client "$CLIENT" "$CLIENT")"
app_exists "$CLIENT" "$APPKA" && die "$(msg new_app.already_exists "$APPKA" "$CLIENT")"
docker ps -a --format '{{.Names}}' | grep -qx "app-$CLIENT-$APPKA" && die "$(msg new_app.container_exists "$CLIENT" "$APPKA")"

CDIR="$CLIENTS_DIR/$CLIENT"
[ -f "$CDIR/.env" ] || die "$(msg new_app.client_env_missing "$CDIR/.env" "$CLIENT")"
ADIR="$CDIR/apps/$APPKA"
APP_SUBDOMAIN="$CLIENT-$APPKA.$DOMAIN"
APP_PORT="$(find_free_app_port)"

# The client's own values (SUBDOMAIN, N8N_PORT, N8N_OWNER_EMAIL/PASSWORD...) —
# loaded ONCE here, so they don't get overwritten later by sourcing .env again.
# Careful: $SUBDOMAIN from here is the CLIENT's own subdomain, not the
# app's — that's $APP_SUBDOMAIN.
set -a; . "$CDIR/.env"; set +a

say "$(msg new_app.founding "$APPKA" "$CLIENT" "https://$APP_SUBDOMAIN")"

# --- 0) retrofit: claude-{client} needs the ./apps:/apps bind mount ---
# Older clients (set up before this feature existed) have a
# docker-compose.yml generated from an older template without the
# mount — regenerate it and recreate only claude-{client} (n8n-{client}
# stays untouched).
if ! grep -q '\./apps:/apps' "$CDIR/docker-compose.yml" 2>/dev/null; then
  say "$(msg new_app.retrofit_needed "$CLIENT")"
  CLIENT="$CLIENT" SUBDOMAIN="$SUBDOMAIN" N8N_PORT="$N8N_PORT" \
    envsubst '$CLIENT $SUBDOMAIN $N8N_PORT $N8N_MTS_LANG' \
    < "$TEMPLATES/docker-compose.yml.tmpl" > "$CDIR/docker-compose.yml"
  mkdir -p "$CDIR/apps"
  ( cd "$CDIR" && docker compose up -d --force-recreate "claude-$CLIENT" >/dev/null )
  ok "$(msg new_app.retrofit_done "$CLIENT" "$CLIENT")"
fi

mkdir -p "$ADIR/code"

# --- 1) n8n API key for the app (its own, not shared with claude-{client}) ---
say "$(msg new_app.creating_apikey)"
APP_N8N_API_KEY="$("$DIR/n8n-apikey.sh" "http://127.0.0.1:$N8N_PORT" "$N8N_OWNER_EMAIL" "$N8N_OWNER_PASSWORD" "ops-provisioned-appka-$CLIENT-$APPKA" || true)"
if [ -n "$APP_N8N_API_KEY" ]; then
  ok "$(msg new_app.apikey_created)"
else
  warn "$(msg new_app.apikey_failed)"
fi

# --- 2) app .env (outside git) ---
# ENABLE_SSH/APP_SSH_PASSWORD are off by default — claude-CLIENT fills
# the app via the bind mount. Turned on separately, see enable-app-ssh.sh.
cat > "$ADIR/.env" <<ENV
CLIENT=$CLIENT
APPKA=$APPKA
N8N_API_KEY=$APP_N8N_API_KEY
ENABLE_SSH=0
APP_SSH_PASSWORD=
ENV
chmod 600 "$ADIR/.env"

# --- 3) app's docker-compose from the template ---
CLIENT="$CLIENT" APPKA="$APPKA" APP_PORT="$APP_PORT" \
  envsubst '$CLIENT $APPKA $APP_PORT $N8N_MTS_LANG' \
  < "$TEMPLATES/app-docker-compose.yml.tmpl" > "$ADIR/docker-compose.yml"
ok "$(msg new_app.compose_generated "$CLIENT" "$APPKA")"

# --- 4) app-runtime image (build if missing or changed) ---
ensure_image "n8n-mts/app-runtime" "$ROOT/docker/app-runtime"

# --- 5) start the app ---
say "$(msg new_app.starting "$CLIENT" "$APPKA")"
( cd "$ADIR" && docker compose up -d >/dev/null )
ok "$(msg new_app.running "$CLIENT" "$APPKA")"

# --- 6) Apache vhost + certificate ---
say "$(msg new_app.vhost_for "$APP_SUBDOMAIN")"
VHOST="/etc/apache2/sites-available/$CLIENT-$APPKA.conf"
CLIENT="$CLIENT" APPKA="$APPKA" SUBDOMAIN="$APP_SUBDOMAIN" APP_PORT="$APP_PORT" \
  envsubst '$CLIENT $APPKA $SUBDOMAIN $APP_PORT' \
  < "$TEMPLATES/app-vhost.conf.tmpl" > "$VHOST"
a2ensite "$CLIENT-$APPKA.conf" >/dev/null
apache2ctl configtest && systemctl reload apache2
ok "$(msg new_app.vhost_active)"

say "$(msg new_app.issuing_cert)"
if certbot --apache -d "$APP_SUBDOMAIN" --non-interactive --agree-tos \
      -m "$CERTBOT_EMAIL" --no-redirect >/tmp/certbot-$CLIENT-$APPKA.log 2>&1; then
  ok "$(msg new_app.cert_issued)"
  CERT_OK=1
  # h2 in the :443 vhost certbot just generated (see new-client.sh / lib.sh)
  ensure_vhost_http2 "/etc/apache2/sites-available/$CLIENT-$APPKA-le-ssl.conf"
else
  warn "$(msg new_app.certbot_failed "$APP_SUBDOMAIN")"
  warn "$(msg new_app.certbot_detail "$CLIENT" "$APPKA")"
  CERT_OK=0
fi

# --- 7) record in apps.md ---
TODAY="$(date +%F)"
printf '| %s | %s | %s | %s | %s | %s |\n' \
  "$CLIENT" "$APPKA" "$APP_SUBDOMAIN" "$APP_PORT" "$TODAY" "active" >> "$APPS_MD"
ok "$(msg new_app.written_to_apps_md)"

# --- 8) append to the client's CLAUDE.md (persistent workspace volume, so
# the app shows up there permanently) ---
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
ok "$(msg new_app.claude_md_updated "$CLIENT")"

# --- summary ---
echo
echo "──────────────────────────────────────────────"
ok "$(msg new_app.summary_title "$APPKA" "$CLIENT")"
echo "$(msg new_app.summary_url "$([ "${CERT_OK:-0}" = 1 ] && echo https || echo http)://$APP_SUBDOMAIN")"
echo "$(msg new_app.summary_port "$APP_PORT")"
echo "$(msg new_app.summary_code "$ADIR" "$CLIENT" "$APPKA")"
echo "$(msg new_app.summary_start)"
echo "──────────────────────────────────────────────"
