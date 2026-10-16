#!/usr/bin/env bash
# backup-clients.sh [client] — backs up every client whose clients.md
# Stav is "active" (or just the one given, regardless of its status)
# into a single archive per run:
#
#   clients/{client}/backups/{client}-{STAMP}.tar.gz
#     db.dump    - pg_dump -Fc (custom format, restore with pg_restore —
#                  handles DROP/CREATE of individual objects cleanly,
#                  unlike a plain SQL dump loaded into a populated DB)
#     files/     - full copy of clients/{client}/ (everything except
#                  backups/ itself): .env (N8N_ENCRYPTION_KEY), apps/*/code/,
#                  compose files — losing the disk loses this, a DB dump
#                  alone does not cover it
#     volumes/*.tar - docker volumes (n8n's own data dir, the client
#                  agent's workspace), snapshotted read-only via a
#                  throwaway container
#     MANIFEST   - what's inside, when, from where
#
# Runs daily via /etc/cron.d/n8n-mts-backup (see lib.sh's
# ensure_backup_cron, installed by both new-client.sh and
# deploy-ops.sh). Exits non-zero if ANY client's backup failed, so a
# cron failure is actually visible — an earlier version of this script
# always exited 0 even on failure, see sysadmin-claude's 2026-10-16
# audit (it also found the predecessor to this script never backed up
# volumes or app code at all, and wrote backups world-readable despite
# the DB dump holding password hashes and encrypted credentials — both
# fixed below).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh"
require_root
umask 077

MSG_CS[backup_clients.backing_up]='Zálohuji klienta %s'
MSG_EN[backup_clients.backing_up]='Backing up client %s'
MSG_CS[backup_clients.pg_down]='Postgres neodpovídá, záloha %s přeskočena'
MSG_EN[backup_clients.pg_down]="Postgres isn't responding, backup of %s skipped"
MSG_CS[backup_clients.pgdump_failed]='pg_dump pro %s selhal nebo vrátil prázdný výstup'
MSG_EN[backup_clients.pgdump_failed]='pg_dump for %s failed or returned empty output'
MSG_CS[backup_clients.files_failed]='Kopie adresáře klienta %s selhala'
MSG_EN[backup_clients.files_failed]="Copying client %s's directory failed"
MSG_CS[backup_clients.volume_failed]='Záloha volume %s (klient %s) selhala'
MSG_EN[backup_clients.volume_failed]='Backing up volume %s (client %s) failed'
MSG_CS[backup_clients.archive_failed]='Sestavení archivu pro %s selhalo'
MSG_EN[backup_clients.archive_failed]='Assembling the archive for %s failed'
MSG_CS[backup_clients.no_clients]='Žádní aktivní klienti v clients.md, není co zálohovat.'
MSG_EN[backup_clients.no_clients]='No active clients in clients.md, nothing to back up.'
MSG_CS[backup_clients.done]='Hotovo: %s/%s klient(ů) zazálohováno do clients/{client}/backups/'
MSG_EN[backup_clients.done]='Done: %s/%s client(s) backed up into clients/{client}/backups/'
MSG_CS[backup_clients.failures]='%s klient(ů) se zazálohovat nepodařilo — viz varování výš'
MSG_EN[backup_clients.failures]='%s client(s) failed to back up — see warnings above'

KEEP="${BACKUP_KEEP:-14}"   # how many most recent archives to keep per client

backup_one() {
  local CLIENT="$1"
  local CDIR="$CLIENTS_DIR/$CLIENT"
  local BDIR="$CDIR/backups"
  local DB="db_$CLIENT"
  local STAMP WORK
  STAMP="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BDIR"
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' RETURN

  if ! docker exec "$PG_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then
    warn "$(msg backup_clients.pg_down "$CLIENT")"
    return 1
  fi
  if ! docker exec "$PG_CONTAINER" pg_dump -U postgres -Fc "$DB" > "$WORK/db.dump" 2>/dev/null \
     || [ ! -s "$WORK/db.dump" ]; then
    warn "$(msg backup_clients.pgdump_failed "$CLIENT")"
    return 1
  fi

  mkdir -p "$WORK/files"
  if ! tar -C "$CDIR" --exclude='./backups' -cf - . 2>/dev/null | tar -C "$WORK/files" -xf -; then
    warn "$(msg backup_clients.files_failed "$CLIENT")"
    return 1
  fi

  mkdir -p "$WORK/volumes"
  local V
  for V in "n8n-$CLIENT-data" "claude-$CLIENT-workspace"; do
    if docker volume inspect "$V" >/dev/null 2>&1; then
      if ! docker run --rm -v "$V":/v:ro postgres:16 tar -C /v -cf - . > "$WORK/volumes/$V.tar" 2>/dev/null \
         || [ ! -s "$WORK/volumes/$V.tar" ]; then
        warn "$(msg backup_clients.volume_failed "$V" "$CLIENT")"
        return 1
      fi
    fi
  done

  {
    echo "client=$CLIENT"
    echo "stamp=$STAMP"
    echo "db=$DB"
  } > "$WORK/MANIFEST"

  local ARCHIVE="$BDIR/$CLIENT-$STAMP.tar.gz"
  if ! tar -C "$WORK" -czf "$ARCHIVE.part" db.dump files volumes MANIFEST 2>/dev/null \
     || ! gzip -t "$ARCHIVE.part" 2>/dev/null; then
    rm -f "$ARCHIVE.part"
    warn "$(msg backup_clients.archive_failed "$CLIENT")"
    return 1
  fi
  chmod 600 "$ARCHIVE.part"
  mv "$ARCHIVE.part" "$ARCHIVE"

  # rotation: keep only the $KEEP most recent archives for this client
  ls -1t "$BDIR/$CLIENT"-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
}

if [ -n "${1:-}" ]; then
  CLIENTS="$1"
else
  CLIENTS="$(awk -F'|' '{
    c=$2; s=$10
    gsub(/^[ \t]+|[ \t]+$/,"",c)
    gsub(/^[ \t]+|[ \t]+$/,"",s)
    if (c ~ /^[a-z0-9][a-z0-9-]*$/ && s=="active") print c
  }' "$CLIENTS_MD" 2>/dev/null || true)"
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

ok "$(msg backup_clients.done "$OK" "$TOTAL")"
if [ "$OK" -ne "$TOTAL" ]; then
  err "$(msg backup_clients.failures "$((TOTAL - OK))")"
  exit 1
fi
