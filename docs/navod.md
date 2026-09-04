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

## Po dokončení — běžný provoz

Po instalaci běží ops Claude Code natrvalo v kontejneru s
remote-control přístupem. Nového klienta pak založí buď příkaz:

```bash
docker exec -it claude-code-n8n-mts bash
cd /workspace && ./scripts/new-client.sh jmeno-klienta
```

nebo věta napsaná Claude Code asistentovi (třeba z mobilu): *"Založ
nového klienta 'firma-xyz'."*

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
