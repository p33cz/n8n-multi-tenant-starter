# app-runtime — generický kontejner pro appky klientů.
# NIKDY nedostává docker.sock. Sedí jen v síti net-{klient}, sdílí kód
# s claude-{klient} přes bind mount /code (host: clients/{klient}/apps/{appka}/code).
FROM node:22-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 ca-certificates curl tini \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /code

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY placeholder/ /placeholder/
RUN chmod +x /usr/local/bin/entrypoint.sh

# Appka musí naslouchat na 8080 uvnitř kontejneru — ven ji vystavuje
# Apache vhost (stejný vzor jako u n8n: publikováno jen na 127.0.0.1:{port}).
EXPOSE 8080

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
