#!/usr/bin/env bash
# enable-app-ssh.sh <klient> <appka> — zapne appce SSH deploy přístup
# (pro n8n workflow, který nemá bind mount jako claude-{klient}).
# Vygeneruje heslo, zapíše ho do .env appky a appku recreatne, ať ho
# entrypoint zvedne. Dosažitelné jen z net-{klient}, nikdy zvenku.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh"
require_root

CLIENT="${1:-}"; APPKA="${2:-}"
[ -n "$CLIENT" ] && [ -n "$APPKA" ] || die "Použití: enable-app-ssh.sh <klient> <appka>"
validate_name "$CLIENT"
validate_name "$APPKA"
ADIR="$CLIENTS_DIR/$CLIENT/apps/$APPKA"
[ -f "$ADIR/.env" ] || die "Appka '$APPKA' (klient '$CLIENT') neexistuje — nejdřív ./scripts/new-app.sh $CLIENT $APPKA"

PASSWORD="$(gen_secret 32 32)"
sed -i "s|^ENABLE_SSH=.*|ENABLE_SSH=1|" "$ADIR/.env"
sed -i "s|^APP_SSH_PASSWORD=.*|APP_SSH_PASSWORD=$PASSWORD|" "$ADIR/.env"

say "Recreatuji app-$CLIENT-$APPKA se zapnutým SSH"
( cd "$ADIR" && docker compose up -d --force-recreate >/dev/null )
ok "SSH deploy přístup zapnutý"

echo
echo "──────────────────────────────────────────────"
echo "  Host      : app-$CLIENT-$APPKA  (dosažitelné jen z net-$CLIENT, ne zvenku)"
echo "  Port      : 22"
echo "  Uživatel  : appdeploy"
echo "  Heslo     : $PASSWORD"
echo "  Chroot    : appdeploy vidí jen kód téhle appky (code/), nic jiného"
echo "──────────────────────────────────────────────"
echo "Tyhle údaje zapiš do n8n SSH credential (typ heslo) workflow, co má appku plnit."
