#!/usr/bin/env bash
# usage-report.sh [--month YYYY-MM] [client ...]
# Goes through clients' usage.log for the chosen period (default: the
# current calendar month), estimates the price from pricing.conf, and
# prints an overview:
#   client | tokens (in/out/cache) | estimated price USD | % of flat fee (from clients.md)
# Highlights clients above 80% of their flat fee (just a warning, nothing blocks).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh"
PRICING="$ROOT/pricing.conf"

MSG_CS[usage_report.usage]='Použití: usage-report.sh [--month YYYY-MM] [klient ...]'
MSG_EN[usage_report.usage]='Usage: usage-report.sh [--month YYYY-MM] [client ...]'
MSG_CS[usage_report.col_client]='KLIENT'
MSG_EN[usage_report.col_client]='CLIENT'
MSG_CS[usage_report.col_pausal]='%% PAUŠÁLU'
MSG_EN[usage_report.col_pausal]='%% FLAT FEE'
MSG_CS[usage_report.over_80]='  <-- ⚠ nad 80%% paušálu'
MSG_EN[usage_report.over_80]='  <-- ⚠ over 80%% of flat fee'
MSG_CS[usage_report.total]='CELKEM'
MSG_EN[usage_report.total]='TOTAL'
MSG_CS[usage_report.footer]="Období: %s   |   ceník: %s   |   paušály: sloupec 'Měsíční paušál' v clients.md"
MSG_EN[usage_report.footer]="Period: %s   |   pricing: %s   |   flat fees: the 'Měsíční paušál' column in clients.md"
MSG_CS[usage_report.unknown_model]='[pozn.] neznámý model bez ceny: %s'
MSG_EN[usage_report.unknown_model]='[note] unknown model with no price: %s'

MONTH="$(date +%Y-%m)"
CLIENTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --month) MONTH="$2"; shift 2 ;;
    -h|--help) echo "$(msg usage_report.usage)"; exit 0 ;;
    *) CLIENTS+=("$1"); shift ;;
  esac
done
# no arguments → every client, from its directory
if [ "${#CLIENTS[@]}" -eq 0 ]; then
  for d in "$CLIENTS_DIR"/*/; do [ -d "$d" ] && CLIENTS+=("$(basename "$d")"); done
fi

# a client's flat fee from clients.md (8th table column, "Měsíční paušál")
pausal_of() {
  local c="$1"
  awk -F'|' -v c=" $1 " '
    $2==c { gsub(/ /,"",$9); print $9; exit }
  ' "$CLIENTS_MD" 2>/dev/null
}

printf '%-14s %12s %12s %12s %12s %12s %10s\n' \
  "$(msg usage_report.col_client)" "IN" "OUT" "CACHE_W" "CACHE_R" "USD" "$(msg usage_report.col_pausal)"
printf '%s\n' "--------------------------------------------------------------------------------------------"

UNKNOWN_MODEL_NOTE="$([ "$N8N_MTS_LANG" = "en" ] && echo "${MSG_EN[usage_report.unknown_model]}" || echo "${MSG_CS[usage_report.unknown_model]}")"

GRAND=0
for c in "${CLIENTS[@]}"; do
  LOG="$CLIENTS_DIR/$c/usage.log"
  [ -f "$LOG" ] || LOG="/dev/null"
  read -r IN OUT CW CR USD < <(
    awk -v month="$MONTH" -v pricing="$PRICING" -v note="$UNKNOWN_MODEL_NOTE" '
      BEGIN{
        while((getline line < pricing)>0){
          if(line ~ /^#/ || line ~ /^[[:space:]]*$/) continue
          n=split(line,a,/[[:space:]]+/)
          if(n>=5){ pi[a[1]]=a[2]; po[a[1]]=a[3]; pcw[a[1]]=a[4]; pcr[a[1]]=a[5] }
        }
      }
      # line format: <ts> <model> in=N out=N cc=N cr=N <id>
      index($1, month)==1 {
        model=$2; inp=out=cc=cr=0
        for(i=3;i<=NF;i++){
          if($i ~ /^in=/){inp=substr($i,4)}
          else if($i ~ /^out=/){out=substr($i,5)}
          else if($i ~ /^cc=/){cc=substr($i,4)}
          else if($i ~ /^cr=/){cr=substr($i,4)}
        }
        tin+=inp; tout+=out; tcw+=cc; tcr+=cr
        if(model in pi){
          cost += inp/1e6*pi[model] + out/1e6*po[model] + cc/1e6*pcw[model] + cr/1e6*pcr[model]
        } else { unknown[model]=1 }
      }
      END{
        for(m in unknown) printf(note "\n", m) > "/dev/stderr"
        printf "%d %d %d %d %.4f\n", tin,tout,tcw,tcr,cost+0
      }
    ' "$LOG"
  )

  PAUSAL="$(pausal_of "$c")"
  PCT="-"; FLAG=""
  if [[ "$PAUSAL" =~ ^[0-9.]+$ ]] && (( $(echo "$PAUSAL > 0" | bc -l) )); then
    PCT="$(echo "scale=1; $USD/$PAUSAL*100" | bc -l)"
    if (( $(echo "$PCT >= 80" | bc -l) )); then FLAG="$(msg usage_report.over_80)"; fi
    PCT="${PCT}%"
  fi
  printf '%-14s %12d %12d %12d %12d %12.4f %10s%s\n' \
    "$c" "$IN" "$OUT" "$CW" "$CR" "$USD" "$PCT" "$FLAG"
  GRAND="$(echo "$GRAND + $USD" | bc -l)"
done

printf '%s\n' "--------------------------------------------------------------------------------------------"
printf '%-14s %12s %12s %12s %12s %12.4f\n' "$(msg usage_report.total)" "" "" "" "" "$GRAND"
echo
echo "$(msg usage_report.footer "$MONTH" "$PRICING")"
