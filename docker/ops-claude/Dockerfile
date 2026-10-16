# ops-claude — the OPS layer (this Claude Code) packaged into a
# permanently running container claude-code-n8n-mts. The ONLY
# container allowed to touch docker.sock.
FROM n8n-mts/claude-agent:latest

# Docker CLI + compose plugin (the ops layer drives Docker through the mounted socket)
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
