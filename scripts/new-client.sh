#!/usr/bin/env bash
# new-client.sh <name> — sets up a new client:
#   DB + user, network net-{name}, n8n-{name}, n8n API key, claude-{name},
#   Apache vhost + HTTPS certificate, record in clients.md.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh"
require_root

MSG_CS[new_client.usage]='Použití: new-client.sh <jmeno>'
MSG_EN[new_client.usage]='Usage: new-client.sh <name>'
MSG_CS[new_client.already_exists]="Klient '%s' už existuje v clients.md."
MSG_EN[new_client.already_exists]="Client '%s' already exists in clients.md."
MSG_CS[new_client.container_exists]='Kontejner n8n-%s už existuje.'
MSG_EN[new_client.container_exists]='Container n8n-%s already exists.'
MSG_CS[new_client.empty_api_key]='ANTHROPIC_API_KEY prázdný — claude-%s poběží bez klíče.'
MSG_EN[new_client.empty_api_key]='ANTHROPIC_API_KEY is empty — claude-%s will run without a key.'
MSG_CS[new_client.founding]="Zakládám klienta '%s'  →  %s  (n8n port 127.0.0.1:%s)"
MSG_EN[new_client.founding]="Setting up client '%s'  →  %s  (n8n port 127.0.0.1:%s)"
MSG_CS[new_client.postgres_setup]='Postgres: role %s + databáze %s'
MSG_EN[new_client.postgres_setup]='Postgres: role %s + database %s'
MSG_CS[new_client.db_ready]='DB připravena (klient nemá přístup k cizím DB)'
MSG_EN[new_client.db_ready]="DB ready (client has no access to other clients' DBs)"
MSG_CS[new_client.network_ready]='Síť %s vytvořena, Postgres do ní připojen'
MSG_EN[new_client.network_ready]='Network %s created, Postgres connected to it'
MSG_CS[new_client.compose_generated]='clients/%s/docker-compose.yml vygenerován'
MSG_EN[new_client.compose_generated]='clients/%s/docker-compose.yml generated'
MSG_CS[new_client.starting_n8n]='Spouštím n8n-%s'
MSG_EN[new_client.starting_n8n]='Starting n8n-%s'
MSG_CS[new_client.waiting_n8n]='Čekám na naběhnutí n8n…'
MSG_EN[new_client.waiting_n8n]='Waiting for n8n to come up…'
MSG_CS[new_client.n8n_failed]='n8n-%s nenaběhl (zkontroluj: docker logs n8n-%s)'
MSG_EN[new_client.n8n_failed]='n8n-%s failed to come up (check: docker logs n8n-%s)'
MSG_CS[new_client.n8n_running]='n8n běží'
MSG_EN[new_client.n8n_running]='n8n is running'
MSG_CS[new_client.creating_owner]='Zakládám vlastníka a n8n API klíč'
MSG_EN[new_client.creating_owner]='Setting up the owner and n8n API key'
MSG_CS[new_client.apikey_saved]='n8n API klíč vytvořen a uložen do .env'
MSG_EN[new_client.apikey_saved]='n8n API key created and saved to .env'
MSG_CS[new_client.apikey_failed]='n8n API klíč se nepodařilo vytvořit automaticky — claude-%s poběží bez klíče.'
MSG_EN[new_client.apikey_failed]='Could not create the n8n API key automatically — claude-%s will run without one.'
MSG_CS[new_client.apikey_manual]='Doplň ho ručně: vygeneruj v n8n UI (Settings → API) a zapiš do %s, pak: cd %s && docker compose up -d claude-%s'
MSG_EN[new_client.apikey_manual]='Add it by hand: generate it in the n8n UI (Settings → API) and write it into %s, then: cd %s && docker compose up -d claude-%s'
MSG_CS[new_client.starting_claude]='Spouštím claude-%s (bez docker.sock, jen síť %s)'
MSG_EN[new_client.starting_claude]='Starting claude-%s (no docker.sock, network %s only)'
MSG_CS[new_client.claude_running]='claude-%s běží'
MSG_EN[new_client.claude_running]='claude-%s is running'
MSG_CS[new_client.vhost_for]='Apache vhost pro %s'
MSG_EN[new_client.vhost_for]='Apache vhost for %s'
MSG_CS[new_client.vhost_active]='vhost aktivní (HTTP)'
MSG_EN[new_client.vhost_active]='vhost active (HTTP)'
MSG_CS[new_client.issuing_cert]='Vydávám HTTPS certifikát (certbot --apache)'
MSG_EN[new_client.issuing_cert]='Issuing an HTTPS certificate (certbot --apache)'
MSG_CS[new_client.cert_issued]='Certifikát vydán, HTTPS + redirect aktivní'
MSG_EN[new_client.cert_issued]='Certificate issued, HTTPS + redirect active'
MSG_CS[new_client.certbot_failed]='certbot selhal. Nejčastější příčina: DNS pro %s neukazuje na tento server.'
MSG_EN[new_client.certbot_failed]="certbot failed. Most common cause: DNS for %s doesn't point at this server."
MSG_CS[new_client.certbot_check_dns]="Zkontroluj prosím: 'dig +short %s' musí vrátit veřejnou IP tohoto serveru."
MSG_EN[new_client.certbot_check_dns]="Please check: 'dig +short %s' must return this server's public IP."
MSG_CS[new_client.certbot_detail]='Detail: /tmp/certbot-%s.log — po opravě spusť: certbot --apache -d %s --redirect'
MSG_EN[new_client.certbot_detail]='Details: /tmp/certbot-%s.log — once fixed, run: certbot --apache -d %s --redirect'
MSG_CS[new_client.written_to_clients_md]='Zapsáno do clients.md'
MSG_EN[new_client.written_to_clients_md]='Written to clients.md'
MSG_CS[new_client.summary_title]="Klient '%s' založen."
MSG_EN[new_client.summary_title]="Client '%s' set up."
MSG_CS[new_client.summary_url]='  URL n8n     : %s'
MSG_EN[new_client.summary_url]='  n8n URL       : %s'
MSG_CS[new_client.summary_port]='  n8n port    : 127.0.0.1:%s (jen loopback, ven přes Apache)'
MSG_EN[new_client.summary_port]='  n8n port      : 127.0.0.1:%s (loopback only, exposed via Apache)'
MSG_CS[new_client.summary_net]='  Síť         : %s (izolovaná)'
MSG_EN[new_client.summary_net]='  Network       : %s (isolated)'
MSG_CS[new_client.summary_db]='  DB / user   : %s / %s'
MSG_EN[new_client.summary_db]='  DB / user     : %s / %s'
MSG_CS[new_client.summary_owner]='  n8n vlastník: %s  (heslo v %s)'
MSG_EN[new_client.summary_owner]='  n8n owner     : %s  (password in %s)'
MSG_CS[new_client.summary_claude_prefix]='  claude-%s: běží; remote-control '
MSG_EN[new_client.summary_claude_prefix]='  claude-%s: running; remote-control '
MSG_CS[new_client.summary_rc_ready]='ready (sdílené claude.ai přihlášení)'
MSG_EN[new_client.summary_rc_ready]='ready (shared claude.ai login)'
MSG_CS[new_client.summary_rc_waiting]='čeká na claude.ai přihlášení (viz OPS.md)'
MSG_EN[new_client.summary_rc_waiting]='waiting for claude.ai login (see OPS.md)'

