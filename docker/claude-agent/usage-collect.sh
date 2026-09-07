#!/usr/bin/env bash
# usage-collect.sh — běží uvnitř claude-{klient} kontejneru (přes cron, hodinově).
# Projde lokální transkripty Claude Code (JSONL), a nově přibylé odpovědi
# (podle message.id) připíše do /client/usage.log.
#
# Formát řádku usage.log (TAB oddělené):
#   <ISO timestamp>  <model>  in=<N>  out=<N>  cc=<N>  cr=<N>  <message_id>
#     cc = cache_creation_input_tokens, cr = cache_read_input_tokens
set -euo pipefail

# CLIENT / USAGE_LOG dodá entrypoint
[ -f /usr/local/etc-usage.env ] && . /usr/local/etc-usage.env
USAGE_LOG="${USAGE_LOG:-/client/usage.log}"
STATE="$(dirname "$USAGE_LOG")/.usage.seen"     # zpracované message.id
PROJ="${HOME:-/root}/.claude/projects"

mkdir -p "$(dirname "$USAGE_LOG")"
touch "$USAGE_LOG" "$STATE"
[ -d "$PROJ" ] || { echo "$(date -u +%FT%TZ) žádné transkripty ($PROJ)"; exit 0; }

added=0
# vytáhni z všech transkriptů asistentské odpovědi s usage
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

echo "$(date -u +%FT%TZ) přidáno $added nových záznamů do $USAGE_LOG"
