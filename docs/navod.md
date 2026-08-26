# Návod: VPS, kde si vše nastaví Claude Code sám

Cíl: na čerstvém VPS uděláš jen minimální bootstrap (nainstaluješ Claude Code), pak mu dáš doménu a token — a on sám zjistí stav serveru, doinstaluje co chybí, a postaví celou multi-tenant n8n infrastrukturu (Apache, Postgres, Docker, per-klient kontejnery, provisioning skripty).

---

## Co musíš udělat ty (a proč to nejde jinak)

**1. Zaplatit VPS** — Debian 12 nebo Ubuntu 24.04, min. 4 vCPU / 8 GB RAM. Poznamenej si veřejnou IP adresu.

**2. Nastavit DNS** — u svého DNS providera (kde spravuješ `tvojedomena.cz`) založ:
```
*.agenti.tvojedomena.cz    A    <IP tvého VPS>
```
Tohle musíš udělat ty ručně — Claude Code nemá přístup k tvému DNS účtu, pokud mu ho výslovně nedáš (API token registrátora). Bez tohoto kroku nedostane žádný SSL certifikát.

**3. Mít Anthropic API token** — ten mu dáš na vyžádání v kroku níž.

To je vše, co musíš udělat ty. Zbytek dělá agent.

---

## Krok 1 — Bootstrap: nainstaluj Claude Code na čerstvý server

Připoj se přes SSH jako root:
```bash
ssh root@<IP-tveho-VPS>
```

Spusť tenhle jednorázový bootstrap (funguje na Debianu i Ubuntu, nezáleží na tom, co je na serveru už nainstalované):

```bash
# Node.js (potřebuje ho Claude Code CLI)
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

# Claude Code CLI
npm install -g @anthropic-ai/claude-code

# pracovní adresář projektu
mkdir -p /opt/agenti && cd /opt/agenti
```

Nastav API token:
```bash
export ANTHROPIC_API_KEY="sk-ant-tvuj-token"
```

*(Ať ho nemusíš zadávat po každém restartu terminálu, přidej tenhle řádek i do `~/.bashrc`.)*

---

## Krok 2 — Spusť Claude Code a dej mu instrukce

```bash
cd /opt/agenti
claude
```

Otevře se interaktivní chat rovnou v terminálu. Vlož mu tenhle prompt (v něm se tě sám zeptá na doménu — nemusíš ji vypisovat předem):

```
Jsem na čerstvém VPS (root přístup, Debian/Ubuntu — zjisti si sám jaký).
Chci na něm postavit multi-tenant hosting pro n8n, kde bude mít každý
klient vlastní izolovanou n8n instanci na vlastní subdoméně.

Než začneš, zeptej se mě na:
1. primární doménu, pod kterou budou subdomény klientů (např.
   agenti.tvojedomena.cz — klienti pak budou na klient1.agenti...)
2. jestli už mám na tuhle doménu nastavený wildcard DNS A záznam
   směřující na IP tohoto serveru (pokud ne, řekni mi přesně, co mám
   nastavit, a počkej, než to potvrdím, než budeš žádat o certifikáty)

Pak proveď kompletní instalaci a konfiguraci:

FÁZE 0 — průzkum
- zjisti distribuci, verzi, co už je nainstalované (apache, docker,
  postgres, certbot, ufw/firewall) — nic needuplikuj, jen doplň chybějící

FÁZE 1 — základní zabezpečení serveru
- firewall (ufw): povol jen SSH, 80, 443
- fail2ban na SSH i Apache

FÁZE 2 — Docker
- nainstaluj Docker + docker compose plugin, pokud chybí
- vytvoř Docker síť `agenti-net` (bridge) pro n8n kontejnery a Postgres

FÁZE 3 — Postgres
- rozjeď Postgres jako Docker kontejner (image postgres:16) v síti
  agenti-net, data na perzistentním volume, žádný veřejný port ven
- ulož root heslo do /opt/agenti/postgres.env (mimo git)

FÁZE 4 — Apache2 jako reverzní proxy
- nainstaluj apache2 a certbot (python3-certbot-apache), pokud chybí
- aktivuj moduly: proxy proxy_http proxy_wstunnel rewrite ssl headers
- zajisti certifikát pro subdomény (wildcard přes DNS-01 pokud máš
  přístup k DNS API, jinak certbot --apache per klient při zakládání)

FÁZE 5 — šablony a konvence
- vytvoř adresářovou strukturu:
  /opt/agenti/clients/{klient}/docker-compose.yml + .env
  /opt/agenti/scripts/
  /opt/agenti/clients.md   (evidence klientů, portů, stavu)
  /opt/agenti/CLAUDE.md    (zapiš do něj VŠECHNY konvence, které
                            zvolíš v této fázi — jméno kontejnerů,
                            číslování portů od 5679, jméno DB/uživatelů
                            db_{klient}/u_{klient}, umístění vhostů,
                            atd. — ať se jich příště držíš i ty sám)
- šablona docker-compose.yml pro jeden n8n klientský kontejner
  (vlastní port, vlastní N8N_ENCRYPTION_KEY, napojení na jeho
  vlastní databázi v Postgresu)
- šablona Apache VirtualHostu (HTTPS + websocket proxy pro n8n editor)

FÁZE 6 — provisioning skripty
- /opt/agenti/scripts/new-client.sh <jmeno>
  → najde volný port, vygeneruje heslo + encryption key,
    založí Postgres DB a uživatele s právy jen na svou DB,
    vytvoří a spustí docker-compose pro klienta,
    vytvoří a aktivuje Apache vhost, vyřídí certifikát,
    zapíše do clients.md, vypíše finální URL
- /opt/agenti/scripts/remove-client.sh <jmeno>
  → zazálohuje DB dumpem, zastaví a smaže kontejner, odebere vhost

FÁZE 7 — self-management (pro budoucí přístup z mobilu)
- zabal sám sebe (Claude Code) do Docker kontejneru se stejnou
  konfigurací, jakou používám na jiném serveru (p33.cz): mount
  /var/run/docker.sock, screen session se spuštěným
  `claude remote-control`, @reboot cron, co tu session po restartu
  nastartuje znovu
- ověř, že běžíš dál i po přesunu do kontejneru

FÁZE 8 — test
- spusť new-client.sh s testovacím klientem "test1"
- ověř, že n8n na jeho subdoméně naběhne přes HTTPS a websocket
  (živý náhled běhu workflow) funguje
- ukaž mi obsah clients.md a shrň, co všechno jsi po cestě nainstaloval
  a jaké výchozí volby jsi udělal tam, kde jsem ti nedal přesnou
  specifikaci

Postupuj fázi po fázi, po každé krátce napiš, co jsi udělal a co jsi
musel rozhodnout sám. Pokud narazíš na chybu, zkus ji opravit sám,
než se mě zeptáš.
```

