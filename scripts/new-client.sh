#!/usr/bin/env bash
# new-client.sh <jmeno> — založí nového klienta:
#   DB + uživatel, síť net-{jmeno}, n8n-{jmeno}, n8n API klíč, claude-{jmeno},
#   Apache vhost + HTTPS certifikát, záznam do clients.md.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh"
require_root

CLIENT="${1:-}"
[ -n "$CLIENT" ] || die "Použití: new-client.sh <jmeno>"
validate_name "$CLIENT"
ensure_dirs
ensure_clients_md
client_exists "$CLIENT" && die "Klient '$CLIENT' už existuje v clients.md."
docker ps -a --format '{{.Names}}' | grep -qx "n8n-$CLIENT" && die "Kontejner n8n-$CLIENT už existuje."

SUBDOMAIN="$CLIENT.$DOMAIN"
CDIR="$CLIENTS_DIR/$CLIENT"
NET="net-$CLIENT"
DB="db_$CLIENT"; DBUSER="u_$CLIENT"
N8N_PORT="$(find_free_port)"
DB_PASSWORD="$(gen_secret 40 40)"
N8N_ENCRYPTION_KEY="$(gen_secret 40 40)"
OWNER_EMAIL="owner@$SUBDOMAIN"
OWNER_PASSWORD="$(gen_secret 24 20)Aa1!"     # splní n8n password policy
ANTHROPIC_API_KEY="$(grep -E '^ANTHROPIC_API_KEY=' "$ROOT/.env" | cut -d= -f2-)"
[ -n "$ANTHROPIC_API_KEY" ] || warn "ANTHROPIC_API_KEY prázdný — claude-$CLIENT poběží bez klíče."

say "Zakládám klienta '$CLIENT'  →  https://$SUBDOMAIN  (n8n port 127.0.0.1:$N8N_PORT)"
mkdir -p "$CDIR/backups" "$CDIR/apps"

# --- 1) Postgres: DB + uživatel jen na svou DB ---
say "Postgres: role $DBUSER + databáze $DB"
psql_super <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='$DBUSER') THEN
    CREATE ROLE $DBUSER LOGIN PASSWORD '$DB_PASSWORD';
  ELSE
    ALTER ROLE $DBUSER LOGIN PASSWORD '$DB_PASSWORD';
  END IF;
END \$\$;
SQL
# CREATE DATABASE nejde v DO bloku / transakci — ošetři existenci zvlášť
if ! psql_super -tAc "SELECT 1 FROM pg_database WHERE datname='$DB'" | grep -q 1; then
  psql_super -c "CREATE DATABASE $DB OWNER $DBUSER;"
fi
psql_super -c "REVOKE CONNECT ON DATABASE $DB FROM PUBLIC;"
psql_super -c "GRANT CONNECT ON DATABASE $DB TO $DBUSER;"
psql_super -c "ALTER DATABASE $DB OWNER TO $DBUSER;"
ok "DB připravena (klient nemá přístup k cizím DB)"

# --- 2) síť + připojení Postgresu do ní ---
docker network inspect "$NET" >/dev/null 2>&1 || docker network create --driver bridge "$NET" >/dev/null
docker network connect "$NET" "$PG_CONTAINER" 2>/dev/null || true
ok "Síť $NET vytvořena, Postgres do ní připojen"

# --- 3) .env klienta (mimo git) ---
cat > "$CDIR/.env" <<ENV
CLIENT=$CLIENT
SUBDOMAIN=$SUBDOMAIN
N8N_PORT=$N8N_PORT
DB_PASSWORD=$DB_PASSWORD
N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
N8N_API_KEY=
N8N_OWNER_EMAIL=$OWNER_EMAIL
N8N_OWNER_PASSWORD=$OWNER_PASSWORD
ENV
chmod 600 "$CDIR/.env"

# --- 4) docker-compose z šablony (secret placeholdery necháme na .env) ---
CLIENT="$CLIENT" SUBDOMAIN="$SUBDOMAIN" N8N_PORT="$N8N_PORT" \
  envsubst '$CLIENT $SUBDOMAIN $N8N_PORT' \
  < "$TEMPLATES/docker-compose.yml.tmpl" > "$CDIR/docker-compose.yml"
ok "clients/$CLIENT/docker-compose.yml vygenerován"

# --- 5) image claude-agent (postav, pokud chybí) ---
if ! docker image inspect n8n-mts/claude-agent:latest >/dev/null 2>&1; then
  say "Buildím image n8n-mts/claude-agent:latest (jednorázově)"
  docker build -t n8n-mts/claude-agent:latest "$ROOT/docker/claude-agent" >/dev/null
  ok "Image postaven"
