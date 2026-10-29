#!/usr/bin/env bash
# Shared functions and constants for n8n-mts provisioning scripts.
set -euo pipefail

ROOT="/opt/n8n-mts"
CLIENTS_DIR="$ROOT/clients"
TEMPLATES="$ROOT/templates"
CLIENTS_MD="$ROOT/clients.md"
APPS_MD="$ROOT/apps.md"
ARCHIVE_DIR="$ROOT/archive"
PG_CONTAINER="n8n-mts-postgres"
OPS_NET="n8n-mts-net"
PORT_BASE=5679
APP_PORT_BASE=6679

# DOMAIN and CERTBOT_EMAIL are specific to one deployment, so they're NOT
# hardcoded in this shared/public file — they're loaded from domain.env
# (outside git, see .gitignore), which bootstrap.sh creates at install time.
DOMAIN_ENV="$ROOT/domain.env"
if [ -f "$DOMAIN_ENV" ]; then
  # shellcheck disable=SC1090
  . "$DOMAIN_ENV"
fi

# ---------- i18n: terminal output language ----------
# N8N_MTS_LANG selects the language of what scripts print to the
# terminal (not log/data file contents). Default stays "cs" so an
# existing live deployment's behavior doesn't change unless someone
# explicitly opts in with N8N_MTS_LANG=en. See msg() below.
N8N_MTS_LANG="${N8N_MTS_LANG:-cs}"
export N8N_MTS_LANG

if [ -z "${DOMAIN:-}" ]; then
  if [ "$N8N_MTS_LANG" = "en" ]; then
    echo "Missing DOMAIN= variable in $ROOT/domain.env (see docs/guide.en.md)." >&2
  else
    echo "Chybí $ROOT/domain.env s proměnnou DOMAIN= (viz docs/navod.md)." >&2
  fi
  exit 1
fi
CERTBOT_EMAIL="${CERTBOT_EMAIL:-admin@$DOMAIN}"

