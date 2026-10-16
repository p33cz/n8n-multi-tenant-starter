# Installation guide

🇬🇧 English · [🇨🇿 Čeština](navod.md)

A detailed walkthrough for installing [n8n multi-tenant starter](../README.en.md)
on a fresh VPS. What the project does and how its architecture works is
described in [`README.en.md`](../README.en.md#how-it-works) — this
document focuses only on the install and day-to-day operation
themselves.

## Prerequisites

- a VPS running Debian 12 or Ubuntu 24.04, min. 4 vCPU / 8 GB RAM, with
  a known public IP address
- a domain where you can set a wildcard DNS A record (`*.domain` →
  the server's IP) — without it you won't be able to issue an SSL
  certificate for client subdomains
- an Anthropic API token

## Installation

On a fresh VPS, logged in as root:

```bash
git clone https://github.com/p33cz/n8n-multi-tenant-starter.git /opt/n8n-mts
cd /opt/n8n-mts
chmod +x bootstrap.sh
sudo ./bootstrap.sh
```

The script asks for a domain and an Anthropic API token, verifies DNS,
installs Node.js and the Claude Code CLI, and then hands it control
with complete instructions. **From this point the install is fully
automatic** — no prompt gets copied anywhere by hand; Claude Code
proceeds on its own, following the instructions embedded in
`bootstrap.sh` (the `PROMPT` variable).

Claude Code figures out the server's state itself, installs whatever
software is missing, and builds, step by step:

1. basic server hardening (firewall, fail2ban)
2. Docker and isolated networks
3. a Postgres database
4. Apache as a reverse proxy with HTTPS certificates
5. templates and conventions (written into `OPS.md`, so it can stick
   to them next time too)
6. the provisioning scripts `new-client.sh` / `remove-client.sh`
7. per-client AI usage tracking (`usage.log`, `pricing.conf`,
   `usage-report.sh`)
8. self-management — packages itself into a container that keeps
   running, reachable through `claude remote-control` (surviving a
   `reboot` too)
9. a test on a trial client

After each phase Claude Code briefly writes what it did and which
default choices it made wherever the instructions didn't give an exact
specification.

### Interactive, or fully autonomous

At the end the script asks how Claude Code should run:

- **interactively** — it asks for confirmation before risky steps
  (installing packages, changing the firewall, etc.); recommended for
  the first run
- **fully autonomous** (`--dangerously-skip-permissions`) — runs
  through everything without asking, faster but with no brake. On a
  fresh VPS where nothing important is running yet, that's a
  reasonable trade-off — but it's a conscious choice, not the default
  behavior.

## Naming and conventions

The scripts stick to a fixed convention — useful to know before you
set up your first client, and when reading the output of the commands
below. `{client}` and `{app}` are names you pass to the scripts;
`{domain}` is the domain given during install (stored in `domain.env`).

| Thing | Convention |
|-------|------------|
| Client subdomain | `{client}.{domain}` |
| App subdomain | `{client}-{app}.{domain}` (flat, not a second level) |
| n8n container | `n8n-{client}` |
| Client's Claude Code container | `claude-{client}` |
| App container | `app-{client}-{app}` |
| Client network | `net-{client}` (isolated, just this client + Postgres) |
| n8n host port | from **5679** up, `127.0.0.1` only |
| App port | from **6679** up, `127.0.0.1` only |
| Client database | `db_{client}` |
| DB user | `u_{client}` (rights on its own DB only) |
| Client/app name | `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$` (lowercase letters, digits, hyphen) |

The record of running clients/apps lives in `clients.md` / `apps.md`
under `/opt/n8n-mts/`. They contain real client names and the domain
of the specific deployment, so they're deliberately in `.gitignore` —
they don't belong in the public repo; the scripts create them
themselves on first use.

## After the install — day-to-day operation

After installation, the ops Claude Code keeps running permanently in a
container with remote-control access. It then sets up a new client
either via the command:

```bash
docker exec -it claude-code-n8n-mts bash
cd /workspace && ./scripts/new-client.sh client-name
```

or a sentence written to the Claude Code assistant (say, from your
phone): *"Set up a new client 'acme-corp'."*

### Listing all clients

The client record (name, port, network, when created, monthly flat
fee) is in `clients.md`:

```bash
cat /opt/n8n-mts/clients.md
```

To verify it against reality on the server (in case the record ever
drifts from what's actually there):

```bash
ls /opt/n8n-mts/clients/          # directories = provisioned clients
docker ps --filter "name=n8n-"    # n8n containers actually running
```

### Logging into a specific client's n8n

The login account (owner) is created automatically by `new-client.sh`.
Its credentials are in its `.env`:

```bash
grep N8N_OWNER /opt/n8n-mts/clients/client-name/.env
```

Login then happens at `https://client-name.<domain>` with that email
and password. `.env` has `600` permissions (root only) — its values
shouldn't be copied anywhere (not even into a chat with an AI
assistant).

### Working on a specific client's workflow

Workflows are built/edited for a client by the operator, through that
client's `claude-{client}` — the client themselves never enters Claude
directly, they only see the finished n8n:

```bash
docker exec -it claude-client-name bash
claude
```

This instance already has `N8N_API_URL`/`N8N_API_KEY` configured, so
it can go straight to creating and editing workflows in that one
client's n8n — and thanks to network isolation it cannot reach any
other client, not even by accident.

### Tracking usage and costs

```bash
/opt/n8n-mts/scripts/usage-report.sh                # overview for all clients
/opt/n8n-mts/scripts/usage-report.sh client-name     # just one client
```

Prints token usage, an estimated price based on `pricing.conf`, and
(if a flat fee is filled in in `clients.md`) what percentage of the
flat fee that usage represents. Clients above 80% of their flat fee
are highlighted in the output.

### Checking container status and logs

```bash
docker ps -a                          # status of all containers (running/crashed)
docker logs --tail 50 n8n-client-name
docker logs --tail 50 claude-client-name
```

### Backups and restore

Every active client (**Stav**/Status column in `clients.md` = `active`)
is backed up automatically, once a day at 3:00 AM
(`/etc/cron.d/n8n-mts-backup`, installed automatically by both
`deploy-ops.sh` and `new-client.sh` — see `ensure_backup_cron` in
`lib.sh`, so it self-installs on an already-running server too). A
backup is one archive per run,
`clients/{client}/backups/{client}-{STAMP}.tar.gz`, mode `600` (it
holds passwords and encrypted credentials, must not be readable by
anyone else):

- `db.dump` — `pg_dump -Fc` (custom format, restored with `pg_restore`)
- `files/` — a copy of all of `clients/{client}/` except `backups/`
  itself: `.env` (`N8N_ENCRYPTION_KEY`), apps (`apps/*/code/`), compose files
- `volumes/*.tar` — the client's docker volumes (`n8n-{client}-data`,
  `claude-{client}-workspace`)
- `MANIFEST` — what's inside and from when

The 14 most recent archives per client are kept (rotation). If any
client's backup fails, the script says so and exits non-zero — check
`/var/log/n8n-mts-backup.log`.

Manual backup any time:
```bash
/opt/n8n-mts/scripts/backup-clients.sh                 # every active client
/opt/n8n-mts/scripts/backup-clients.sh client-name      # just one (even inactive)
```

**Dry-run restore** (try it before you ever need it for real):
```bash
cd /opt/n8n-mts/clients/client-name/backups
ARCHIVE=LATEST.tar.gz   # substitute the actual file name
mkdir -p /tmp/restore-test && tar -xzf "$ARCHIVE" -C /tmp/restore-test

# DB into a TEMPORARY database (not straight into the live db_client-name!)
docker exec -i n8n-mts-postgres psql -U postgres -c "CREATE DATABASE restore_test;"
docker exec -i n8n-mts-postgres pg_restore -U postgres -d restore_test < /tmp/restore-test/db.dump

# verify the content loaded
docker exec -i n8n-mts-postgres psql -U postgres restore_test -c "SELECT count(*) FROM workflow_entity;"

# clean up
docker exec -i n8n-mts-postgres psql -U postgres -c "DROP DATABASE restore_test;"
rm -rf /tmp/restore-test
```

**Real restore of an existing client** (after a data incident, the
client is still in `clients.md`). The DB is never loaded into the
live, populated database — a full dump has no `--clean` and would
collide with the objects already there:
```bash
CLIENT=client-name
ARCHIVE=/opt/n8n-mts/clients/$CLIENT/backups/LATEST.tar.gz   # substitute

docker stop "n8n-$CLIENT" "claude-$CLIENT"
mkdir -p "/tmp/restore-$CLIENT" && tar -xzf "$ARCHIVE" -C "/tmp/restore-$CLIENT"

# DB: DROP + CREATE (not loading into the existing one)
docker exec -i n8n-mts-postgres psql -U postgres -c "DROP DATABASE IF EXISTS db_$CLIENT WITH (FORCE);"
docker exec -i n8n-mts-postgres psql -U postgres -c "CREATE DATABASE db_$CLIENT OWNER u_$CLIENT;"
docker exec -i n8n-mts-postgres psql -U postgres -c "REVOKE CONNECT ON DATABASE db_$CLIENT FROM PUBLIC;"
docker exec -i n8n-mts-postgres psql -U postgres -c "GRANT CONNECT ON DATABASE db_$CLIENT TO u_$CLIENT;"
docker exec -i n8n-mts-postgres pg_restore -U postgres -d "db_$CLIENT" < "/tmp/restore-$CLIENT/db.dump"

# files (apps, .env) — diff against the live ones before overwriting anything
diff -rq "/tmp/restore-$CLIENT/files/" "clients/$CLIENT/"
cp -a "clients/$CLIENT" "/tmp/clients-$CLIENT-before-restore"   # safety net
cp -a "/tmp/restore-$CLIENT/files/." "clients/$CLIENT/"

# volumes
for V in "n8n-$CLIENT-data" "claude-$CLIENT-workspace"; do
  [ -f "/tmp/restore-$CLIENT/volumes/$V.tar" ] || continue
  docker run --rm -v "$V":/v -v "/tmp/restore-$CLIENT/volumes":/b:ro alpine \
    sh -c "rm -rf /v/* && tar -C /v -xf /b/$V.tar"
done

docker start "n8n-$CLIENT" "claude-$CLIENT"
rm -rf "/tmp/restore-$CLIENT"
```

**Total loss of a client** (network, role, directory — everything
gone): first run `scripts/new-client.sh client-name` again to recreate
a clean skeleton (network, DB role, empty DB, containers, vhost,
certificate), then follow the "real restore of an existing client"
steps above — they'll overwrite the empty DB and default files with
the backup's content.

### Removing a client

```bash
/opt/n8n-mts/scripts/remove-client.sh client-name
```

Before deletion a database dump is taken and `usage.log` is moved to
the archive — the usage history stays traceable even after the client
is removed.

### Managing a client's apps

Besides n8n, a client can also have their own web apps — managed by
the same `claude-{client}` that manages their n8n, not a separate
extra agent.

**Setting up an app:**
```bash
/opt/n8n-mts/scripts/new-app.sh client-name app-name
```
The app gets its own container in the same isolated network as the
client, a public address `https://client-name-app-name.<domain>`, and
shares its code with `claude-client-name` through
`/apps/app-name/code/`. At runtime the app decides for itself, based
on this directory's contents, how to start — nothing is chosen in
advance:
1. an executable `start.sh` listening on port 8080 → that one runs
   (your own code in Node/Python/whatever)
2. otherwise the directory has anything else in it → the app serves it
   itself through Apache + PHP (static HTML/CSS as well as PHP work
   out of the box; Apache also serves, by default, only known-safe
   file types — see [Security note](#security-note))
3. the directory is empty → just the placeholder page runs

An app can also have several "sites" as subdirectories
(`code/site-a/`, `code/site-b/`) — each one shows up at
`https://client-name-app-name.<domain>/site-a` etc., purely a matter
of file structure, nothing to configure for it.

An app has no SSH by default — its contents are managed by
`claude-client-name` through the bind mount above. If you need
something external to fill the app (typically an n8n workflow, which
can't do a bind mount, only SSH), turn it on separately:
```bash
/opt/n8n-mts/scripts/enable-app-ssh.sh client-name app-name
```
It prints the login credentials (host = the app container's name,
reachable only from the client's own network, not from outside) to
enter into an n8n SSH credential.

For clients set up before this feature existed, `new-app.sh` fills in
the missing wiring itself the first time (regenerates and restarts
just `claude-{client}`, `n8n-{client}` is left untouched).

**Writing an app's code:** same as with a workflow — you talk to
`claude-client-name` (`docker exec -it claude-client-name bash` →
`claude`), the app is recorded in its `CLAUDE.md`, so it knows about
it automatically.

**Listing apps:**
```bash
cat /opt/n8n-mts/apps.md
```

**Removing an app:**
```bash
/opt/n8n-mts/scripts/remove-app.sh client-name app-name
```
The app's code is backed up to the archive before deletion; the
client's own containers and network are left untouched.

## Checklist after the first run

- [ ] `docker ps` — Postgres + the test n8n container are running
- [ ] the test subdomain opens over HTTPS, the certificate is valid
- [ ] the websocket in the n8n editor works (live preview of a running workflow)
- [ ] `cat /opt/n8n-mts/OPS.md` — contains all the conventions the agent chose
- [ ] `crontab -l` — an `@reboot` entry for remote-control exists
- [ ] `crontab -l` in the test client container — an hourly job writing to `usage.log` exists
- [ ] `/opt/n8n-mts/scripts/usage-report.sh <client>` prints an estimated usage and price
- [ ] `reboot`, and verify that everything (Postgres, test n8n, Claude Code remote-control) starts back up on its own
- [ ] passwords and keys in `.env` files have `600` permissions and aren't in git

## Security note

The ops layer runs in a container with `/var/run/docker.sock`
mounted — that effectively gives it root over the whole server (it
could launch a privileged container and "escape" to the host). This
is a deliberate trade-off that allows managing the whole server and
its clients remotely — it works, but untrusted input (someone else's
prompts, untrusted data to process) shouldn't be let into this
container.

Client `claude-{client}` containers must never get `docker.sock` —
that's the core of the isolation between clients.

Apache also has a catch-all vhost (`000-catchall`, set up by
`new-client.sh` itself) — without it, a request to a deleted/
nonexistent subdomain would fall through to the first vhost in order
and show someone else's n8n with someone else's certificate, instead
of returning a 404.

**Memory limits**: `n8n-{client}` (2 GB), `claude-{client}` and apps
(512 MB–1 GB) carry a `mem_limit` in the templates, so one client
(e.g. a runaway workflow) can't exhaust the whole server's memory and
take everyone else down with it. Postgres is shared across every
client, so it's deliberately left unlimited. This only applies to
newly created clients/apps — an already-running one only picks it up
after its `docker-compose.yml` is regenerated and recreated
(`docker compose up -d`).

Optionally, outside this repo (it's a Docker daemon setting, not a
project one): `"live-restore": true` in `/etc/docker/daemon.json`
lets containers survive a restart/upgrade of `dockerd` itself (e.g.
an `apt upgrade` of the `docker-ce` package) — without it, restarting
Docker restarts every container at once.

**Apps**: an app can internally have several "sites" as
subdirectories, and some of them may store supporting data there
(settings, hashed passwords) — that data physically sits in the same
directory the app serves out, so it doesn't rely on the site/app
remembering to protect it itself. Apache inside an app therefore
defaults to an **allowlist** (serves only known-safe types —
HTML/CSS/JS/images/fonts/PHP, nothing else), not a blacklist of
specific filenames — anything an app saves under a different type
(`.json`, `.db`, no extension...) is unreachable over the URL, no
matter what it's called. SSH deploy access (`enable-app-ssh.sh`) is
also off until you explicitly turn it on, and always confined to that
one app.

## Note on `claude remote-control`

`claude remote-control` (controlling Claude Code from your phone) only
works after logging in through a claude.ai account (subscription) —
**not** with a plain `ANTHROPIC_API_KEY`. Installation sets it up for
both the ops layer and every client (a screen session, a retry loop),
but until you log in once (`claude /login`) and save the credentials
to the location the agent decides on during install, it stays
inactive. The rest of provisioning (client isolation, n8n, usage
tracking) doesn't depend on this login and works without it.

Before turning remote-control on, it's worth verifying how logging in
with a personal subscription interacts with usage and the flat fee
being calculated from `ANTHROPIC_API_KEY` — the open question is
whether logging in changes whose account a given instance counts
against (tracked in
[Issue #2](https://github.com/p33cz/n8n-multi-tenant-starter/issues/2)).
