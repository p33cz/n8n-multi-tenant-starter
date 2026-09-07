# ops-claude — OPS vrstva (tato Claude Code) zabalená do trvale běžícího
# kontejneru claude-code-n8n-mts. JEDINÝ kontejner se smí dotknout docker.sock.
FROM n8n-mts/claude-agent:latest

# Docker CLI + compose plugin (ops vrstva řídí Docker přes mountnutý socket)
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && . /etc/os-release \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $VERSION_CODENAME stable" > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin apache2-utils certbot python3-certbot-apache \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
COPY entrypoint-ops.sh /usr/local/bin/entrypoint-ops.sh
RUN chmod +x /usr/local/bin/entrypoint-ops.sh
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint-ops.sh"]
