#!/usr/bin/env bash
# entrypoint pro app-{klient}-{appka}. Spouští se při každém startu kontejneru.
#
# Pokud claude-{klient} (nebo kdokoli s přístupem k /code) napsal do sdíleného
# kódu spustitelný /code/start.sh, spustí se ten — appka musí naslouchat na
# portu 8080. Dokud start.sh neexistuje, běží jen placeholder stránka, ať má
# appka od začátku funkční (byť prázdnou) veřejnou adresu.
set -euo pipefail

CODE_DIR=/code

if [ -x "$CODE_DIR/start.sh" ]; then
  echo "[entrypoint] spouštím $CODE_DIR/start.sh"
  cd "$CODE_DIR"
  exec "$CODE_DIR/start.sh"
fi

if [ -f "$CODE_DIR/start.sh" ]; then
  echo "[entrypoint] $CODE_DIR/start.sh existuje, ale není spustitelný (chmod +x) — běží placeholder"
else
  echo "[entrypoint] $CODE_DIR/start.sh zatím neexistuje — běží placeholder na portu 8080"
fi
exec python3 -m http.server 8080 --directory /placeholder
