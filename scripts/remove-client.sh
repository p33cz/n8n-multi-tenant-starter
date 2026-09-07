#!/usr/bin/env bash
# remove-client.sh <jmeno> — zruší klienta:
#   dump DB do archivu, přesun usage.log do archivu (historie spotřeby zůstává),
#   zastavení+smazání obou kontejnerů, odpojení Postgresu ze sítě, smazání sítě,
#   smazání DB+uživatele, odebrání Apache vhostu, vyřazení z clients.md.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh"
require_root

CLIENT="${1:-}"
[ -n "$CLIENT" ] || die "Použití: remove-client.sh <jmeno>"
validate_name "$CLIENT"
CDIR="$CLIENTS_DIR/$CLIENT"
NET="net-$CLIENT"; DB="db_$CLIENT"; DBUSER="u_$CLIENT"
STAMP="$(date +%Y%m%d-%H%M%S)"
ADIR="$ARCHIVE_DIR/${CLIENT}-${STAMP}"

client_exists "$CLIENT" || warn "Klient '$CLIENT' není v clients.md — pokusím se uklidit i tak."
mkdir -p "$ADIR"

# --- 1) záloha DB dumpem ---
if docker exec "$PG_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then
  say "Zálohuji databázi $DB → $ADIR/$DB.sql.gz"
  docker exec "$PG_CONTAINER" pg_dump -U postgres "$DB" 2>/dev/null | gzip > "$ADIR/$DB.sql.gz" || warn "pg_dump selhal (DB možná neexistuje)"
fi

# --- 2) usage.log NEMAZAT — přesun do archivu ---
if [ -f "$CDIR/usage.log" ]; then
  mv "$CDIR/usage.log" "$ADIR/usage.log"
  ok "usage.log přesunut do archivu (historie spotřeby zachována)"
fi
[ -f "$CDIR/.env" ] && cp "$CDIR/.env" "$ADIR/.env.bak" || true

# --- 3) zastav a smaž kontejnery + volumes ---
if [ -f "$CDIR/docker-compose.yml" ]; then
  say "Zastavuji a mažu kontejnery klienta"
  ( cd "$CDIR" && docker compose down -v >/dev/null 2>&1 ) || true
fi
docker rm -f "n8n-$CLIENT" "claude-$CLIENT" >/dev/null 2>&1 || true

# --- 4) odpoj Postgres ze sítě a smaž síť ---
docker network disconnect "$NET" "$PG_CONTAINER" >/dev/null 2>&1 || true
docker network rm "$NET" >/dev/null 2>&1 || true
ok "Síť $NET odstraněna"

# --- 5) smaž DB + uživatele ---
if docker exec "$PG_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then
  psql_super -c "DROP DATABASE IF EXISTS $DB;" >/dev/null 2>&1 || warn "DROP DATABASE $DB selhal"
  psql_super -c "DROP ROLE IF EXISTS $DBUSER;" >/dev/null 2>&1 || true
  ok "DB $DB a uživatel $DBUSER smazáni"
fi

# --- 6) Apache vhost ---
if [ -f "/etc/apache2/sites-available/$CLIENT.conf" ]; then
  a2dissite "$CLIENT.conf" >/dev/null 2>&1 || true
  rm -f "/etc/apache2/sites-available/$CLIENT.conf" "/etc/apache2/sites-available/$CLIENT-le-ssl.conf"
  systemctl reload apache2 2>/dev/null || true
  ok "Apache vhost odstraněn (certifikát v /etc/letsencrypt ponechán)"
fi

# --- 7) vyřaď z clients.md, archivuj složku klienta ---
if [ -f "$CLIENTS_MD" ]; then
  grep -v "^| $CLIENT " "$CLIENTS_MD" > "$CLIENTS_MD.tmp" && mv "$CLIENTS_MD.tmp" "$CLIENTS_MD"
fi
if [ -d "$CDIR" ]; then
  mv "$CDIR" "$ADIR/client-dir" 2>/dev/null || rm -rf "$CDIR"
fi

echo
ok "Klient '$CLIENT' zrušen. Archiv (DB dump + usage.log): $ADIR"
