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
(otevři v prohlížeči).

## Obsah repozitáře

```
bootstrap.sh        — spustí se na čerstvém VPS, nainstaluje Claude Code
                       a předá mu řízení k postavení celé infrastruktury
docs/navod.md        — psaný návod k celému postupu, krok za krokem
docs/architektura.html — grafický diagram architektury
scripts/              — sem Claude Code při instalaci vygeneruje
                       new-client.sh / remove-client.sh (viz níže)
```

`scripts/` je při prvním checkoutu prázdný — `new-client.sh` a
`remove-client.sh` nejsou psané ručně předem, generuje je Claude Code
sám během instalace (fáze 6 v `bootstrap.sh`) podle stavu konkrétního
serveru. Jakmile je vygeneruje, commitni je do repa, ať máš verzovanou
i tuhle část.

## Použití na čerstvém VPS

```bash
git clone <tvoje-repo-url> /opt/agenti
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

## Bezpečnostní poznámka

`docker.sock` má mountnutý **jen** ops kontejner. Klientské
`claude-{klient}` kontejnery ho mít nesmí — to je jádro izolace mezi
klienty. Pokud někdy najdeš v generovaném compose souboru
`claude-{klient}` s `docker.sock` mountem, je to chyba, ne feature.
