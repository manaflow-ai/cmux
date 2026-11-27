#!/usr/bin/env bash
# Can a fleet Mac give the NIGHTLY health gate a denominator without Sentry (R&D card rc-3b82908a)? Reads, on the
# Mac it runs on: the cmux NEXT feed's newest build and its publish time, the installed NIGHTLY build and when it
# landed, how many NIGHTLY GUI processes run (and since when), and the cmux crash/hang reports in DiagnosticReports
# naming each build. Read only: it installs, launches and kills nothing.
#   cmux-ci run --class shared --label measure --target-worker HOST \
#     --script scripts/measure/fleet-nightly-health.sh --ref <sha> [--arg=feed=URL]
# Prints one FNH line per fact; FNH verdict says whether this Mac counts toward the gate's >=5-Mac denominator
# (the newest build installed within 30 min of publish, and at least one launch of it).
set -uo pipefail
feed="https://files-next.cmux.com/nightly-next/appcast-arm64.xml"
for arg in "$@"; do
  case "$arg" in
    feed=https://*) feed="${arg#feed=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
host=$(hostname -s)
echo "FNH host $host user $(id -un) macOS $(sw_vers -productVersion) session $(launchctl managername 2>/dev/null)"
xml=$(curl -fsS --max-time 20 "$feed" 2>/dev/null)
newest=$(grep -oE '<sparkle:version>[0-9]+' <<<"$xml" | head -1 | sed 's/.*>//')
pub=$(grep -oE '<pubDate>[^<]+' <<<"$xml" | head -1 | sed 's/<pubDate>//')
pub_epoch=$(date -j -f '%a, %d %b %Y %H:%M:%S %z' "$pub" +%s 2>/dev/null || echo 0)
echo "FNH feed newest=${newest:-?} published=$(date -u -r "$pub_epoch" +%FT%TZ 2>/dev/null)"
installed="" landed=0
for app in "/Applications/cmux NIGHTLY.app" "$HOME/Applications/cmux NIGHTLY.app"; do
  [[ -d "$app" ]] || continue
  v=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist" 2>/dev/null)
  t=$(stat -f %m "$app/Contents/Info.plist" 2>/dev/null || echo 0)
  echo "FNH installed app=\"$app\" build=$v landed=$(date -u -r "$t" +%FT%TZ)"
  [[ -z "$installed" ]] && { installed=$v; landed=$t; }
done
[[ -n "$installed" ]] || echo "FNH installed none"
log="$HOME/Library/Logs/cmux-nightly-cu-agent.log"
if [[ -f "$log" ]]; then
  echo "FNH cu-agent log lines=$(wc -l <"$log" | tr -d ' ') last=\"$(tail -1 "$log" | cut -c1-200)\""
else
  echo "FNH cu-agent log none"
fi
gui=0
while read -r pid lstart; do
  [[ -n "$pid" ]] || continue
  gui=$((gui + 1)); echo "FNH gui pid=$pid started=\"$lstart\""
done < <(ps -axo pid=,lstart=,command= | grep -F 'cmux NIGHTLY.app/Contents/MacOS/' | grep -v -e grep -e 'cmuxd\|helper' \
  | awk '{print $1, $2, $3, $4, $5, $6}')
echo "FNH gui running=$gui"
for d in "$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports; do
  [[ -r "$d" ]] || { echo "FNH diag dir=$d unreadable"; continue; }
  all=$(find "$d" -maxdepth 2 -iname '*cmux*' 2>/dev/null | wc -l | tr -d ' ')
  recent=$(find "$d" -maxdepth 2 -iname '*cmux*' -mtime -2 2>/dev/null | wc -l | tr -d ' ')
  naming=0
  [[ -n "$installed" ]] && naming=$(grep -l -F "$installed" $(find "$d" -maxdepth 2 -iname '*cmux*' 2>/dev/null) /dev/null 2>/dev/null | wc -l | tr -d ' ')
  echo "FNH diag dir=$d cmux_reports=$all last48h=$recent naming_installed_build=$naming"
done
lag=$(( landed > 0 && pub_epoch > 0 ? (landed - pub_epoch) / 60 : -1 ))
on_newest=$([[ -n "$newest" && "$installed" == "$newest" ]] && echo 1 || echo 0)
counts=$([[ $on_newest == 1 && $lag -le 30 && $gui -ge 1 ]] && echo 1 || echo 0)
echo "FNH verdict host=$host on_newest=$on_newest install_lag_min=$lag gui_running=$gui counts_toward_denominator=$counts"