Claude Code se tě po odeslání zeptá na doménu — odpovíš přímo v chatu (`agenti.tvojedomena.cz`) a potvrdíš, že DNS je nastavené. Dál už pokračuje sám.

---

## Co dělat s potvrzováním akcí

Claude Code se ve výchozím režimu bude občas ptát na potvrzení před rizikovými příkazy (instalace balíčků, změny firewallu apod.). Pro tenhle jednorázový bootstrap je to v pořádku nechat — je to čerstvý server, není co pokazit, a je dobré vidět, co přesně dělá.

Pokud chceš, ať běží plně autonomně bez přerušování (rychlejší, ale bez brzdy), spusť ho místo `claude` s:
```bash
claude --dangerously-skip-permissions
```
Použij to vědomě — název flagu není náhodný, agent pak provede i destruktivní příkazy bez ptaní. Na čerstvém VPS, kde ještě nic důležitého neběží, je to rozumný kompromis.

---

## Po dokončení — běžný provoz

Jakmile fáze 7 doběhne, budeš mít Claude Code natrvalo v kontejneru s remote-control přístupem — stejně jako na p33.cz. Nového klienta pak založíš buď:

```bash
docker exec -it claude-code-agenti bash
cd /workspace && ./scripts/new-client.sh jmeno-klienta
```

nebo prostě z mobilní appky napíšeš: *"Založ nového klienta 'firma-xyz'."*

---

## Kontrolní seznam po prvním běhu

- [ ] `docker ps` — Postgres + testovací n8n kontejner běží
- [ ] `https://test1.agenti.tvojedomena.cz` se otevře, certifikát je platný
- [ ] websocket v n8n editoru funguje (live náhled běhu workflow)
- [ ] `cat /opt/agenti/CLAUDE.md` — obsahuje všechny konvence, které agent zvolil
- [ ] `crontab -l` — `@reboot` záznam pro remote-control existuje
- [ ] zkusit `reboot` a ověřit, že se vše (Postgres, testovací n8n, Claude Code remote-control) samo nastartuje
- [ ] hesla a klíče v `.env` souborech mají práva `600` a nejsou v gitu

---

## Bezpečnostní poznámka

Po fázi 7 běží Claude Code v kontejneru s mountnutým `/var/run/docker.sock` — to mu dává fakticky root nad celým serverem (může spustit privilegovaný kontejner a "uniknout" na hosta). To je vědomý kompromis stejný jako máš na p33.cz — funguje to, ale nepouštěj do tohoto kontejneru nedůvěryhodný vstup (cizí prompty, nedůvěryhodná data ke zpracování).