CLIENT="${1:-}"
[ -n "$CLIENT" ] || die "$(msg new_client.usage)"
validate_name "$CLIENT"
ensure_dirs
ensure_clients_md
ensure_catchall_vhost
client_exists "$CLIENT" && die "$(msg new_client.already_exists "$CLIENT")"
docker ps -a --format '{{.Names}}' | grep -qx "n8n-$CLIENT" && die "$(msg new_client.container_exists "$CLIENT")"

SUBDOMAIN="$CLIENT.$DOMAIN"
CDIR="$CLIENTS_DIR/$CLIENT"
NET="net-$CLIENT"
DB="db_$CLIENT"; DBUSER="u_$CLIENT"
N8N_PORT="$(find_free_port)"
DB_PASSWORD="$(gen_secret 40 40)"
N8N_ENCRYPTION_KEY="$(gen_secret 40 40)"
OWNER_EMAIL="owner@$SUBDOMAIN"
OWNER_PASSWORD="$(gen_secret 24 20)Aa1!"     # satisfies n8n's password policy
ANTHROPIC_API_KEY="$(grep -E '^ANTHROPIC_API_KEY=' "$ROOT/.env" | cut -d= -f2-)"
[ -n "$ANTHROPIC_API_KEY" ] || warn "$(msg new_client.empty_api_key "$CLIENT")"

say "$(msg new_client.founding "$CLIENT" "https://$SUBDOMAIN" "$N8N_PORT")"
mkdir -p "$CDIR/backups" "$CDIR/apps"

# --- 1) Postgres: DB + user scoped to its own DB only ---
say "$(msg new_client.postgres_setup "$DBUSER" "$DB")"
psql_super <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='$DBUSER') THEN
    CREATE ROLE $DBUSER LOGIN PASSWORD '$DB_PASSWORD';
  ELSE
    ALTER ROLE $DBUSER LOGIN PASSWORD '$DB_PASSWORD';
  END IF;
END \$\$;
SQL
# CREATE DATABASE doesn't work inside a DO block / transaction — handle existence separately
if ! psql_super -tAc "SELECT 1 FROM pg_database WHERE datname='$DB'" | grep -q 1; then
  psql_super -c "CREATE DATABASE $DB OWNER $DBUSER;"
fi
psql_super -c "REVOKE CONNECT ON DATABASE $DB FROM PUBLIC;"
psql_super -c "GRANT CONNECT ON DATABASE $DB TO $DBUSER;"
psql_super -c "ALTER DATABASE $DB OWNER TO $DBUSER;"
ok "$(msg new_client.db_ready)"

# --- 2) network + connect Postgres into it ---
docker network inspect "$NET" >/dev/null 2>&1 || docker network create --driver bridge "$NET" >/dev/null
docker network connect "$NET" "$PG_CONTAINER" 2>/dev/null || true
ok "$(msg new_client.network_ready "$NET")"

