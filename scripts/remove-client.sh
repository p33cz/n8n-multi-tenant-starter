#!/usr/bin/env bash
# remove-client.sh <name> — removes a client:
#   dumps the DB to the archive, moves usage.log to the archive (usage
#   history is kept), stops+removes both containers, disconnects
#   Postgres from the network, removes the network, drops the DB+user,
#   removes the Apache vhost and its Let's Encrypt certificate, drops
#   the row from clients.md.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh"
require_root

MSG_CS[remove_client.usage]='Použití: remove-client.sh <jmeno>'
MSG_EN[remove_client.usage]='Usage: remove-client.sh <name>'
MSG_CS[remove_client.not_in_md]="Klient '%s' není v clients.md — pokusím se uklidit i tak."
MSG_EN[remove_client.not_in_md]="Client '%s' isn't in clients.md — I'll try to clean up anyway."
MSG_CS[remove_client.has_app]="Klient má appku '%s' — ruším ji nejdřív"
MSG_EN[remove_client.has_app]="Client has app '%s' — removing it first"
MSG_CS[remove_client.app_remove_failed]="remove-app.sh selhal pro appku '%s'"
MSG_EN[remove_client.app_remove_failed]="remove-app.sh failed for app '%s'"
MSG_CS[remove_client.backing_up_db]='Zálohuji databázi %s → %s'
MSG_EN[remove_client.backing_up_db]='Backing up database %s → %s'
MSG_CS[remove_client.pgdump_failed]='pg_dump selhal (DB možná neexistuje)'
MSG_EN[remove_client.pgdump_failed]="pg_dump failed (the DB may not exist)"
MSG_CS[remove_client.usage_log_moved]='usage.log přesunut do archivu (historie spotřeby zachována)'
MSG_EN[remove_client.usage_log_moved]='usage.log moved to the archive (usage history kept)'
MSG_CS[remove_client.stopping_containers]='Zastavuji a mažu kontejnery klienta'
MSG_EN[remove_client.stopping_containers]="Stopping and removing the client's containers"
MSG_CS[remove_client.network_removed]='Síť %s odstraněna'
MSG_EN[remove_client.network_removed]='Network %s removed'
MSG_CS[remove_client.drop_db_failed]='DROP DATABASE %s selhal'
MSG_EN[remove_client.drop_db_failed]='DROP DATABASE %s failed'
MSG_CS[remove_client.db_removed]='DB %s a uživatel %s smazáni'
MSG_EN[remove_client.db_removed]='DB %s and user %s removed'
MSG_CS[remove_client.vhost_removed]='Apache vhost odstraněn'
MSG_EN[remove_client.vhost_removed]='Apache vhost removed'
MSG_CS[remove_client.configtest_failed]='apache2ctl configtest selhal po úklidu vhostu — reload přeskočen, zkontroluj ručně'
MSG_EN[remove_client.configtest_failed]='apache2ctl configtest failed after vhost cleanup — reload skipped, check manually'
MSG_CS[remove_client.cert_removed]='Certifikát %s smazán (certbot delete)'
MSG_EN[remove_client.cert_removed]='Certificate %s removed (certbot delete)'
MSG_CS[remove_client.cert_remove_failed]='certbot delete pro %s selhalo — zkontroluj ručně (certbot certificates)'
MSG_EN[remove_client.cert_remove_failed]='certbot delete for %s failed — check manually (certbot certificates)'
MSG_CS[remove_client.done]="Klient '%s' zrušen. Archiv (DB dump + usage.log): %s"
MSG_EN[remove_client.done]="Client '%s' removed. Archive (DB dump + usage.log): %s"

CLIENT="${1:-}"
[ -n "$CLIENT" ] || die "$(msg remove_client.usage)"
validate_name "$CLIENT"
CDIR="$CLIENTS_DIR/$CLIENT"
NET="net-$CLIENT"; DB="db_$CLIENT"; DBUSER="u_$CLIENT"
STAMP="$(date +%Y%m%d-%H%M%S)"
ADIR="$ARCHIVE_DIR/${CLIENT}-${STAMP}"

client_exists "$CLIENT" || warn "$(msg remove_client.not_in_md "$CLIENT")"
mkdir -p "$ADIR"

# --- 0) remove all of the client's apps first ---
# Otherwise they'd be left orphaned (container keeps running, vhost
# stays) and net-{client} couldn't even be removed while an app is
# still connected to it.
if [ -f "$APPS_MD" ]; then
  for APPKA in $(awk -F'|' -v c="$CLIENT" '{gsub(/^[ \t]+|[ \t]+$/,"",$2); gsub(/^[ \t]+|[ \t]+$/,"",$3); if ($2==c) print $3}' "$APPS_MD"); do
    say "$(msg remove_client.has_app "$APPKA")"
    "$DIR/remove-app.sh" "$CLIENT" "$APPKA" || warn "$(msg remove_client.app_remove_failed "$APPKA")"
  done
