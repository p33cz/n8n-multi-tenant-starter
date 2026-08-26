#!/usr/bin/env bash
#
# bootstrap.sh — spustí se na čerstvém VPS, nainstaluje Claude Code
# a předá mu řízení, aby si postavil multi-tenant n8n hosting sám.
#
# Použití:
#   chmod +x bootstrap.sh
#   ./bootstrap.sh
#
set -euo pipefail

# ---------- barvy pro čitelnost ----------
C_OK='\033[0;32m'; C_WARN='\033[0;33m'; C_ERR='\033[0;31m'; C_INFO='\033[0;36m'; C_RESET='\033[0m'
say()  { echo -e "${C_INFO}▶${C_RESET} $1"; }
ok()   { echo -e "${C_OK}✔${C_RESET} $1"; }
warn() { echo -e "${C_WARN}⚠${C_RESET} $1"; }
err()  { echo -e "${C_ERR}✘${C_RESET} $1"; }

WORKDIR="/opt/agenti"
PROMPT_FILE="$WORKDIR/master-prompt.txt"

# ---------- 0. kontrola root ----------
if [[ $EUID -ne 0 ]]; then
  err "Spusť tento skript jako root (sudo ./bootstrap.sh)."
  exit 1
fi

echo ""
echo "======================================================"
echo "   Bootstrap: Claude Code pro multi-tenant n8n hosting"
echo "======================================================"
echo ""

# ---------- 1. zjištění veřejné IP serveru ----------
say "Zjišťuji veřejnou IP tohoto serveru..."
SERVER_IP="$(curl -fsSL4 ifconfig.me || curl -fsSL4 icanhazip.com || true)"
if [[ -z "$SERVER_IP" ]]; then
  warn "Nepodařilo se zjistit veřejnou IP automaticky."
  read -rp "Zadej veřejnou IP tohoto serveru ručně: " SERVER_IP
fi
ok "Veřejná IP serveru: $SERVER_IP"
echo ""

# ---------- 2. doména ----------
read -rp "Zadej primární doménu pro klienty (např. agenti.tvojedomena.cz): " DOMAIN
if [[ -z "$DOMAIN" ]]; then
  err "Doména je povinná, končím."
  exit 1
fi

echo ""
say "Potřebuješ mít u svého DNS providera nastavený wildcard záznam:"
echo ""
echo "    *.${DOMAIN}    A    ${SERVER_IP}"
echo ""
read -rp "Je tenhle záznam už nastavený? [y/N]: " DNS_CONFIRMED
if [[ ! "$DNS_CONFIRMED" =~ ^[Yy]$ ]]; then
  warn "Nastav si ho teď u svého DNS providera (A záznam *.${DOMAIN} -> ${SERVER_IP})."
  read -rp "Až bude hotovo, stiskni Enter a zkusíme to ověřit... " _
fi

# ---------- 3. ověření DNS (best-effort, neblokuje pokračování) ----------
say "Ověřuji DNS pro test.${DOMAIN}..."
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
  [[ $i -lt 3 ]] && { warn "Zatím nesedí (DNS propagace může chvíli trvat). Zkouším znovu za 10s..."; sleep 10; }
done

if [[ $DNS_OK -eq 1 ]]; then
  ok "DNS ukazuje správně na tento server."
else
  warn "DNS pro *.${DOMAIN} zatím neukazuje na ${SERVER_IP} (nebo ještě propaguje)."
  warn "Claude Code to zkusí ověřit znovu sám, než bude žádat o certifikáty."
  read -rp "Pokračovat i tak? [y/N]: " CONTINUE_ANYWAY
  if [[ ! "$CONTINUE_ANYWAY" =~ ^[Yy]$ ]]; then
    err "Zastaveno — nastav DNS a spusť skript znovu."
    exit 1
  fi
fi
echo ""

# ---------- 4. API token ----------
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  read -rsp "Vlož Anthropic API token (sk-ant-...): " ANTHROPIC_API_KEY
  echo ""
fi
if [[ -z "$ANTHROPIC_API_KEY" ]]; then
  err "API token je povinný, končím."
  exit 1
fi
ok "API token přijat."
echo ""

# ---------- 5. instalace Node.js + Claude Code CLI ----------
if ! command -v node &>/dev/null; then
  say "Instaluji Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - &>/dev/null
  apt-get install -y -qq nodejs &>/dev/null
  ok "Node.js nainstalován: $(node --version)"