# --- 3) client .env (outside git) ---
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

# --- 4) docker-compose from the template (secret placeholders stay for .env) ---
CLIENT="$CLIENT" SUBDOMAIN="$SUBDOMAIN" N8N_PORT="$N8N_PORT" \
  envsubst '$CLIENT $SUBDOMAIN $N8N_PORT $N8N_MTS_LANG' \
  < "$TEMPLATES/docker-compose.yml.tmpl" > "$CDIR/docker-compose.yml"
ok "$(msg new_client.compose_generated "$CLIENT")"

# --- 5) claude-agent image (build if missing or changed) ---
ensure_image "n8n-mts/claude-agent" "$ROOT/docker/claude-agent"

# --- 6) start n8n and wait for it to come up ---
say "$(msg new_client.starting_n8n "$CLIENT")"
( cd "$CDIR" && docker compose up -d "n8n-$CLIENT" >/dev/null )
BASE="http://127.0.0.1:$N8N_PORT"
say "$(msg new_client.waiting_n8n)"
for i in $(seq 1 60); do
  curl -fsS "$BASE/healthz" >/dev/null 2>&1 && break
  sleep 2
  [ "$i" = 60 ] && die "$(msg new_client.n8n_failed "$CLIENT" "$CLIENT")"
done
ok "$(msg new_client.n8n_running)"

# --- 7) n8n API key scoped to this instance ---
say "$(msg new_client.creating_owner)"
N8N_API_KEY="$("$DIR/n8n-apikey.sh" "$BASE" "$OWNER_EMAIL" "$OWNER_PASSWORD" "ops-provisioned-claude-$CLIENT" || true)"
if [ -n "$N8N_API_KEY" ]; then
  sed -i "s|^N8N_API_KEY=.*|N8N_API_KEY=$N8N_API_KEY|" "$CDIR/.env"
  ok "$(msg new_client.apikey_saved)"
else
  warn "$(msg new_client.apikey_failed "$CLIENT")"
  warn "$(msg new_client.apikey_manual "$CDIR/.env" "$CDIR" "$CLIENT")"
fi

# --- 8) start claude-{client} ---
say "$(msg new_client.starting_claude "$CLIENT" "$NET")"
( cd "$CDIR" && docker compose up -d "claude-$CLIENT" >/dev/null )
ok "$(msg new_client.claude_running "$CLIENT")"

# --- 9) Apache vhost + certificate ---
say "$(msg new_client.vhost_for "$SUBDOMAIN")"
VHOST="/etc/apache2/sites-available/$CLIENT.conf"
CLIENT="$CLIENT" SUBDOMAIN="$SUBDOMAIN" N8N_PORT="$N8N_PORT" \
  envsubst '$CLIENT $SUBDOMAIN $N8N_PORT' \
  < "$TEMPLATES/vhost.conf.tmpl" > "$VHOST"
a2ensite "$CLIENT.conf" >/dev/null
apache2ctl configtest && systemctl reload apache2
ok "$(msg new_client.vhost_active)"

say "$(msg new_client.issuing_cert)"
# the redirect is handled in the vhost template (RewriteCond HTTPS off), hence --no-redirect
if certbot --apache -d "$SUBDOMAIN" --non-interactive --agree-tos \
      -m "$CERTBOT_EMAIL" --no-redirect >/tmp/certbot-$CLIENT.log 2>&1; then
  ok "$(msg new_client.cert_issued)"
  CERT_OK=1
else
  warn "$(msg new_client.certbot_failed "$SUBDOMAIN")"
  warn "$(msg new_client.certbot_check_dns "$SUBDOMAIN")"
  warn "$(msg new_client.certbot_detail "$CLIENT" "$SUBDOMAIN")"
  CERT_OK=0
fi

# --- 10) record in clients.md ---
TODAY="$(date +%F)"
printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
  "$CLIENT" "$SUBDOMAIN" "$N8N_PORT" "$NET" "$DB" "$DBUSER" "$TODAY" "" "active" >> "$CLIENTS_MD"
ok "$(msg new_client.written_to_clients_md)"

# --- summary ---
echo
echo "──────────────────────────────────────────────"
ok "$(msg new_client.summary_title "$CLIENT")"
echo "$(msg new_client.summary_url "$([ "${CERT_OK:-0}" = 1 ] && echo https || echo http)://$SUBDOMAIN")"
echo "$(msg new_client.summary_port "$N8N_PORT")"
echo "$(msg new_client.summary_net "$NET")"
echo "$(msg new_client.summary_db "$DB" "$DBUSER")"
echo "$(msg new_client.summary_owner "$OWNER_EMAIL" "$CDIR/.env")"
echo -n "$(msg new_client.summary_claude_prefix "$CLIENT")"
if [ -f "$ROOT/claude-auth/.credentials.json" ]; then echo "$(msg new_client.summary_rc_ready)"; else echo "$(msg new_client.summary_rc_waiting)"; fi
echo "──────────────────────────────────────────────"
