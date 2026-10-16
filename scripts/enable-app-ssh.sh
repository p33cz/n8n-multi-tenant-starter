#!/usr/bin/env bash
# enable-app-ssh.sh <client> <app> — turns on SSH deploy access for an
# app (for an n8n workflow, which doesn't have a bind mount like
# claude-{client} does). Generates a password, writes it to the app's
# .env, and recreates the app so the entrypoint picks it up. Reachable
# only from net-{client}, never from outside.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh"
require_root

MSG_CS[enable_app_ssh.usage]='Použití: enable-app-ssh.sh <klient> <appka>'
MSG_EN[enable_app_ssh.usage]='Usage: enable-app-ssh.sh <client> <app>'
MSG_CS[enable_app_ssh.no_app]="Appka '%s' (klient '%s') neexistuje — nejdřív ./scripts/new-app.sh %s %s"
MSG_EN[enable_app_ssh.no_app]="App '%s' (client '%s') doesn't exist — run ./scripts/new-app.sh %s %s first"
MSG_CS[enable_app_ssh.recreating]='Recreatuji app-%s-%s se zapnutým SSH'
MSG_EN[enable_app_ssh.recreating]='Recreating app-%s-%s with SSH turned on'
MSG_CS[enable_app_ssh.enabled]='SSH deploy přístup zapnutý'
MSG_EN[enable_app_ssh.enabled]='SSH deploy access turned on'
MSG_CS[enable_app_ssh.summary_host]='  Host      : app-%s-%s  (dosažitelné jen z net-%s, ne zvenku)'
MSG_EN[enable_app_ssh.summary_host]='  Host      : app-%s-%s  (reachable only from net-%s, not from outside)'
MSG_CS[enable_app_ssh.summary_port]='  Port      : 22'
MSG_EN[enable_app_ssh.summary_port]='  Port      : 22'
MSG_CS[enable_app_ssh.summary_user]='  Uživatel  : appdeploy'
MSG_EN[enable_app_ssh.summary_user]='  User      : appdeploy'
MSG_CS[enable_app_ssh.summary_password]='  Heslo     : %s'
MSG_EN[enable_app_ssh.summary_password]='  Password  : %s'
MSG_CS[enable_app_ssh.summary_scope]='  Rozsah    : appdeploy je ve svém vlastním kontejneru appky, bez cizích dat — žádný chroot není potřeba'
MSG_EN[enable_app_ssh.summary_scope]="  Scope     : appdeploy sits in this app's own container, with no other data in it — no chroot needed"
MSG_CS[enable_app_ssh.footer]='Tyhle údaje zapiš do n8n SSH credential (typ heslo) workflow, co má appku plnit.'
MSG_EN[enable_app_ssh.footer]="Enter these into an n8n SSH credential (password type) for the workflow that will fill the app."

CLIENT="${1:-}"; APPKA="${2:-}"
[ -n "$CLIENT" ] && [ -n "$APPKA" ] || die "$(msg enable_app_ssh.usage)"
validate_name "$CLIENT"
validate_name "$APPKA"
ADIR="$CLIENTS_DIR/$CLIENT/apps/$APPKA"
[ -f "$ADIR/.env" ] || die "$(msg enable_app_ssh.no_app "$APPKA" "$CLIENT" "$CLIENT" "$APPKA")"

PASSWORD="$(gen_secret 32 32)"
sed -i "s|^ENABLE_SSH=.*|ENABLE_SSH=1|" "$ADIR/.env"
sed -i "s|^APP_SSH_PASSWORD=.*|APP_SSH_PASSWORD=$PASSWORD|" "$ADIR/.env"

say "$(msg enable_app_ssh.recreating "$CLIENT" "$APPKA")"
( cd "$ADIR" && docker compose up -d --force-recreate >/dev/null )
ok "$(msg enable_app_ssh.enabled)"

echo
echo "──────────────────────────────────────────────"
echo "$(msg enable_app_ssh.summary_host "$CLIENT" "$APPKA" "$CLIENT")"
echo "$(msg enable_app_ssh.summary_port)"
echo "$(msg enable_app_ssh.summary_user)"
echo "$(msg enable_app_ssh.summary_password "$PASSWORD")"
echo "$(msg enable_app_ssh.summary_scope)"
echo "──────────────────────────────────────────────"
echo "$(msg enable_app_ssh.footer)"