else
  ok "Node.js už je nainstalovaný: $(node --version)"
fi

if ! command -v claude &>/dev/null; then
  say "Instaluji Claude Code CLI..."
  npm install -g @anthropic-ai/claude-code &>/dev/null
  ok "Claude Code nainstalován: $(claude --version)"
else
  ok "Claude Code už je nainstalovaný: $(claude --version)"
fi
echo ""

# ---------- 6. pracovní adresář + trvalé uložení tokenu ----------
mkdir -p "$WORKDIR"
cd "$WORKDIR"

cat > "$WORKDIR/.env" <<EOF
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
EOF
chmod 600 "$WORKDIR/.env"

if ! grep -q "ANTHROPIC_API_KEY" ~/.bashrc 2>/dev/null; then
  echo "export ANTHROPIC_API_KEY=\"${ANTHROPIC_API_KEY}\"" >> ~/.bashrc
fi
export ANTHROPIC_API_KEY

ok "Token uložen do ${WORKDIR}/.env a ~/.bashrc"
echo ""

# ---------- 7. vygenerování master promptu pro Claude Code ----------
say "Připravuji instrukce pro Claude Code..."

cat > "$PROMPT_FILE" <<PROMPT
Jsem na čerstvém VPS (root přístup). Zjisti si sám distribuci a verzi
a co už je na serveru nainstalované — nic needuplikuj, jen doplň
chybějící.

Primární doména pro klienty: ${DOMAIN}
Klienti poběží na subdoménách typu klient1.${DOMAIN}, klient2.${DOMAIN} atd.
Wildcard DNS záznam *.${DOMAIN} -> ${SERVER_IP} by měl už být nastavený
(pokud při vydávání certifikátu narazíš na chybu DNS, řekni mi přesně,
co mám zkontrolovat, a počkej na mé potvrzení, než to zkusíš znovu).

Chci postavit multi-tenant hosting pro n8n s DVOUVRSTVOU architekturou:

1) TY (tato instance, které teď dávám instrukce) jsi OPS vrstva — spravuješ
   celý server, zakládáš a rušíš klienty, upravuješ Apache/Postgres/firewall.
   Nikdy se nedotýkáš obsahu (workflow, credentials) žádného klienta přímo.

2) Každý KLIENT dostane PÁR kontejnerů:
   - n8n-{klient} — jeho n8n instance
   - claude-{klient} — JEHO VLASTNÍ Claude Code, který mluví JEN s n8n
     REST API tohoto jednoho klienta (přes interní hostname n8n-{klient}
     v jejich společné izolované síti). Tenhle kontejner NEMÁ mountnutý
     docker.sock a NEVIDÍ žádný jiný kontejner na serveru. Slouží k tomu,
     abych já (David) mohl tomu klientovi nechat vytvářet/upravovat jeho
     agenty a workflow, aniž bych se mohl technicky splést a zasáhnout
     do dat jiného klienta — izolace musí být síťová/strukturální, ne
     jen "dávat pozor".
   - oba dva sedí ve VLASTNÍ Docker síti net-{klient} (bridge), izolované
     od ostatních klientů i od ops sítě.

Proveď kompletní instalaci a konfiguraci v těchto fázích. Po každé
fázi krátce napiš, co jsi udělal a jaké výchozí volby jsi zvolil tam,
kde jsem ti nedal přesnou specifikaci.

FÁZE 1 — základní zabezpečení serveru
- firewall (ufw): povol jen SSH, 80, 443
- fail2ban na SSH i Apache

