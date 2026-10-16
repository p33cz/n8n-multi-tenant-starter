#!/usr/bin/env bash
# n8n-apikey.sh <base_url> <owner_email> <owner_password> [label]
# Sets up the owner (first run), logs in, and creates an n8n public API
# key scoped to this one instance. Prints the key to stdout; diagnostics
# to stderr.
#
# [label] is optional — when an app asks for a second key for the SAME
# owner (the n8n-{client} owner shared between claude-{client} and its
# apps), every key needs a different label, or n8n rejects it as a
# duplicate.
set -euo pipefail
BASE="$1"; EMAIL="$2"; PASS="$3"; LABEL="${4:-ops-provisioned}"
JAR="$(mktemp)"; trap 'rm -f "$JAR"' EXIT

# Standalone helper script — doesn't source lib.sh, so it keeps its own
# tiny N8N_MTS_LANG switch instead of depending on the shared one.
N8N_MTS_LANG="${N8N_MTS_LANG:-cs}"
log() {
  local cs="$1" en="$2"; shift 2
  local template="$cs"
  [ "$N8N_MTS_LANG" = "en" ] && template="$en"
  # shellcheck disable=SC2059
  echo "[n8n-apikey] $(printf -- "$template" "$@")" >&2
}

# 1) owner setup (succeeds on an empty DB; otherwise returns an error → log in instead)
curl -fsS -c "$JAR" -X POST "$BASE/rest/owner/setup" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"firstName\":\"Ops\",\"lastName\":\"Owner\",\"password\":\"$PASS\"}" \
  >/dev/null 2>&1 \
  && log 'vlastník vytvořen' 'owner created' \
  || log 'owner/setup přeskočen (nejspíš už existuje)' 'owner/setup skipped (probably already exists)'

# 2) log in (payload variants across n8n versions)
logged_in=0
for body in \
  "{\"emailOrLdapLoginId\":\"$EMAIL\",\"password\":\"$PASS\"}" \
  "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}"; do
  if curl -fsS -c "$JAR" -b "$JAR" -X POST "$BASE/rest/login" \
       -H 'Content-Type: application/json' -d "$body" >/dev/null 2>&1; then
    logged_in=1; break
  fi
done
if [ "$logged_in" = 1 ]; then
  log 'přihlášen' 'logged in'
else
  log 'login se nepodařil (zkusím i tak vytvořit klíč se setup cookie)' "login failed (I'll still try to create the key with the setup cookie)"
fi

# 3) create the API key — retry until n8n is fully up ("n8n is starting up").
# scopes are pulled dynamically from /rest/api-keys/scopes (differs by
# version/edition); newer n8n requires both scopes (array) and expiresAt.
# healthz tends to go green before this endpoint is fully ready — in
# practice that can take over a minute, hence 40 attempts (~2 min), not 20.
RESP=""; KEY=""
ATTEMPTS=40
for attempt in $(seq 1 "$ATTEMPTS"); do
  # this instance's currently valid scopes (JSON array); empty while n8n is still starting
  SCOPES_JSON="$(curl -fsS -c "$JAR" -b "$JAR" "$BASE/rest/api-keys/scopes" 2>/dev/null \
                 | jq -c '.data // .' 2>/dev/null || true)"
  if [ -z "$SCOPES_JSON" ] || ! printf '%s' "$SCOPES_JSON" | jq -e 'type=="array" and length>0' >/dev/null 2>&1; then
    log 'n8n ještě nastartovává (pokus %s/%s), čekám 3s…' 'n8n is still starting up (attempt %s/%s), waiting 3s…' "$attempt" "$ATTEMPTS"
    sleep 3
    curl -fsS -c "$JAR" -b "$JAR" -X POST "$BASE/rest/login" -H 'Content-Type: application/json' \
      -d "{\"emailOrLdapLoginId\":\"$EMAIL\",\"password\":\"$PASS\"}" >/dev/null 2>&1 || true
    continue
  fi
  # build the request body with label + all scopes + expiresAt:null
  BODY="$(jq -cn --arg l "$LABEL" --argjson sc "$SCOPES_JSON" '{label:$l, scopes:$sc, expiresAt:null}')"
  for b in "$BODY" \
           "$(jq -cn --arg l "$LABEL" --argjson sc "$SCOPES_JSON" '{label:$l, scopes:$sc}')" \
           "$(jq -cn --arg l "$LABEL" '{label:$l}')"; do
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
  log 'API klíč vytvořen' 'API key created'
  printf '%s\n' "$KEY"
  exit 0
fi
log 'nepodařilo se získat API klíč. Odpověď: %s' 'could not obtain an API key. Response: %s' "${RESP:0:200}"
exit 1
