#!/usr/bin/env bash
#
# bootstrap.sh — runs on a fresh VPS, installs Claude Code and hands
# it control to build a multi-tenant n8n hosting setup on its own.
#
# Usage:
#   chmod +x bootstrap.sh
#   ./bootstrap.sh
#
# Language of the interactive messages below: set N8N_MTS_LANG=en
# before running for English (default: cs). This also becomes the
# default N8N_MTS_LANG for every script in scripts/ afterwards (saved
# to ~/.bashrc, same as ANTHROPIC_API_KEY). The embedded prompt
# handed to Claude Code (FÁZE 1-9 below) is in English either way —
# an LLM reads it equally well in either language, so there's no
# value in maintaining two copies of it.
set -euo pipefail

N8N_MTS_LANG="${N8N_MTS_LANG:-cs}"
# pick <czech> <english> — returns the text matching N8N_MTS_LANG
pick() { if [ "$N8N_MTS_LANG" = "en" ]; then echo "$2"; else echo "$1"; fi; }

# ---------- colors for readability ----------
C_OK='\033[0;32m'; C_WARN='\033[0;33m'; C_ERR='\033[0;31m'; C_INFO='\033[0;36m'; C_RESET='\033[0m'
say()  { echo -e "${C_INFO}▶${C_RESET} $1"; }
ok()   { echo -e "${C_OK}✔${C_RESET} $1"; }
warn() { echo -e "${C_WARN}⚠${C_RESET} $1"; }
err()  { echo -e "${C_ERR}✘${C_RESET} $1"; }

WORKDIR="/opt/n8n-mts"
PROMPT_FILE="$WORKDIR/master-prompt.txt"

# ---------- 0. root check ----------
if [[ $EUID -ne 0 ]]; then
  err "$(pick 'Spusť tento skript jako root (sudo ./bootstrap.sh).' 'Run this script as root (sudo ./bootstrap.sh).')"
  exit 1
fi

echo ""
echo "======================================================"
echo "$(pick '   Bootstrap: Claude Code pro multi-tenant n8n hosting' '   Bootstrap: Claude Code for multi-tenant n8n hosting')"
echo "======================================================"
echo ""

# ---------- 1. detect the server's public IP ----------
say "$(pick 'Zjišťuji veřejnou IP tohoto serveru...' "Detecting this server's public IP...")"
SERVER_IP="$(curl -fsSL4 ifconfig.me || curl -fsSL4 icanhazip.com || true)"
if [[ -z "$SERVER_IP" ]]; then
  warn "$(pick 'Nepodařilo se zjistit veřejnou IP automaticky.' "Couldn't detect the public IP automatically.")"
  read -rp "$(pick 'Zadej veřejnou IP tohoto serveru ručně: ' "Enter this server's public IP manually: ")" SERVER_IP
fi
ok "$(pick 'Veřejná IP serveru: ' "Server's public IP: ")$SERVER_IP"
echo ""

# ---------- 2. domain ----------
read -rp "$(pick 'Zadej primární doménu pro klienty (např. n8n.tvojedomena.cz): ' 'Enter the primary domain for clients (e.g. n8n.yourdomain.com): ')" DOMAIN
if [[ -z "$DOMAIN" ]]; then
  err "$(pick 'Doména je povinná, končím.' 'The domain is required, stopping.')"
  exit 1
fi

echo ""
say "$(pick 'Potřebuješ mít u svého DNS providera nastavený wildcard záznam:' 'You need a wildcard record set up with your DNS provider:')"
echo ""
echo "    *.${DOMAIN}    A    ${SERVER_IP}"
echo ""
read -rp "$(pick 'Je tenhle záznam už nastavený? [y/N]: ' 'Is this record already set up? [y/N]: ')" DNS_CONFIRMED
if [[ ! "$DNS_CONFIRMED" =~ ^[Yy]$ ]]; then
  warn "$(pick "Nastav si ho teď u svého DNS providera (A záznam *.${DOMAIN} -> ${SERVER_IP})." "Set it up now with your DNS provider (A record *.${DOMAIN} -> ${SERVER_IP}).")"
  read -rp "$(pick 'Až bude hotovo, stiskni Enter a zkusíme to ověřit... ' "Once it's done, press Enter and we'll try to verify it... ")" _
fi

