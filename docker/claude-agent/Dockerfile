# claude-agent — per-client Claude Code container.
# NEVER gets docker.sock. Only talks to its client's n8n REST API
# over the internal hostname in their shared network net-{client}.
FROM node:22-bookworm-slim

# Tools: screen (remote-control session), cron (usage tracking),
# jq (transcript parsing), curl/ca-certificates (n8n API), tini (PID 1).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl jq screen cron procps tini git \
 && rm -rf /var/lib/apt/lists/*

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code \
 && npm cache clean --force

WORKDIR /workspace

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY usage-collect.sh /usr/local/bin/usage-collect.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/usage-collect.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