fi

# --- 6) spusť n8n a počkej na běh ---
say "Spouštím n8n-$CLIENT"
( cd "$CDIR" && docker compose up -d "n8n-$CLIENT" >/dev/null )
BASE="http://127.0.0.1:$N8N_PORT"
say "Čekám na naběhnutí n8n…"
for i in $(seq 1 60); do
  curl -fsS "$BASE/healthz" >/dev/null 2>&1 && break
  sleep 2
  [ "$i" = 60 ] && die "n8n-$CLIENT nenaběhl (zkontroluj: docker logs n8n-$CLIENT)"
done
ok "n8n běží"

# --- 7) n8n API klíč scoped na tuto instanci ---
say "Zakládám vlastníka a n8n API klíč"
N8N_API_KEY="$("$DIR/n8n-apikey.sh" "$BASE" "$OWNER_EMAIL" "$OWNER_PASSWORD" || true)"
if [ -n "$N8N_API_KEY" ]; then
  sed -i "s|^N8N_API_KEY=.*|N8N_API_KEY=$N8N_API_KEY|" "$CDIR/.env"
  ok "n8n API klíč vytvořen a uložen do .env"
else
  warn "n8n API klíč se nepodařilo vytvořit automaticky — claude-$CLIENT poběží bez klíče."
  warn "Doplň ho ručně: vygeneruj v n8n UI (Settings → API) a zapiš do $CDIR/.env, pak: cd $CDIR && docker compose up -d claude-$CLIENT"
fi

# --- 8) spusť claude-{klient} ---
say "Spouštím claude-$CLIENT (bez docker.sock, jen síť $NET)"
( cd "$CDIR" && docker compose up -d "claude-$CLIENT" >/dev/null )
ok "claude-$CLIENT běží"

# --- 9) Apache vhost + certifikát ---
say "Apache vhost pro $SUBDOMAIN"
VHOST="/etc/apache2/sites-available/$CLIENT.conf"
CLIENT="$CLIENT" SUBDOMAIN="$SUBDOMAIN" N8N_PORT="$N8N_PORT" \
  envsubst '$CLIENT $SUBDOMAIN $N8N_PORT' \
  < "$TEMPLATES/vhost.conf.tmpl" > "$VHOST"
a2ensite "$CLIENT.conf" >/dev/null
apache2ctl configtest && systemctl reload apache2
ok "vhost aktivní (HTTP)"

say "Vydávám HTTPS certifikát (certbot --apache)"
# redirect řešíme ve vhost šabloně (RewriteCond HTTPS off), proto --no-redirect
if certbot --apache -d "$SUBDOMAIN" --non-interactive --agree-tos \
      -m "$CERTBOT_EMAIL" --no-redirect >/tmp/certbot-$CLIENT.log 2>&1; then
  ok "Certifikát vydán, HTTPS + redirect aktivní"
  CERT_OK=1
else
  warn "certbot selhal. Nejčastější příčina: DNS pro $SUBDOMAIN neukazuje na tento server."
  warn "Zkontroluj prosím: 'dig +short $SUBDOMAIN' musí vrátit veřejnou IP tohoto serveru."
  warn "Detail: /tmp/certbot-$CLIENT.log — po opravě spusť: certbot --apache -d $SUBDOMAIN --redirect"
  CERT_OK=0
fi

# --- 10) evidence v clients.md ---
TODAY="$(date +%F)"
printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
  "$CLIENT" "$SUBDOMAIN" "$N8N_PORT" "$NET" "$DB" "$DBUSER" "$TODAY" "" "active" >> "$CLIENTS_MD"
ok "Zapsáno do clients.md"

# --- shrnutí ---
echo
echo "──────────────────────────────────────────────"
ok "Klient '$CLIENT' založen."
echo "  URL n8n     : $([ "${CERT_OK:-0}" = 1 ] && echo https || echo http)://$SUBDOMAIN"
echo "  n8n port    : 127.0.0.1:$N8N_PORT (jen loopback, ven přes Apache)"
echo "  Síť         : $NET (izolovaná)"
echo "  DB / user   : $DB / $DBUSER"
echo "  n8n vlastník: $OWNER_EMAIL  (heslo v $CDIR/.env)"
echo -n "  claude-$CLIENT: běží; remote-control "
if [ -f "$ROOT/claude-auth/.credentials.json" ]; then echo "ready (sdílené claude.ai přihlášení)"; else echo "čeká na claude.ai přihlášení (viz CLAUDE.md)"; fi
echo "──────────────────────────────────────────────"
