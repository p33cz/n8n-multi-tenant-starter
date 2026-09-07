#!/usr/bin/env bash
# Sdílené funkce a konstanty pro provisioning skripty n8n-mts.
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

# DOMAIN a CERTBOT_EMAIL jsou specifické pro konkrétní nasazení, proto NEJSOU
# natvrdo v tomhle sdíleném/veřejném souboru — načtou se z domain.env
# (mimo git, viz .gitignore), který si při instalaci vytvoří bootstrap.sh.
DOMAIN_ENV="$ROOT/domain.env"
if [ -f "$DOMAIN_ENV" ]; then
  # shellcheck disable=SC1090
  . "$DOMAIN_ENV"
fi
DOMAIN="${DOMAIN:?Chybí $ROOT/domain.env s proměnnou DOMAIN= (viz docs/navod.md).}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-admin@$DOMAIN}"

C_OK='\033[0;32m'; C_WARN='\033[0;33m'; C_ERR='\033[0;31m'; C_INFO='\033[0;36m'; C_RESET='\033[0m'
say()  { echo -e "${C_INFO}▶${C_RESET} $*"; }
ok()   { echo -e "${C_OK}✔${C_RESET} $*"; }
warn() { echo -e "${C_WARN}⚠${C_RESET} $*"; }
err()  { echo -e "${C_ERR}✘${C_RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

require_root() { [ "$(id -u)" -eq 0 ] || die "Spusť jako root."; }

# jméno klienta: malá písmena/číslice/pomlčka, začíná i končí alfanumericky
validate_name() {
  local n="$1"
  [[ "$n" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "Neplatné jméno klienta '$n' (povoleno: a-z 0-9 - )."
}

client_exists() { grep -q "^| $1 " "$CLIENTS_MD" 2>/dev/null; }

# appka je vedená jako "| klient | appka | ..." v apps.md
app_exists() { grep -q "^| $1 | $2 " "$APPS_MD" 2>/dev/null; }

# heslo/klíč bez znaků, které dělají problém v .env / shellu
gen_secret() { openssl rand -base64 "${1:-32}" | tr -dc 'A-Za-z0-9' | head -c "${2:-32}"; }

# najdi volný n8n port od PORT_BASE výš (nekoliduje s clients.md ani s naslouchajícími porty)
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

# clients.md/apps.md jsou živá evidence konkrétního nasazení (mimo git, viz
# .gitignore) — pokud chybí (čerstvá instalace, nebo poprvé se zakládá appka),
# vytvoř je s hlavičkou, ať na tom skripty nejsou závislé jen jednorázově.
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

# najdi volný port appky od APP_PORT_BASE výš (nekoliduje s apps.md ani s naslouchajícími porty)
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