# ---------- 3. DNS verification (best-effort, doesn't block continuing) ----------
say "$(pick "Ověřuji DNS pro test.${DOMAIN}..." "Verifying DNS for test.${DOMAIN}...")"
if ! command -v dig &>/dev/null; then
  apt-get update -qq && apt-get install -y -qq dnsutils &>/dev/null || true
fi

DNS_OK=0
for i in 1 2 3; do
  RESOLVED_IP="$(dig +short "test.${DOMAIN}" A | tail -n1 || true)"
  if [[ "$RESOLVED_IP" == "$SERVER_IP" ]]; then
    DNS_OK=1
    break
  fi
  [[ $i -lt 3 ]] && { warn "$(pick 'Zatím nesedí (DNS propagace může chvíli trvat). Zkouším znovu za 10s...' "Doesn't match yet (DNS propagation can take a while). Trying again in 10s...")"; sleep 10; }
done

if [[ $DNS_OK -eq 1 ]]; then
  ok "$(pick 'DNS ukazuje správně na tento server.' 'DNS correctly points at this server.')"
else
  warn "$(pick "DNS pro *.${DOMAIN} zatím neukazuje na ${SERVER_IP} (nebo ještě propaguje)." "DNS for *.${DOMAIN} doesn't point at ${SERVER_IP} yet (or is still propagating).")"
  warn "$(pick 'Claude Code to zkusí ověřit znovu sám, než bude žádat o certifikáty.' 'Claude Code will try to verify it again itself before requesting certificates.')"
  read -rp "$(pick 'Pokračovat i tak? [y/N]: ' 'Continue anyway? [y/N]: ')" CONTINUE_ANYWAY
  if [[ ! "$CONTINUE_ANYWAY" =~ ^[Yy]$ ]]; then
    err "$(pick 'Zastaveno — nastav DNS a spusť skript znovu.' 'Stopped — set up DNS and run the script again.')"
    exit 1
  fi
fi
echo ""

# ---------- 4. API token ----------
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  read -rsp "$(pick 'Vlož Anthropic API token (sk-ant-...): ' 'Enter your Anthropic API token (sk-ant-...): ')" ANTHROPIC_API_KEY
  echo ""
fi
if [[ -z "$ANTHROPIC_API_KEY" ]]; then
  err "$(pick 'API token je povinný, končím.' 'The API token is required, stopping.')"
  exit 1
fi
ok "$(pick 'API token přijat.' 'API token accepted.')"
echo ""

# ---------- 5. install Node.js + Claude Code CLI ----------
if ! command -v node &>/dev/null; then
  say "$(pick 'Instaluji Node.js 20...' 'Installing Node.js 20...')"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - &>/dev/null
  apt-get install -y -qq nodejs &>/dev/null
  ok "$(pick 'Node.js nainstalován: ' 'Node.js installed: ')$(node --version)"
else
  ok "$(pick 'Node.js už je nainstalovaný: ' 'Node.js is already installed: ')$(node --version)"
fi

if ! command -v claude &>/dev/null; then
  say "$(pick 'Instaluji Claude Code CLI...' 'Installing the Claude Code CLI...')"
  npm install -g @anthropic-ai/claude-code &>/dev/null
  ok "$(pick 'Claude Code nainstalován: ' 'Claude Code installed: ')$(claude --version)"
else
  ok "$(pick 'Claude Code už je nainstalovaný: ' 'Claude Code is already installed: ')$(claude --version)"
fi
echo ""

# ---------- 6. working directory + persisting the token ----------
mkdir -p "$WORKDIR"
cd "$WORKDIR"

cat > "$WORKDIR/.env" <<EOF
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
EOF
chmod 600 "$WORKDIR/.env"

# the domain is specific to this deployment — outside git (see
# .gitignore), the provisioning scripts (scripts/lib.sh) load it from here
cat > "$WORKDIR/domain.env" <<EOF
DOMAIN=${DOMAIN}
EOF
chmod 600 "$WORKDIR/domain.env"

if ! grep -q "ANTHROPIC_API_KEY" ~/.bashrc 2>/dev/null; then
  echo "export ANTHROPIC_API_KEY=\"${ANTHROPIC_API_KEY}\"" >> ~/.bashrc
fi
export ANTHROPIC_API_KEY
if ! grep -q "N8N_MTS_LANG" ~/.bashrc 2>/dev/null; then
  echo "export N8N_MTS_LANG=\"${N8N_MTS_LANG}\"" >> ~/.bashrc
fi
export N8N_MTS_LANG

ok "$(pick "Token uložen do ${WORKDIR}/.env a ~/.bashrc" "Token saved to ${WORKDIR}/.env and ~/.bashrc")"
echo ""

# ---------- 7. generate the master prompt for Claude Code ----------
say "$(pick 'Připravuji instrukce pro Claude Code...' 'Preparing instructions for Claude Code...')"

cat > "$PROMPT_FILE" <<PROMPT
I'm on a fresh VPS (root access). Figure out the distro and version
yourself, and what's already installed on the server — don't
duplicate anything, just fill in what's missing.

Primary domain for clients: ${DOMAIN}
Clients will run on subdomains like client1.${DOMAIN}, client2.${DOMAIN}
etc. The wildcard DNS record *.${DOMAIN} -> ${SERVER_IP} should already
be set up (if you hit a DNS error while issuing a certificate, tell me
exactly what to check, and wait for my confirmation before retrying).

I want to build multi-tenant hosting for n8n with a TWO-LAYER architecture:

1) YOU (this instance, which I'm giving instructions to right now) are
   the OPS layer — you manage the whole server, create and remove
   clients, configure Apache/Postgres/the firewall. You never touch
   any client's content (workflows, credentials) directly.

2) Each CLIENT gets a PAIR of containers:
   - n8n-{client} — their n8n instance
   - claude-{client} — THEIR OWN Claude Code, which talks ONLY to this
     one client's n8n REST API (via the internal hostname n8n-{client}
     in their shared isolated network). This container does NOT have
     docker.sock mounted and CANNOT see any other container on the
     server. Its purpose is to let me have that client's agents and
     workflows created/edited without me being able to technically
     slip up and touch another client's data — the isolation has to be
     network/structural, not just "being careful".
   - both sit in their OWN Docker network net-{client} (bridge),
     isolated from other clients and from the ops network.

