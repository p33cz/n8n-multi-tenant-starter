#!/usr/bin/env bash
# usage-collect.sh — runs inside the claude-{client} container (via
# cron, hourly). Goes through local Claude Code transcripts (JSONL),
# and appends any newly-appeared responses (by message.id) to
# /client/usage.log.
#
# usage.log line format (TAB-separated):
#   <ISO timestamp>  <model>  in=<N>  out=<N>  cc=<N>  cr=<N>  <message_id>
#     cc = cache_creation_input_tokens, cr = cache_read_input_tokens
set -euo pipefail

# Standalone cron script — no access to scripts/lib.sh inside the
# container, so it keeps its own tiny N8N_MTS_LANG switch (the value
# itself is passed in from the host via templates/docker-compose.yml.tmpl).
N8N_MTS_LANG="${N8N_MTS_LANG:-cs}"

# CLIENT / USAGE_LOG supplied by the entrypoint
[ -f /usr/local/etc-usage.env ] && . /usr/local/etc-usage.env
USAGE_LOG="${USAGE_LOG:-/client/usage.log}"
STATE="$(dirname "$USAGE_LOG")/.usage.seen"     # already-processed message.id values
PROJ="${HOME:-/root}/.claude/projects"

mkdir -p "$(dirname "$USAGE_LOG")"
touch "$USAGE_LOG" "$STATE"
if [ ! -d "$PROJ" ]; then
  if [ "$N8N_MTS_LANG" = "en" ]; then
    echo "$(date -u +%FT%TZ) no transcripts ($PROJ)"
  else
    echo "$(date -u +%FT%TZ) žádné transkripty ($PROJ)"
  fi
  exit 0
fi

added=0
# pull assistant responses with usage data out of all transcripts
while IFS=$'\t' read -r ts model id inp out cc cr; do
  [ -z "${id:-}" ] && continue
  grep -qxF "$id" "$STATE" && continue
  printf '%s\t%s\tin=%s\tout=%s\tcc=%s\tcr=%s\t%s\n' \
    "$ts" "$model" "$inp" "$out" "$cc" "$cr" "$id" >> "$USAGE_LOG"
  echo "$id" >> "$STATE"
  added=$((added+1))
done < <(
  find "$PROJ" -type f -name '*.jsonl' -print0 \
  | xargs -0 -r cat \
  | jq -rc 'select(.type=="assistant" and (.message.usage != null))
            | [ (.timestamp // "?"),
                (.message.model // "?"),
                (.message.id // "?"),
                (.message.usage.input_tokens // 0),
                (.message.usage.output_tokens // 0),
                (.message.usage.cache_creation_input_tokens // 0),
                (.message.usage.cache_read_input_tokens // 0) ]
            | @tsv' 2>/dev/null
)

if [ "$N8N_MTS_LANG" = "en" ]; then
  echo "$(date -u +%FT%TZ) added $added new records to $USAGE_LOG"
else
  echo "$(date -u +%FT%TZ) přidáno $added nových záznamů do $USAGE_LOG"
fi