fi

# --- 1) back up via a DB dump ---
if docker exec "$PG_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then
  say "$(msg remove_client.backing_up_db "$DB" "$ADIR/$DB.sql.gz")"
  docker exec "$PG_CONTAINER" pg_dump -U postgres "$DB" 2>/dev/null | gzip > "$ADIR/$DB.sql.gz" || warn "$(msg remove_client.pgdump_failed)"
fi

# --- 2) do NOT delete usage.log — move it to the archive ---
if [ -f "$CDIR/usage.log" ]; then
  mv "$CDIR/usage.log" "$ADIR/usage.log"
  ok "$(msg remove_client.usage_log_moved)"
fi
[ -f "$CDIR/.env" ] && cp "$CDIR/.env" "$ADIR/.env.bak" || true

# --- 3) stop and remove containers + volumes ---
if [ -f "$CDIR/docker-compose.yml" ]; then
  say "$(msg remove_client.stopping_containers)"
  ( cd "$CDIR" && docker compose down -v >/dev/null 2>&1 ) || true
fi
docker rm -f "n8n-$CLIENT" "claude-$CLIENT" >/dev/null 2>&1 || true

# --- 4) disconnect Postgres from the network and remove the network ---
docker network disconnect "$NET" "$PG_CONTAINER" >/dev/null 2>&1 || true
docker network rm "$NET" >/dev/null 2>&1 || true
ok "$(msg remove_client.network_removed "$NET")"

# --- 5) drop DB + user ---
if docker exec "$PG_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then
  psql_super -c "DROP DATABASE IF EXISTS $DB;" >/dev/null 2>&1 || warn "$(msg remove_client.drop_db_failed "$DB")"
  psql_super -c "DROP ROLE IF EXISTS $DBUSER;" >/dev/null 2>&1 || true
  ok "$(msg remove_client.db_removed "$DB" "$DBUSER")"
fi

# --- 6) Apache vhost ---
# certbot's apache plugin enables its own *-le-ssl.conf site alongside
# the http one — clean each up INDEPENDENTLY of the other. A partial
# earlier run can leave just one behind (found by sysadmin-claude's
# 2026-10-16 audit: test1 had a dangling *-le-ssl.conf symlink because
# the base .conf was already gone, and nesting this cleanup inside "if
# the base .conf exists" meant it never ran).
VHOST_CHANGED=0
for V in "$CLIENT.conf" "$CLIENT-le-ssl.conf"; do
  if [ -f "/etc/apache2/sites-available/$V" ] || [ -L "/etc/apache2/sites-enabled/$V" ]; then
    a2dissite "$V" >/dev/null 2>&1 || true
    rm -f "/etc/apache2/sites-available/$V" "/etc/apache2/sites-enabled/$V"
    VHOST_CHANGED=1
  fi
done
if [ "$VHOST_CHANGED" = "1" ]; then
  if apache2ctl configtest 2>/dev/null; then
    systemctl reload apache2 2>/dev/null || true
    ok "$(msg remove_client.vhost_removed)"
  else
    warn "$(msg remove_client.configtest_failed)"
  fi
fi

# --- 6b) Let's Encrypt certificate ---
# certbot was invoked with -d "$SUBDOMAIN" and no --cert-name, so the
# lineage is named after the subdomain itself. Leaving it behind after
# the vhost is gone makes its renewal fail (and clutters certbot renew
# output for every other client too).
if certbot certificates --cert-name "$CLIENT.$DOMAIN" 2>/dev/null | grep -q "Certificate Name"; then
  if certbot delete --cert-name "$CLIENT.$DOMAIN" --non-interactive >/dev/null 2>&1; then
    ok "$(msg remove_client.cert_removed "$CLIENT.$DOMAIN")"
  else
    warn "$(msg remove_client.cert_remove_failed "$CLIENT.$DOMAIN")"
  fi
fi

# --- 7) drop from clients.md, archive the client directory ---
if [ -f "$CLIENTS_MD" ]; then
  grep -v "^| $CLIENT " "$CLIENTS_MD" > "$CLIENTS_MD.tmp" && mv "$CLIENTS_MD.tmp" "$CLIENTS_MD"
fi
if [ -d "$CDIR" ]; then
  mv "$CDIR" "$ADIR/client-dir" 2>/dev/null || rm -rf "$CDIR"
fi

echo
ok "$(msg remove_client.done "$CLIENT" "$ADIR")"