Carry out the complete install and configuration in these phases.
After each phase, briefly write what you did and which default
choices you made wherever I didn't give you an exact specification.

PHASE 1 — basic server hardening
- firewall (ufw): allow only SSH, 80, 443
- fail2ban for SSH and Apache

PHASE 2 — Docker
- install Docker + the docker compose plugin if missing
- create a Docker network \`n8n-mts-net\` (bridge) — ONLY for Postgres
  and the ops layer, client pairs do NOT belong in it

PHASE 3 — Postgres
- run Postgres as a Docker container (image postgres:16) in network
  n8n-mts-net, data on a persistent volume, no public port
- save the root password to /opt/n8n-mts/postgres.env (outside git)
- Postgres must be reachable from net-{client} networks too, but a
  client must not see anything else from n8n-mts-net: when setting up
  a client (new-client.sh), additionally connect the Postgres
  container into the newly created net-{client} via
  \`docker network connect\`, and run \`REVOKE CONNECT ON DATABASE ...
  FROM PUBLIC\` on both the maintenance DB and every client DB, so a
  client's DB user only sees its own database

PHASE 4 — Apache2 as a reverse proxy
- install apache2 and certbot (python3-certbot-apache) if missing
- enable modules: proxy proxy_http proxy_wstunnel rewrite ssl headers
- for HTTP/2, load ONLY the module itself (symlink
  mods-enabled/http2.load); do NOT run `a2enmod http2`, which also
  enables mods-available/http2.conf with a global "Protocols h2 h2c
  http/1.1" and would switch h2 on for every vhost on the server,
  including any not managed by this layer — h2 is enabled per vhost,
  in the :443 vhost template (needs MPM event + PHP via PHP-FPM)
- handle the HTTP→HTTPS redirect directly in the vhost template
  (RewriteCond %{HTTPS} off + RewriteRule), NOT via certbot
  --redirect — so when issuing/renewing a certificate, use \`certbot
  --apache ... --no-redirect\`, so certbot doesn't dictate its own
  redirect into the vhost; for re-issuing the same certificate (e.g.
  after fixing a vhost), also use \`--reinstall\`, so it doesn't
  request a new certificate and risk hitting the Let's Encrypt rate
  limit needlessly

PHASE 5 — templates and conventions
- create the structure:
  /opt/n8n-mts/clients/{client}/docker-compose.yml + .env
  /opt/n8n-mts/scripts/
  /opt/n8n-mts/clients.md   (record of clients, ports, status)
  /opt/n8n-mts/OPS.md       (write down every convention you pick —
                            container names, network net-{client},
                            numbering n8n ports from 5679, DB/user
                            names db_{client}/u_{client}, where vhosts
                            live, how the n8n API key is generated and
                            passed to claude-{client}, etc. NOTE:
                            /opt/n8n-mts/CLAUDE.md already exists in
                            the repo and is committed — generic
                            instructions for anyone working on the
                            repo. DO NOT overwrite it, leave it as is;
                            live conventions belong only in OPS.md)
- a docker-compose.yml template for a client's container PAIR
  (n8n-{client} + claude-{client}) in a shared isolated network
  net-{client} — mark network net-{client} in the template as
  \`external: true\`, because new-client.sh creates it itself (to
  connect Postgres into it), not docker compose
- an Apache VirtualHost template (HTTPS + websocket proxy for the n8n
  editor) — exposes ONLY n8n-{client}, claude-{client} has no public port
- IMPORTANT: name-based vhosting in Apache means a request for a
  subdomain that matches NO ServerName (a deleted client, a random
  subdomain under the wildcard) otherwise falls through to the first
  vhost in order and shows someone else's n8n with someone else's
  certificate — create ONE explicit catch-all vhost
  (\`<VirtualHost _default_:80>\` and \`_default_:443\`, its own
  self-signed cert) returning 404, so this can never happen
- IMPORTANT: /opt/n8n-mts is a git repository connected to public
  GitHub. The domain (${DOMAIN}) and any other specifics of this
  deployment (the real IP, real client names) must NOT be hardcoded in
  files that end up committed — read the domain in provisioning
  scripts from /opt/n8n-mts/domain.env (I'll create it in bootstrap
  step 6, outside git). clients.md and OPS.md will get filled with
  real client data during operation — add them to .gitignore so they
  don't accidentally end up in the public repo; only generic, reusable
  code belongs in git (scripts/, templates/, docker/, ops/, pricing.conf)

PHASE 6 — provisioning scripts
- /opt/n8n-mts/scripts/new-client.sh <name>
  → finds a free port, generates a password + encryption key, sets up
    a Postgres DB and user with rights on its own DB only
  → creates network net-{name}, starts n8n-{name} in it
  → generates an n8n API key scoped to just this instance via the n8n
    REST API (/rest/login + /rest/api-keys). Keep in mind:
    - n8n needs time after the container starts before its API
      actually responds — wrap the call in a retry loop (e.g. 20x
      every 3s), not a single attempt
    - creating a key requires a mandatory \`scopes\` field — don't
      hardcode the scopes list, fetch it dynamically from
      /rest/api-keys/scopes so it works across n8n versions, and send
      \`expiresAt: null\` along with it
    - the script that generates the key runs on the HOST (not in a
      container) — check for/install \`jq\` (and \`curl\`) on the host
      so it has something to parse with
    - never print the key or password value itself to logs/output,
      only its length, to confirm it isn't empty
  → starts claude-{name} in the same network with this key and with
    ANTHROPIC_API_KEY; claude-{name} must NOT have a docker.sock mount
  → in claude-{name}, automatically on container start (via the
    entrypoint, not cron) starts a screen session running \`claude
    remote-control\`, so it can be controlled from a phone right after
    setup and after every restart too — NOTE: \`claude remote-control\`
    only works with a login through a claude.ai account (subscription),
    NOT with ANTHROPIC_API_KEY. Without a one-time \`claude /login\` it
    stays ready but inactive. Build it so this doesn't block the rest
    of provisioning (isolation, n8n, usage tracking work independently
    of remote-control), and clearly tell me that this one step needs
    my manual login
  → creates and enables an Apache vhost for n8n-{name}, sorts out the
    certificate
  → writes to clients.md (name, port, network, when set up)
  → prints the final n8n URL and claude-{name}'s status (remote-control ready)
- /opt/n8n-mts/scripts/remove-client.sh <name>
  → backs up via a DB dump, stops and removes both containers and
    network net-{name}, removes the vhost

PHASE 7 — tracking AI (Anthropic) usage per client
- all claude-{client} containers share the same ANTHROPIC_API_KEY, so
  we have to track AI usage and cost ourselves, outside Anthropic's
  own billing — clients pay a flat fee meant to cover the cost, and I
  want to know whether it does
- in every claude-{client} container, set up a periodic job (cron,
  e.g. once an hour) that goes through local Claude Code session
  transcripts (JSONL files with usage fields: input_tokens/output_tokens/
  cache_creation_input_tokens/cache_read_input_tokens per response) and
  appends newly-appeared records to
  /opt/n8n-mts/clients/{client}/usage.log (line = date, model, token
  types, counts)
- create /opt/n8n-mts/pricing.conf — the price per 1M input/output/cache
  tokens for each model in use, so it's easy to update once Anthropic
  changes its pricing
- create /opt/n8n-mts/scripts/usage-report.sh, which goes through every
  client's usage.log for a chosen period (default: the current
  calendar month), estimates the price from pricing.conf, and prints
  an overview: client, token usage, estimated price in USD, and — if a
  client has a flat fee filled in in clients.md — what percentage of
  it the usage represents; highlight clients above 80% of their flat
  fee in the output (just a warning, nothing blocks automatically). If
  it hits a model in usage.log that isn't in pricing.conf, that must
  NOT crash the whole script (no exit with an error code) — just print
  a warning for that line and keep going with the other clients/models
- add a column for each client's monthly flat fee to clients.md (so I
  can fill it in myself)
- write the convention to OPS.md: where usage.log lives and its
  format, where pricing.conf is, how the price estimate is computed,
  and how to run usage-report.sh
- in remove-client.sh, when removing a client, don't delete usage.log —
  move it together with the DB backup into the archive (so the usage
  history survives even after removal)

PHASE 8 — self-management of the ops layer for future mobile access
- package yourself (the ops Claude Code) into a Docker container named
  claude-code-n8n-mts, running permanently in n8n-mts-net: mount
  /var/run/docker.sock (only here, for the ops layer — NEVER for
  client claude-{client} containers), an entrypoint that starts a
  screen session running \`claude remote-control\`, an @reboot cron as
  a safety net — same note as for clients: remote-control needs a
  one-time \`claude /login\` (a subscription account), with just
  ANTHROPIC_API_KEY it stays inactive; tell me this clearly in the
  summary so I don't miss it
- verify you keep running after moving into the container

PHASE 9 — test
- run new-client.sh with a test client "test1"
- verify: n8n on its subdomain runs over HTTPS, the websocket works,
  claude-test1 is running, has remote-control active, and does NOT
  have access to docker.sock or any network other than net-test1
- trigger at least one response in claude-test1 (e.g. a simple
  question), wait for the cron to run (or run it manually), and verify
  that a record shows up in /opt/n8n-mts/clients/test1/usage.log and
  that usage-report.sh test1 prints it correctly
- show me the contents of clients.md

If you hit an error, try to fix it yourself first before asking me.
At the end, give me a brief summary of the whole install and what I
should check.
PROMPT

ok "$(pick "Instrukce připraveny do ${PROMPT_FILE}" "Instructions ready at ${PROMPT_FILE}")"
echo ""

# ---------- 8. run mode ----------
echo "$(pick 'Jak chceš Claude Code spustit?' 'How do you want to run Claude Code?')"
echo "$(pick '  1) Interaktivně — bude se ptát na potvrzení rizikových kroků (doporučeno pro první běh)' '  1) Interactively — it will ask for confirmation before risky steps (recommended for the first run)')"
echo "$(pick '  2) Plně autonomně — bez ptaní, projede vše samo (--dangerously-skip-permissions)' '  2) Fully autonomous — no asking, runs through everything on its own (--dangerously-skip-permissions)')"
read -rp "$(pick 'Volba [1/2]: ' 'Choice [1/2]: ')" MODE_CHOICE
echo ""

cd "$WORKDIR"

if [[ "$MODE_CHOICE" == "2" ]]; then
  warn "$(pick 'Spouštím v plně autonomním režimu. Sleduj výstup v terminálu.' "Running in fully autonomous mode. Keep an eye on the terminal output.")"
  claude --dangerously-skip-permissions "$(cat "$PROMPT_FILE")"
else
  say "$(pick 'Spouštím interaktivně — Claude Code se bude občas ptát na potvrzení.' 'Running interactively — Claude Code will occasionally ask for confirmation.')"
  claude "$(cat "$PROMPT_FILE")"
fi
