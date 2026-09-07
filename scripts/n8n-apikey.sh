#!/usr/bin/env bash
# n8n-apikey.sh <base_url> <owner_email> <owner_password>
# Založí vlastníka (první běh), přihlásí se a vytvoří n8n public API klíč
# scoped na tuto jednu instanci. Klíč vypíše na stdout; diagnostiku na stderr.
set -euo pipefail
BASE="$1"; EMAIL="$2"; PASS="$3"
JAR="$(mktemp)"; trap 'rm -f "$JAR"' EXIT

log() { echo "[n8n-apikey] $*" >&2; }

# 1) owner setup (na prázdné DB projde; jinak vrátí chybu → přihlásíme se)
curl -fsS -c "$JAR" -X POST "$BASE/rest/owner/setup" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"firstName\":\"Ops\",\"lastName\":\"Owner\",\"password\":\"$PASS\"}" \
  >/dev/null 2>&1 && log "vlastník vytvořen" || log "owner/setup přeskočen (nejspíš už existuje)"

# 2) login (varianty payloadu napříč verzemi n8n)
logged_in=0
for body in \
  "{\"emailOrLdapLoginId\":\"$EMAIL\",\"password\":\"$PASS\"}" \
  "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}"; do
  if curl -fsS -c "$JAR" -b "$JAR" -X POST "$BASE/rest/login" \
       -H 'Content-Type: application/json' -d "$body" >/dev/null 2>&1; then
    logged_in=1; break
  fi
done
[ "$logged_in" = 1 ] && log "přihlášen" || log "login se nepodařil (zkusím i tak vytvořit klíč se setup cookie)"

# 3) vytvoř API klíč — retry, dokud n8n plně nenaběhne ("n8n is starting up").
# scopes si stáhneme dynamicky z /rest/api-keys/scopes (liší se dle verze/edice);
# novější n8n vyžaduje scopes (pole) i expiresAt.
RESP=""; KEY=""
for attempt in $(seq 1 20); do
  # aktuální platné scopes této instance (JSON pole); prázdné dokud n8n startuje
  SCOPES_JSON="$(curl -fsS -c "$JAR" -b "$JAR" "$BASE/rest/api-keys/scopes" 2>/dev/null \
                 | jq -c '.data // .' 2>/dev/null || true)"
  if [ -z "$SCOPES_JSON" ] || ! printf '%s' "$SCOPES_JSON" | jq -e 'type=="array" and length>0' >/dev/null 2>&1; then
    log "n8n ještě nastartovává (pokus $attempt/20), čekám 3s…"
    sleep 3
    curl -fsS -c "$JAR" -b "$JAR" -X POST "$BASE/rest/login" -H 'Content-Type: application/json' \
      -d "{\"emailOrLdapLoginId\":\"$EMAIL\",\"password\":\"$PASS\"}" >/dev/null 2>&1 || true
    continue
  fi
  # sestav tělo požadavku s label + všemi scopes + expiresAt:null
  BODY="$(jq -cn --argjson sc "$SCOPES_JSON" '{label:"ops-provisioned", scopes:$sc, expiresAt:null}')"
  for b in "$BODY" \
           "$(jq -cn --argjson sc "$SCOPES_JSON" '{label:"ops-provisioned", scopes:$sc}')" \
           '{"label":"ops-provisioned"}'; do
    RESP="$(curl -fsS -c "$JAR" -b "$JAR" -X POST "$BASE/rest/api-keys" \
            -H 'Content-Type: application/json' -d "$b" 2>/dev/null || true)"
    printf '%s' "$RESP" | grep -qi 'starting up' && { RESP=""; continue; }
    KEY="$(printf '%s' "$RESP" | jq -r '.data.rawApiKey // .data.apiKey // .rawApiKey // .apiKey // empty' 2>/dev/null || true)"
    [ -n "$KEY" ] && [ "$KEY" != "null" ] && break
  done
  [ -n "$KEY" ] && [ "$KEY" != "null" ] && break
  sleep 2
done

if [ -n "$KEY" ] && [ "$KEY" != "null" ]; then
  log "API klíč vytvořen"
  printf '%s\n' "$KEY"
  exit 0
fi
log "nepodařilo se získat API klíč. Odpověď: ${RESP:0:200}"
exit 1