C_OK='\033[0;32m'; C_WARN='\033[0;33m'; C_ERR='\033[0;31m'; C_INFO='\033[0;36m'; C_RESET='\033[0m'
say()  { echo -e "${C_INFO}▶${C_RESET} $*"; }
ok()   { echo -e "${C_OK}✔${C_RESET} $*"; }
warn() { echo -e "${C_WARN}⚠${C_RESET} $*"; }
err()  { echo -e "${C_ERR}✘${C_RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

# msg <key> [args...] — looks up a CZ/EN message template by key (per
# N8N_MTS_LANG) and formats it with printf-style %s args. Message
# tables live in MSG_CS/MSG_EN (declared below, one pair per script,
# keys namespaced "script.name" to avoid collisions). Falls back to
# printing the bare key if it's missing from a table — a caller should
# never see a blank message, even if a translation is incomplete.
declare -gA MSG_CS=() MSG_EN=()
msg() {
  local key="$1"; shift
  local template
  if [ "$N8N_MTS_LANG" = "en" ]; then
    template="${MSG_EN[$key]:-${MSG_CS[$key]:-$key}}"
  else
    template="${MSG_CS[$key]:-$key}"
  fi
  # shellcheck disable=SC2059
  printf -- "$template" "$@"
}

MSG_CS[lib.require_root]='Spusť jako root.'
MSG_EN[lib.require_root]='Run as root.'
MSG_CS[lib.invalid_name]="Neplatné jméno klienta '%s' (povoleno: a-z 0-9 - )."
MSG_EN[lib.invalid_name]="Invalid client/app name '%s' (allowed: a-z 0-9 - )."
MSG_CS[lib.building_image]='Buildím image %s:latest (%s)'
MSG_EN[lib.building_image]='Building image %s:latest (%s)'
MSG_CS[lib.building_image.changed]='obsah %s se změnil'
MSG_EN[lib.building_image.changed]='contents of %s changed'
MSG_CS[lib.building_image.first]='poprvé'
MSG_EN[lib.building_image.first]='first time'
MSG_CS[lib.image_built]='Image %s:latest postaven'
MSG_EN[lib.image_built]='Image %s:latest built'
MSG_CS[lib.http2_enabled]='HTTP/2 zapnuto ve vhostu %s'
MSG_EN[lib.http2_enabled]='HTTP/2 enabled in vhost %s'
MSG_CS[lib.http2_module_missing]='mod_http2 není načtený — HTTP/2 pro %s přeskakuji. Načti SAMOTNÝ modul (ln -s ../mods-available/http2.load /etc/apache2/mods-enabled/http2.load), NE a2enmod http2 — ten přidá i http2.conf a zapne h2 i webům mimo tuto vrstvu.'
MSG_EN[lib.http2_module_missing]='mod_http2 is not loaded — skipping HTTP/2 for %s. Load the module ITSELF (ln -s ../mods-available/http2.load /etc/apache2/mods-enabled/http2.load), NOT a2enmod http2 — that also adds http2.conf and turns h2 on for sites this layer does not manage.'
MSG_CS[lib.http2_no_servername]='Ve vhostu %s není ServerName — HTTP/2 nezapnuto, přidej "Protocols h2 http/1.1" ručně.'
MSG_EN[lib.http2_no_servername]='No ServerName in vhost %s — HTTP/2 not enabled, add "Protocols h2 http/1.1" manually.'
MSG_CS[lib.http2_configtest_failed]='apache2ctl configtest po zapnutí HTTP/2 selhal — vracím %s ze zálohy, HTTP/2 nezapnuto.'
MSG_EN[lib.http2_configtest_failed]='apache2ctl configtest failed after enabling HTTP/2 — restoring %s from backup, HTTP/2 not enabled.'

require_root() { [ "$(id -u)" -eq 0 ] || die "$(msg lib.require_root)"; }

# client/app name: lowercase letters/digits/hyphen, starts and ends alphanumeric
validate_name() {
  local n="$1"
  [[ "$n" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "$(msg lib.invalid_name "$n")"
}

client_exists() { grep -q "^| $1 " "$CLIENTS_MD" 2>/dev/null; }

# an app is tracked as "| client | app | ..." in apps.md
app_exists() { grep -q "^| $1 | $2 " "$APPS_MD" 2>/dev/null; }

# password/key without characters that cause trouble in .env / shell
gen_secret() { openssl rand -base64 "${1:-32}" | tr -dc 'A-Za-z0-9' | head -c "${2:-32}"; }

# find a free n8n port from PORT_BASE up (no collision with clients.md or listening ports)
find_free_port() {
  local p="$PORT_BASE"
  while :; do
    if ! grep -q "| $p |" "$CLIENTS_MD" 2>/dev/null \
       && ! ss -tlnH "sport = :$p" 2>/dev/null | grep -q ":$p"; then
      echo "$p"; return 0
    fi
    p=$((p+1))
  done
}

psql_super() { docker exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=1 -U postgres "$@"; }

ensure_dirs() { mkdir -p "$CLIENTS_DIR" "$ARCHIVE_DIR" "$ROOT/claude-auth"; }

# Builds <name>:latest from directory <dir>, but ONLY if its contents
# changed since the last build — not just "if the image doesn't exist
# yet". Without this, a `git pull` bringing in a new Dockerfile on a
# server where the image already exists does nothing, and
# clients/apps keep running on the old image (we hit this with both
# app-runtime and claude-agent — issue #4). The directory's content
# hash is stored as a label on the image; the next call just compares
# against it, no external bookkeeping needed.
ensure_image() {
  local image="$1" dir="$2"
  local hash current
  hash="$(find "$dir" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)"
  current="$(docker image inspect "$image:latest" --format '{{index .Config.Labels "n8n_mts.src_hash"}}' 2>/dev/null || true)"
  if [ "$current" = "$hash" ]; then
    return 0
  fi
  local reason
  reason="$([ -n "$current" ] && msg lib.building_image.changed "$dir" || msg lib.building_image.first)"
  say "$(msg lib.building_image "$image" "$reason")"
  docker build --label "n8n_mts.src_hash=$hash" -t "$image:latest" "$dir" >/dev/null
  ok "$(msg lib.image_built "$image")"
}

# Apache name-based vhosting: a request for a subdomain that matches NO
# ServerName (a deleted/nonexistent client, a random subdomain under
# the wildcard) otherwise falls through to the first vhost in order
# and shows someone else's n8n with someone else's certificate. A
# _default_ vhost with its own self-signed cert catches this and
# returns 404 — it never reveals a real client's content. Idempotent,
# safe to call repeatedly (from new-client.sh, so it self-heals on
# already-running installs too).
ensure_catchall_vhost() {
  local conf="/etc/apache2/sites-available/000-catchall.conf"
  local cert="/etc/n8n-mts-catchall.pem" key="/etc/n8n-mts-catchall.key"
  if [ ! -f "$conf" ]; then
    if [ ! -f "$cert" ] || [ ! -f "$key" ]; then
      openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/CN=catchall.invalid" -keyout "$key" -out "$cert" >/dev/null 2>&1
      chmod 600 "$key"
    fi
    cat > "$conf" <<EOF
# Catch-all vhost — anything that doesn't match a specific client
# must NOT fall through to the alphabetically-first vhost and show
# someone else's n8n. _default_ only kicks in when nothing else matches.
<VirtualHost _default_:80>
    ServerName catchall.invalid
    Redirect 404 /
</VirtualHost>

<VirtualHost _default_:443>
    ServerName catchall.invalid
    SSLEngine on
    SSLCertificateFile $cert
    SSLCertificateKeyFile $key
    Redirect 404 /
</VirtualHost>
EOF
  fi
  a2ensite 000-catchall >/dev/null 2>&1
  apache2ctl configtest 2>/dev/null && systemctl reload apache2 2>/dev/null || true
}

# HTTP/2 for ONE of our own :443 vhosts (the *-le-ssl.conf that
# certbot generates). Called right after certbot, so every new client
# and app gets h2 without anyone remembering to add it.
#
# Why not mod_http2's own global config: mods-available/http2.conf
# carries "Protocols h2 h2c http/1.1", which turns h2 on for EVERY
# vhost on the server — including vhosts this layer doesn't manage.
# Protocols directives ADD UP, so a global line can't be overridden
# back off per vhost. Therefore: NEVER run `a2enmod http2` (it enables
# both http2.load and http2.conf) — only the .load symlink belongs
# here, and h2 is switched on per vhost, by us, in our files only.
#
# Idempotent: a vhost that already has a Protocols line is left
# untouched, so this is safe to re-run and also retrofits vhosts
# created before h2 was a thing here. Fail-safe: if configtest doesn't
# like the result, the original file is put back and provisioning
# carries on over HTTP/1.1 rather than leaving Apache unreloadable.
ensure_vhost_http2() {
  local vhost="$1"
  [ -f "$vhost" ] || return 0
  grep -qE '^[[:space:]]*Protocols[[:space:]]' "$vhost" && return 0
  if ! apache2ctl -M 2>/dev/null | grep -q 'http2_module'; then
    warn "$(msg lib.http2_module_missing "$(basename "$vhost")")"
    return 0
  fi

  local backup="$vhost.pre-http2"
  cp -p "$vhost" "$backup"
  # insert "Protocols h2 http/1.1" right below the first ServerName,
  # at the same indentation; everything else stays byte-identical
  awk '!ins && /^[[:space:]]*ServerName[[:space:]]/ {
         match($0, /^[[:space:]]*/)
         print
         print substr($0, 1, RLENGTH) "Protocols h2 http/1.1"
         ins = 1
         next
       } { print }' "$backup" > "$vhost"

  if ! grep -qE '^[[:space:]]*Protocols h2 http/1\.1$' "$vhost"; then
    cp -p "$backup" "$vhost"; rm -f "$backup"
    warn "$(msg lib.http2_no_servername "$(basename "$vhost")")"
    return 0
  fi
  if ! apache2ctl configtest >/dev/null 2>&1; then
    cp -p "$backup" "$vhost"; rm -f "$backup"
    warn "$(msg lib.http2_configtest_failed "$(basename "$vhost")")"
    return 0
  fi
  rm -f "$backup"
  systemctl reload apache2 2>/dev/null || true
  ok "$(msg lib.http2_enabled "$(basename "$vhost")")"
}

# clients.md/apps.md are the live record of a specific deployment
# (outside git, see .gitignore) — if missing (a fresh install, or the
# first time an app is ever set up), create them with a header, so
# scripts don't depend on a one-time setup step for this.
ensure_clients_md() {
  [ -f "$CLIENTS_MD" ] && return 0
  cat > "$CLIENTS_MD" <<'MD'
# Evidence klientů n8n-mts

Automaticky spravováno skripty `new-client.sh` / `remove-client.sh`.
Sloupec **Měsíční paušál** si vyplň ručně (USD) — používá ho `usage-report.sh`
k výpočtu, na kolik % paušálu vychází spotřeba AI daného klienta.

Pořadí sloupců je závazné (skripty ho parsují): 9. sloupec = paušál.

| Klient | Subdoména | Port | Síť | DB | Uživatel | Založen | Měsíční paušál | Stav |
|--------|-----------|------|-----|----|----------|---------|----------------|------|
MD
}

ensure_apps_md() {
  [ -f "$APPS_MD" ] && return 0
  cat > "$APPS_MD" <<'MD'
# Evidence appek n8n-mts

Automaticky spravováno skripty `new-app.sh` / `remove-app.sh`.
Appka patří vždy ke konkrétnímu klientovi (sloupec **Klient**) a sedí v jeho
izolované síti `net-{klient}` — nevidí a není vidět z žádného jiného klienta.

Pořadí sloupců je závazné (skripty ho parsují).

| Klient | Appka | Subdoména | Port | Založena | Stav |
|--------|-------|-----------|------|----------|------|
MD
}

# Daily backup of every active client (DB dump + .env, see
# backup-clients.sh) via a host cron.d entry. Idempotent — only writes
# the file if it's missing or doesn't already reference the script, so
# it self-heals on an already-running server too (found missing by
# sysadmin-claude's 2026-10-16 audit: new clients never got scheduled
# backups, only a one-off dump at removal time).
ensure_backup_cron() {
  local cron="/etc/cron.d/n8n-mts-backup"
  if [ -f "$cron" ] && grep -qF "$ROOT/scripts/backup-clients.sh" "$cron" 2>/dev/null; then
    return 0
  fi
  echo "0 3 * * * root $ROOT/scripts/backup-clients.sh >>/var/log/n8n-mts-backup.log 2>&1" > "$cron"
  chmod 0644 "$cron"
}

# find a free app port from APP_PORT_BASE up (no collision with apps.md or listening ports)
find_free_app_port() {
  local p="$APP_PORT_BASE"
  while :; do
    if ! grep -q "| $p |" "$APPS_MD" 2>/dev/null \
       && ! ss -tlnH "sport = :$p" 2>/dev/null | grep -q ":$p"; then
      echo "$p"; return 0
    fi
    p=$((p+1))
  done
}
