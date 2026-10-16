# n8n multi-tenant starter — instructions for Claude Code

This file is loaded automatically at the start of every Claude Code
session run in this directory. It's **committed and generic** — it
holds equally on a fresh checkout and on a live server. Never write
anything specific to one deployment here (a real domain, client names,
an IP) — that's what `OPS.md` is for (see the import at the end,
gitignored, created only on a server).

## What this is

A starter kit for self-hosted multi-tenant n8n hosting on a VPS — a
two-layer architecture (an ops layer manages the server, each client
gets an isolated `n8n-{client}` + `claude-{client}` pair, with
optional apps on top). Full description: [`README.en.md`](README.en.md)
(Czech original: [`README.md`](README.md)). Step-by-step and
operational reference: [`docs/guide.en.md`](docs/guide.en.md) (Czech:
[`docs/navod.md`](docs/navod.md)).

## Before you change anything

1. `git log --oneline -20` — what happened here most recently.
2. Open [GitHub Issues](https://github.com/p33cz/n8n-multi-tenant-starter/issues)
   — work in progress and unresolved decisions.
3. `README.en.md` → `Repository structure` — what's a finished reference
   implementation (`scripts/`, `templates/`, `docker/`) versus what's
   only generated at runtime (`clients.md`, `apps.md`, `OPS.md` —
   gitignored).

## Key conventions (details in `docs/guide.en.md`)

- `{client}.{domain}` (client subdomain), `{client}-{app}.{domain}`
  (app, flat, not a second level) — name regex: `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`
- `n8n-{client}` + `claude-{client}` in an isolated network
  `net-{client}`; apps (`app-{client}-{app}`) in the same network. None
  of them ever get `docker.sock` — only the ops layer does.
- Secrets (passwords, API keys, `domain.env`) always stay out of git —
  `.env` files, never hardcoded in committed files.
- Scripts in `scripts/` are idempotent where that makes sense
  (`ensure_*` functions in `lib.sh`) — they fill in missing state
  themselves, even on an already-running server.

## Safety while working on this repo

- Never remove or work around the `.gitignore` rules for `clients.md`,
  `apps.md`, `OPS.md`, `*.env` — they hold live operational data for a
  specific deployment (this exact thing once leaked into the repo's
  history, see the old `git log` — that's why the repo has just one
  root commit now).
- Images under `docker/` are built through `ensure_image()` (content
  hash, not "if missing") — follow the same pattern for new images, so
  the same bug doesn't repeat (see closed issue #4).

@OPS.md
