# Návod k instalaci

Podrobný postup instalace [n8n multi-tenant starter](../README.md) na
čerstvý VPS. Co projekt dělá a jak funguje jeho architektura popisuje
[`README.md`](../README.md#jak-to-funguje) — tenhle dokument se
soustředí jen na samotnou instalaci a provoz.

## Co je potřeba předem

- VPS s Debianem 12 nebo Ubuntu 24.04, min. 4 vCPU / 8 GB RAM, se
  známou veřejnou IP adresou
- doména, u které jde nastavit wildcard DNS A záznam (`*.doména` →
  IP serveru) — bez toho nepůjde vydat SSL certifikát pro subdomény
  klientů
- Anthropic API token

## Instalace

Na čerstvém VPS, přihlášený jako root:

```bash
git clone https://github.com/p33cz/n8n-multi-tenant-starter.git /opt/n8n-mts
cd /opt/n8n-mts
chmod +x bootstrap.sh
sudo ./bootstrap.sh
```

Skript se zeptá na doménu a Anthropic API token, ověří DNS, nainstaluje
Node.js a Claude Code CLI a pak mu předá řízení s kompletními
instrukcemi. **Od tohoto bodu je instalace plně automatická** — žádný
prompt se nikam ručně nekopíruje, Claude Code postupuje sám podle
instrukcí zabudovaných v `bootstrap.sh` (proměnná `PROMPT`).

Claude Code si sám zjistí stav serveru, doinstaluje chybějící software
a postupně postaví:

1. základní zabezpečení serveru (firewall, fail2ban)
2. Docker a izolované sítě
3. Postgres databázi
4. Apache jako reverzní proxy s HTTPS certifikáty
5. šablony a konvence (zapsané do `CLAUDE.md`, aby se jich držel i
   příště)
6. provisioning skripty `new-client.sh` / `remove-client.sh`
7. sledování spotřeby AI per klient (`usage.log`, `pricing.conf`,
   `usage-report.sh`)
8. self-management — sám sebe zabalí do trvale běžícího kontejneru
   s přístupem přes `claude remote-control` (i po `reboot`)
9. test na zkušebním klientovi

Po každé fázi Claude Code stručně napíše, co udělal a jaké výchozí
volby zvolil tam, kde instrukce nedávaly přesnou specifikaci.

### Interaktivně, nebo plně autonomně

Skript se na konci zeptá, jak má Claude Code běžet:

- **interaktivně** — před rizikovými kroky (instalace balíčků, změny
  firewallu apod.) se zeptá na potvrzení; doporučeno pro první běh
- **plně autonomně** (`--dangerously-skip-permissions`) — projede
  vše bez ptaní, rychlejší, ale bez brzdy. Na čerstvém VPS, kde ještě
  nic důležitého neběží, je to rozumný kompromis — ale je to vědomá
  volba, ne výchozí chování.

## Pojmenování a konvence

Skripty se drží pevné konvence — užitečné vědět, než založíš prvního
klienta, i při čtení výstupu příkazů níž. `{klient}` a `{appka}` jsou
jména, která zadáváš skriptům; `{domena}` je doména zadaná při
instalaci (uložená v `domain.env`).

| Věc | Konvence |
|-----|----------|
| Subdoména klienta | `{klient}.{domena}` |
| Subdoména appky | `{klient}-{appka}.{domena}` (plochá, ne druhá úroveň) |
| Kontejner n8n | `n8n-{klient}` |
| Kontejner Claude Code klienta | `claude-{klient}` |
| Kontejner appky | `app-{klient}-{appka}` |
| Klientská síť | `net-{klient}` (izolovaná, jen tenhle klient + Postgres) |
| n8n host port | od **5679** výš, jen `127.0.0.1` |
| Port appky | od **6679** výš, jen `127.0.0.1` |
| Databáze klienta | `db_{klient}` |
| DB uživatel | `u_{klient}` (práva jen na svou DB) |
| Jméno klienta/appky | `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$` (malá písmena, číslice, pomlčka) |

Evidence běžících klientů/appek je v `clients.md` / `apps.md` v
`/opt/n8n-mts/`. Obsahují reálná jména klientů a doménu konkrétního
nasazení, proto jsou úmyslně v `.gitignore` — do veřejného repa
nepatří, skripty si je při prvním použití samy založí.

## Po dokončení — běžný provoz

Po instalaci běží ops Claude Code natrvalo v kontejneru s
remote-control přístupem. Nového klienta pak založí buď příkaz:

```bash
docker exec -it claude-code-n8n-mts bash
cd /workspace && ./scripts/new-client.sh jmeno-klienta
```

nebo věta napsaná Claude Code asistentovi (třeba z mobilu): *"Založ
nového klienta 'firma-xyz'."*

### Seznam všech klientů

Evidence klientů (jméno, port, síť, kdy založen, měsíční paušál) je v
`clients.md`:

```bash
cat /opt/n8n-mts/clients.md
```

Pro ověření proti realitě na serveru (kdyby se evidence někdy rozešla
se skutečností):

```bash
ls /opt/n8n-mts/clients/          # adresáře = provizovaní klienti
docker ps --filter "name=n8n-"    # skutečně běžící n8n kontejnery
```

### Přihlášení do n8n konkrétního klienta

Přihlašovací účet (owner) vytváří `new-client.sh` automaticky. Údaje
jsou v jeho `.env`:

```bash
grep N8N_OWNER /opt/n8n-mts/clients/jmeno-klienta/.env
```

Přihlášení pak proběhne na `https://jmeno-klienta.<doména>` tímto
emailem a heslem. `.env` má práva `600` (jen root) — hodnoty z něj by
se neměly nikam kopírovat (ani do chatu s AI asistentem).

### Práce na workflow konkrétního klienta

Workflow za klienta staví/upravuje provozovatel, přes jeho
`claude-{klient}` — klient sám do Claude nikdy nevstupuje, vidí jen
hotové n8n:

```bash
docker exec -it claude-jmeno-klienta bash
claude
```

Tahle instance má už nastavené `N8N_API_URL`/`N8N_API_KEY`, takže může
rovnou vytvářet a upravovat workflow v n8n toho jednoho klienta —
a díky síťové izolaci se nemůže (ani omylem) dostat k žádnému jinému.

### Sledování spotřeby a nákladů

```bash
/opt/n8n-mts/scripts/usage-report.sh                # přehled za všechny klienty
/opt/n8n-mts/scripts/usage-report.sh jmeno-klienta   # jen jeden klient
```

Vypíše spotřebu tokenů, odhadovanou cenu podle `pricing.conf` a (pokud
je v `clients.md` vyplněný paušál) i kolik % paušálu spotřeba
představuje. Klienti nad 80 % paušálu jsou ve výstupu zvýrazněni.

### Kontrola stavu kontejnerů a logů

```bash
docker ps -a                          # stav všech kontejnerů (běží/spadlé)
docker logs --tail 50 n8n-jmeno-klienta
docker logs --tail 50 claude-jmeno-klienta
```

### Zrušení klienta

```bash
/opt/n8n-mts/scripts/remove-client.sh jmeno-klienta
```

Před smazáním se udělá dump databáze a `usage.log` se přesune do
archivu — historie spotřeby zůstane dohledatelná i po zrušení klienta.

### Správa appek klienta

Kromě n8n může mít klient i vlastní webové appky — stará se o ně stejný
`claude-{klient}`, co spravuje jeho n8n, ne samostatný agent navíc.

**Založení appky:**
```bash
/opt/n8n-mts/scripts/new-app.sh jmeno-klienta nazev-appky
```
Appka dostane vlastní kontejner ve stejné izolované síti jako klient,
veřejnou adresu `https://jmeno-klienta-nazev-appky.<doména>` a kód appky
sdílí s `claude-jmeno-klienta` přes `/apps/nazev-appky/code/`. Appka
naběhne, jakmile v tomhle adresáři vznikne spustitelný `start.sh`
naslouchající na portu 8080 — do té doby běží jen placeholder stránka.

U klientů založených před touhle funkcí `new-app.sh` napoprvé sám
jednorázově doplní chybějící propojení (přegeneruje a restartuje jen
`claude-{klient}`, `n8n-{klient}` se nedotkne).

**Psaní kódu appky:** stejně jako u workflow — mluvíš s `claude-jmeno-klienta`
(`docker exec -it claude-jmeno-klienta bash` → `claude`), appka je zapsaná
v jeho `CLAUDE.md`, takže o ní ví automaticky.

**Seznam appek:**
```bash
cat /opt/n8n-mts/apps.md
```

**Zrušení appky:**
```bash
/opt/n8n-mts/scripts/remove-app.sh jmeno-klienta nazev-appky
```
Kód appky se před smazáním zazálohuje do archivu; kontejnery a síť
klienta samotného se nedotýká.

## Kontrolní seznam po prvním běhu

- [ ] `docker ps` — Postgres + testovací n8n kontejner běží
- [ ] testovací subdoména se otevře přes HTTPS, certifikát je platný
- [ ] websocket v n8n editoru funguje (live náhled běhu workflow)
- [ ] `cat /opt/n8n-mts/CLAUDE.md` — obsahuje všechny konvence, které agent zvolil
- [ ] `crontab -l` — `@reboot` záznam pro remote-control existuje
- [ ] `crontab -l` v testovacím klientském kontejneru — hodinová úloha pro zápis do `usage.log` existuje
- [ ] `/opt/n8n-mts/scripts/usage-report.sh <klient>` vypíše odhadovanou spotřebu a cenu
- [ ] `reboot` a ověřit, že se vše (Postgres, testovací n8n, Claude Code remote-control) samo nastartuje
- [ ] hesla a klíče v `.env` souborech mají práva `600` a nejsou v gitu

## Bezpečnostní poznámka

Ops vrstva běží v kontejneru s mountnutým `/var/run/docker.sock` — to
jí dává fakticky root nad celým serverem (může spustit privilegovaný
kontejner a "uniknout" na hosta). Je to vědomý kompromis, který
umožňuje spravovat celý server i klienty na dálku — funguje to, ale do
tohoto kontejneru by se neměl pouštět nedůvěryhodný vstup (cizí
prompty, nedůvěryhodná data ke zpracování).

Klientské `claude-{klient}` kontejnery `docker.sock` mít nesmí — to je
jádro izolace mezi klienty.

## Poznámka k `claude remote-control`

`claude remote-control` (ovládání Claude Code z mobilu) funguje jen po
přihlášení přes claude.ai účet (subscription) — **ne** s pouhým
`ANTHROPIC_API_KEY`. Instalace jej u ops vrstvy i u každého klienta
připraví (screen session, retry smyčka), ale dokud se jednorázově
nepřihlásíš (`claude /login`) a neuložíš přihlašovací údaje na místo,
které agent při instalaci určí, zůstane neaktivní. Zbytek provizování
(izolace klientů, n8n, sledování spotřeby) na tomhle přihlášení
nezávisí a funguje bez něj.

Před zapnutím remote-control je potřeba ověřit, jak se přihlášení přes
osobní subscription slučuje s tím, že spotřeba a paušál se počítají
podle `ANTHROPIC_API_KEY` — otevřená otázka je, jestli přihlášení
nezmění, na čí účet se daná instance započítává (sledováno v
[Issue #2](https://github.com/p33cz/n8n-multi-tenant-starter/issues/2)).