FÁZE 2 — Docker
- nainstaluj Docker + docker compose plugin, pokud chybí
- vytvoř Docker síť \`agenti-net\` (bridge) — JEN pro Postgres a ops vrstvu,
  klientské páry do ní NEPATŘÍ

FÁZE 3 — Postgres
- rozjeď Postgres jako Docker kontejner (image postgres:16) v síti
  agenti-net, data na perzistentním volume, žádný veřejný port ven
- ulož root heslo do /opt/agenti/postgres.env (mimo git)
- Postgres musí být dosažitelný i ze sítí net-{klient} — připoj kontejner
  Postgres do agenti-net i do každé nově vznikající net-{klient} (nebo
  zvol jiný rozumný způsob, jak DB kontejner uvidí klientská síť, aniž
  klient uvidí cokoli jiného v agenti-net — a napiš mi, jak jsi to vyřešil)

FÁZE 4 — Apache2 jako reverzní proxy
- nainstaluj apache2 a certbot (python3-certbot-apache), pokud chybí
- aktivuj moduly: proxy proxy_http proxy_wstunnel rewrite ssl headers

FÁZE 5 — šablony a konvence
- vytvoř strukturu:
  /opt/agenti/clients/{klient}/docker-compose.yml + .env
  /opt/agenti/scripts/
  /opt/agenti/clients.md   (evidence klientů, portů, stavu)
  /opt/agenti/CLAUDE.md    (zapiš tam všechny konvence, které zvolíš —
                            jméno kontejnerů, síť net-{klient}, číslování
                            portů n8n od 5679, jméno DB/uživatelů
                            db_{klient}/u_{klient}, umístění vhostů,
                            jak se generuje a předává n8n API klíč do
                            claude-{klient} atd.)
- šablona docker-compose.yml pro PÁR kontejnerů klienta (n8n-{klient} +
  claude-{klient}) ve společné izolované síti net-{klient}
- šablona Apache VirtualHostu (HTTPS + websocket proxy pro n8n editor) —
  vystavuje ven POUZE n8n-{klient}, claude-{klient} nemá žádný veřejný port

FÁZE 6 — provisioning skripty
- /opt/agenti/scripts/new-client.sh <jmeno>
  → najde volný port, vygeneruje heslo + encryption key, založí
    Postgres DB a uživatele s právy jen na svou DB
  → vytvoří síť net-{jmeno}, spustí n8n-{jmeno} v ní
  → vygeneruje n8n API klíč scoped jen na tuto instanci (přes n8n
    API/CLI) a spustí v téže síti claude-{jmeno} s tímto klíčem
    a s ANTHROPIC_API_KEY; claude-{jmeno} NESMÍ mít docker.sock mount
  → v claude-{jmeno} automaticky při startu kontejneru (přes entrypoint,
    ne cron) spustí screen session s \`claude remote-control\`, aby
    šel ovládat z mobilu hned po založení a i po každém restartu
  → vytvoří a aktivuje Apache vhost pro n8n-{jmeno}, vyřídí certifikát
  → zapíše do clients.md (jméno, port, síť, kdy založen)
  → vypíše finální URL n8n a stav claude-{jmeno} (remote-control ready)
- /opt/agenti/scripts/remove-client.sh <jmeno>
  → zazálohuje DB dumpem, zastaví a smaže oba kontejnery i síť
    net-{jmeno}, odebere vhost

FÁZE 7 — self-management ops vrstvy pro budoucí přístup z mobilu
- zabal sám sebe (ops Claude Code) do Docker kontejneru trvale běžícího
  v agenti-net: mount /var/run/docker.sock (jen tady, u ops vrstvy — u
  klientských claude-{klient} kontejnerů NIKDY), entrypoint co spustí
  screen session s \`claude remote-control\`, @reboot cron jako pojistka
- ověř, že běžíš dál i po přesunu do kontejneru

FÁZE 8 — test
- spusť new-client.sh s testovacím klientem "test1"
- ověř: n8n na jeho subdoméně běží přes HTTPS, websocket funguje,
  claude-test1 běží, má remote-control aktivní, a NEMÁ přístup
  k docker.sock ani k jiné síti než net-test1
- ukaž mi obsah clients.md

Pokud narazíš na chybu, zkus ji nejdřív opravit sám, než se mě zeptáš.
Na konci mi dej stručné shrnutí celé instalace a co mám zkontrolovat.
PROMPT

ok "Instrukce připraveny do ${PROMPT_FILE}"
echo ""

# ---------- 8. režim spuštění ----------
echo "Jak chceš Claude Code spustit?"
echo "  1) Interaktivně — bude se ptát na potvrzení rizikových kroků (doporučeno pro první běh)"
echo "  2) Plně autonomně — bez ptaní, projede vše samo (--dangerously-skip-permissions)"
read -rp "Volba [1/2]: " MODE_CHOICE
echo ""

cd "$WORKDIR"

if [[ "$MODE_CHOICE" == "2" ]]; then
  warn "Spouštím v plně autonomním režimu. Sleduj výstup v terminálu."
  claude --dangerously-skip-permissions "$(cat "$PROMPT_FILE")"
else
  say "Spouštím interaktivně — Claude Code se bude občas ptát na potvrzení."
  claude "$(cat "$PROMPT_FILE")"
fi
