#!/usr/bin/env bash
# usage-report.sh [--month YYYY-MM] [klient ...]
# Projde usage.log klientů za zvolené období (výchozí: aktuální kalendářní měsíc),
# spočítá odhadovanou cenu podle pricing.conf a vypíše přehled:
#   klient | tokeny (in/out/cache) | odhad ceny USD | % paušálu (z clients.md)
# Klienty nad 80 % paušálu zvýrazní (jen upozornění, nic neblokuje).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib.sh"
PRICING="$ROOT/pricing.conf"

MONTH="$(date +%Y-%m)"
CLIENTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --month) MONTH="$2"; shift 2 ;;
    -h|--help) echo "Použití: usage-report.sh [--month YYYY-MM] [klient ...]"; exit 0 ;;
    *) CLIENTS+=("$1"); shift ;;
  esac
done
# bez argumentů → všichni klienti podle složek
if [ "${#CLIENTS[@]}" -eq 0 ]; then
  for d in "$CLIENTS_DIR"/*/; do [ -d "$d" ] && CLIENTS+=("$(basename "$d")"); done
fi

# paušál klienta z clients.md (8. sloupec tabulky "Měsíční paušál")
pausal_of() {
  local c="$1"
  awk -F'|' -v c=" $1 " '
    $2==c { gsub(/ /,"",$9); print $9; exit }
  ' "$CLIENTS_MD" 2>/dev/null
}

printf '%-14s %12s %12s %12s %12s %12s %10s\n' \
  "KLIENT" "IN" "OUT" "CACHE_W" "CACHE_R" "USD" "% PAUŠÁLU"
printf '%s\n' "--------------------------------------------------------------------------------------------"

GRAND=0
for c in "${CLIENTS[@]}"; do
  LOG="$CLIENTS_DIR/$c/usage.log"
  [ -f "$LOG" ] || LOG="/dev/null"
  read -r IN OUT CW CR USD < <(
    awk -v month="$MONTH" -v pricing="$PRICING" '
      BEGIN{
        while((getline line < pricing)>0){
          if(line ~ /^#/ || line ~ /^[[:space:]]*$/) continue
          n=split(line,a,/[[:space:]]+/)
          if(n>=5){ pi[a[1]]=a[2]; po[a[1]]=a[3]; pcw[a[1]]=a[4]; pcr[a[1]]=a[5] }
        }
      }
      # řádek: <ts> <model> in=N out=N cc=N cr=N <id>
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
        for(m in unknown) printf("[pozn.] neznámý model bez ceny: %s\n", m) > "/dev/stderr"
        printf "%d %d %d %d %.4f\n", tin,tout,tcw,tcr,cost+0
      }
    ' "$LOG"
  )

  PAUSAL="$(pausal_of "$c")"
  PCT="-"; FLAG=""
  if [[ "$PAUSAL" =~ ^[0-9.]+$ ]] && (( $(echo "$PAUSAL > 0" | bc -l) )); then
    PCT="$(echo "scale=1; $USD/$PAUSAL*100" | bc -l)"
    if (( $(echo "$PCT >= 80" | bc -l) )); then FLAG="  <-- ⚠ nad 80% paušálu"; fi
    PCT="${PCT}%"
  fi
  printf '%-14s %12d %12d %12d %12d %12.4f %10s%s\n' \
    "$c" "$IN" "$OUT" "$CW" "$CR" "$USD" "$PCT" "$FLAG"
  GRAND="$(echo "$GRAND + $USD" | bc -l)"
done

printf '%s\n' "--------------------------------------------------------------------------------------------"
printf '%-14s %12s %12s %12s %12s %12.4f\n' "CELKEM" "" "" "" "" "$GRAND"
echo
echo "Období: $MONTH   |   ceník: $PRICING   |   paušály: sloupec 'Měsíční paušál' v clients.md"
