#!/usr/bin/env bash
# Workspace-switch, typing and hang measurement of published cmux NEXT nightly DMGs on a fleet Mac with a
# console session (measurement only; scripts/cmux-next/nightly-ws-switch.py does the driving).
#   cmux-ci run --class exclusive --label measure --display \
#     --script scripts/measure/nightly-ws-switch.sh --ref <sha> \
#     --arg=dmg=URL [--arg=dmg=URL ...] [--arg=rounds=20] [--arg=workspaces=6] \
#     --artifact .build/nightly-ws-switch/report.tgz --timeout 3600
#   dmg=URL  an https nightly DMG (repeatable; run in the order given)
#   heavy=1  each workspace also gets two splits (one printing), a second terminal tab and a browser tab
# Prints NWS lines per build (the summary) and keeps report.json, app output and sample files in report.tgz.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
out="$PWD/.build/nightly-ws-switch"
rm -rf "$out" && mkdir -p "$out"
dmgs=() extra=()
for arg in "$@"; do
  case "$arg" in
    dmg=https://*) dmgs+=("${arg#dmg=}") ;;
    rounds=*) extra+=(--rounds "${arg#rounds=}") ;;
    workspaces=*) extra+=(--workspaces "${arg#workspaces=}") ;;
    typing=*) extra+=(--typing "${arg#typing=}") ;;
    heavy=1) extra+=(--heavy) ;;
    heavy=0) ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ ${#dmgs[@]} -gt 0 ]] || { echo "give at least one dmg=https://..." >&2; exit 2; }
echo "NWS host $(hostname -s) chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername)"
status=0
for url in "${dmgs[@]}"; do
  name="$(basename "$url" .dmg)"
  dir="$out/$name"
  mkdir -p "$dir"
  echo "NWS ==> $name"
  if ! curl -fsSL --proto '=https' --retry 3 -A cmux-nightly-ws-switch/1 -o "$dir/in.dmg" "$url"; then
    echo "NWS $name download failed"; status=3; continue
  fi
  python3 scripts/cmux-next/nightly-ws-switch.py --dmg "$dir/in.dmg" --out "$dir" ${extra[@]+"${extra[@]}"} 2>&1 | tee "$dir/run.log"
  rc=${PIPESTATUS[0]}
  rm -f "$dir/in.dmg"
  echo "NWS $name exit=$rc $(grep '^SUMMARY ' "$dir/run.log" | tail -n 1)"
  for sample in "$dir"/sample-*.txt; do
    [[ -f "$sample" ]] || continue
    echo "NWS --- $name $(basename "$sample"): heaviest main-thread frames (sort by top of stack)"
    awk '/Sort by top of stack/{on=1;next} on&&NF==0{exit} on' "$sample" | head -n 25
    echo "NWS --- $name $(basename "$sample"): main thread call graph (first 80 lines)"
    awk '/Call graph:/{on=1;next} on&&/^ *[0-9]+ Thread_/{n++} n>1{exit} on' "$sample" | cut -c1-220 | head -n 80
  done
  [[ $rc -eq 0 ]] || status=1
done
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . 2>/dev/null || true
exit "$status"
