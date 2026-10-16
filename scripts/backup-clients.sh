#!/usr/bin/env bash
# backup-clients.sh [client] — backs up every active client (or just
# the one given): a gzipped DB dump + a copy of .env (holds
# N8N_ENCRYPTION_KEY, required to decrypt credentials in that dump on
# restore) into clients/{client}/backups/, with rotation.
#
# Runs daily via /etc/cron.d/n8n-mts-backup (see lib.sh's
# ensure_backup_cron, installed by new-client.sh), and can be run by
# hand any time for an immediate backup. Restore procedure: see
# "Backups and restore" in docs/guide.en.md (docs/navod.md in Czech).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh"
require_root

MSG_CS[backup_clients.backing_up]='Zálohuji klienta %s'
MSG_EN[backup_clients.backing_up]='Backing up client %s'
MSG_CS[backup_clients.pgdump_failed]='pg_dump pro %s selhal nebo vrátil prázdný výstup — záloha přeskočena'
MSG_EN[backup_clients.pgdump_failed]='pg_dump for %s failed or returned empty output — backup skipped'
MSG_CS[backup_clients.no_clients]='Žádní klienti v clients.md, není co zálohovat.'
MSG_EN[backup_clients.no_clients]='No clients in clients.md, nothing to back up.'
MSG_CS[backup_clients.done]='Hotovo: %s/%s klient(ů) zazálohováno do %s'
MSG_EN[backup_clients.done]='Done: %s/%s client(s) backed up into %s'

KEEP="${BACKUP_KEEP:-7}"   # how many most recent backups to keep per client

backup_one() {
  local CLIENT="$1"
  local CDIR="$CLIENTS_DIR/$CLIENT"
  local BDIR="$CDIR/backups"
  local DB="db_$CLIENT"
  local STAMP
  STAMP="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BDIR"

  if ! docker exec "$PG_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then
    warn "$(msg backup_clients.pgdump_failed "$CLIENT")"
    return 1
  fi
  if ! docker exec "$PG_CONTAINER" pg_dump -U postgres "$DB" 2>/dev/null | gzip > "$BDIR/$STAMP.sql.gz" \
     || [ ! -s "$BDIR/$STAMP.sql.gz" ]; then
    warn "$(msg backup_clients.pgdump_failed "$CLIENT")"
    rm -f "$BDIR/$STAMP.sql.gz"
    return 1
  fi
  [ -f "$CDIR/.env" ] && cp "$CDIR/.env" "$BDIR/$STAMP.env.bak"

  # rotation: keep only the $KEEP most recent dumps (and their matching .env.bak)
  ls -1t "$BDIR"/*.sql.gz 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
    rm -f "$old" "${old%.sql.gz}.env.bak"
  done
}

if [ -n "${1:-}" ]; then
  CLIENTS="$1"
else
  CLIENTS="$(grep -oP '^\| \K[a-z0-9][a-z0-9-]*(?= )' "$CLIENTS_MD" 2>/dev/null || true)"
fi

if [ -z "$CLIENTS" ]; then
  warn "$(msg backup_clients.no_clients)"
  exit 0
fi

TOTAL=0 OK=0
for CLIENT in $CLIENTS; do
  TOTAL=$((TOTAL + 1))
  say "$(msg backup_clients.backing_up "$CLIENT")"
  backup_one "$CLIENT" && OK=$((OK + 1))
done

ok "$(msg backup_clients.done "$OK" "$TOTAL" "$CLIENTS_DIR/{client}/backups/")"
