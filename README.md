# n8n multi-tenant starter

Startovací bod pro self-hosted multi-tenant n8n hosting na VPS, kde
architekturu (Apache, Postgres, Docker sítě, izolované klientské páry)
staví Claude Code na základě jednoho promptu.

## Architektura

Dvouvrstvý model:

- **Ops vrstva** (1× na server) — Claude Code s přístupem k `docker.sock`,
  spravuje celý server: zakládá/ruší klienty, upravuje Apache/Postgres.
  Nikdy nezasahuje přímo do dat konkrétního klienta.
- **Klientská vrstva** (1× pár na klienta) — `n8n-{klient}` +
  `claude-{klient}` ve vlastní izolované Docker síti `net-{klient}`.
  Klientský Claude Code mluví jen s n8n REST API svého souseda, nemá
  `docker.sock` ani přístup k jiným klientům.

Detailní diagram: [`docs/architektura.html`](docs/architektura.html)
(HTML soubor, otevírá se v prohlížeči).

## Obsah repozitáře

```
bootstrap.sh        — spustí se na čerstvém VPS, nainstaluje Claude Code
                       a předá mu řízení k postavení celé infrastruktury
docs/navod.md        — psaný návod k celému postupu, krok za krokem
docs/architektura.html — grafický diagram architektury
scripts/              — sem Claude Code při instalaci vygeneruje
                       new-client.sh / remove-client.sh / usage-report.sh
                       (viz níže)
```

`scripts/` je při prvním checkoutu prázdný — `new-client.sh`,
`remove-client.sh` a `usage-report.sh` nejsou psané ručně předem,
generuje je Claude Code sám během instalace (fáze 6 a 7 v `bootstrap.sh`)
podle stavu konkrétního serveru. Jakmile je vygeneruje, je vhodné je
commitnout do repa, aby byla verzovaná i tato část.

## Použití na čerstvém VPS

```bash
git clone https://github.com/p33cz/n8n-multi-tenant-starter.git /opt/agenti
cd /opt/agenti
chmod +x bootstrap.sh
sudo ./bootstrap.sh
```

Skript se zeptá na doménu a Anthropic API token, ověří DNS a spustí
Claude Code, který podle vloženého promptu postaví zbytek sám.

## Stav

Toto je startovací bod (bootstrap skript + prompt + diagram), ne
otestovaná produkční instalace. Po prvním běhu na reálném serveru
doporučeno:
- zkontrolovat vygenerované `CLAUDE.md`, `clients.md` a skripty ve
  `scripts/` a commitnout je
- projít bezpečnostní poznámky v `docs/navod.md`
- ověřit chování po `reboot` (automatický restart n8n/Postgres/ops
  kontejneru)

## Sledování spotřeby a paušál

Všichni `claude-{klient}` sdílejí jeden `ANTHROPIC_API_KEY`, takže
Anthropic fakturuje spotřebu jako celek, ne po klientech. Pokud klienti
platí paušál, který má náklady na AI pokrýt, je potřeba spotřebu
sledovat mimo Anthropic fakturaci — fáze 7 v `bootstrap.sh` proto
nechává Claude Code vygenerovat:

- `clients/{klient}/usage.log` — spotřeba tokenů daného klienta podle
  transkriptů jeho Claude Code relací
- `pricing.conf` — aktuální ceník modelů (per 1M tokenů), aby šel snadno
  aktualizovat
- `scripts/usage-report.sh` — přehled spotřeby a odhadované ceny per
  klient, s upozorněním, když se klient blíží limitu paušálu

Je to jen orientační odhad (na základě lokálních transkriptů, ne
oficiálního Anthropic vyúčtování) — pro přesná čísla použij Anthropic
Console.

## Bezpečnostní poznámka

`docker.sock` má mountnutý **jen** ops kontejner. Klientské
`claude-{klient}` kontejnery ho mít nesmí — to je jádro izolace mezi
klienty. Pokud se v generovaném compose souboru objeví
`claude-{klient}` s `docker.sock` mountem, jde o chybu, ne o feature.
