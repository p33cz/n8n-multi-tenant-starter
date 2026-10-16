# app-runtime — generic container for client apps.
# NEVER gets docker.sock. Sits only in net-{client}, shares code with
# claude-{client} via a bind mount (host: clients/{client}/apps/{app}/code).
#
# An app figures out at runtime how it should start (entrypoint.sh):
#   1) an executable code/start.sh exists  → that one runs (your own Node/Python/whatever)
#   2) otherwise, code/ isn't empty        → Apache (mod_php) serves code/
#   3) otherwise                           → the placeholder page
# SSH deploy access (for an n8n workflow, not for claude-{client} — it
# has the bind mount) is off until scripts/enable-app-ssh.sh turns it on.
FROM node:22-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 ca-certificates curl tini \
      apache2 libapache2-mod-php php-cli \
      openssh-server \
 && rm -rf /var/lib/apt/lists/*

# Apache must listen on 8080 (an app always listens on 8080; the
# host's Apache vhost is what exposes it — same pattern as with n8n).
RUN sed -i 's/^Listen 80$/Listen 8080/' /etc/apache2/ports.conf

COPY apache-app.conf /etc/apache2/sites-available/000-app.conf
RUN a2dissite 000-default >/dev/null 2>&1 || true; a2ensite 000-app >/dev/null

# SSH deploy user appdeploy (see entrypoint.sh + enable-app-ssh.sh) —
# NO chroot: the app sits alone in its own container with no other
# data in it (no other client/app has anything here), so there's
# nothing else to protect. Home = /code, a normal shell, so commands
# from a workflow (mkdir, chmod, php -l) work too, not just SFTP upload.
RUN useradd -m -d /code -s /bin/bash appdeploy

WORKDIR /code

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY placeholder/ /placeholder/
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080 22

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
