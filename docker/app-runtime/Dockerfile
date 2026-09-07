# app-runtime — generický kontejner pro appky klientů.
# NIKDY nedostává docker.sock. Sedí jen v síti net-{klient}, sdílí kód
# s claude-{klient} přes bind mount (host: clients/{klient}/apps/{appka}/code).
#
# Appka sama za běhu pozná, jak se má spustit (entrypoint.sh):
#   1) spustitelný code/start.sh existuje  → spustí se ten (vlastní Node/Python/cokoliv)
#   2) jinak, code/ není prázdný           → Apache (mod_php) servíruje code/
#   3) jinak                               → placeholder stránka
# SSH deploy přístup (pro n8n workflow, ne pro claude-{klient} — ten má bind
# mount) je vypnutý, dokud ho scripts/enable-app-ssh.sh nezapne.
FROM node:22-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 ca-certificates curl tini \
      apache2 libapache2-mod-php php-cli \
      openssh-server \
 && rm -rf /var/lib/apt/lists/*

# Apache musí naslouchat na 8080 (appka vždycky poslouchá na 8080, ven ji
# vystavuje Apache vhost hostitele — stejný vzor jako u n8n).
RUN sed -i 's/^Listen 80$/Listen 8080/' /etc/apache2/ports.conf

COPY apache-app.conf /etc/apache2/sites-available/000-app.conf
RUN a2dissite 000-default >/dev/null 2>&1 || true; a2ensite 000-app >/dev/null

# SSH deploy uživatel appdeploy (viz entrypoint.sh + enable-app-ssh.sh) —
# BEZ chrootu: appka je sama ve vlastním kontejneru bez cizích dat (žádný
# jiný klient/appka tu nic nemá), takže tu není co dalšího chránit. Home
# = /code, normální shell, ať fungují i příkazy z workflow (mkdir, chmod,
# php -l), ne jen SFTP upload.
RUN useradd -m -d /code -s /bin/bash appdeploy

WORKDIR /code

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY placeholder/ /placeholder/
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080 22

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
