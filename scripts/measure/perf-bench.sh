#!/usr/bin/env bash
# xbench (msg 2654): cmux NEXT against Chrome, Helium, Ardia, Dia and Safari on
# the rows of Ardia's 2026-10-19 comparison (power idle hidden/in view,
# scrolling, video, switching tabs; cold launch; new tab first paint; idle
# wakeups and CPU at 20 tabs; memory at 1/10/20 tabs). Method and rows:
# scripts/perf-bench/README.md. Run alone on an idle mini (it launches apps):
#   cmux-ci run --class exclusive --measurement --label measure \
#     --script scripts/measure/perf-bench.sh --ref SHA --artifact artifacts/perf-bench/results.json \
#     [--arg=rounds=3] [--arg=launches=2] [--arg=idle=60] [--arg=active=30] [--arg=cmux=build|nightly]
#     [--arg=browsers=cmux-chromium,cmux-webkit,cmux-terminal,chrome,helium,ardia,dia,safari] [--arg=gate=1]
# cmux=build (default) builds a Release app at this checkout; cmux=nightly
# measures the latest nightly-next DMG. gate=1 fails the step when a cmux row
# is worse than scripts/perf-bench/baseline/<chip>-macos<major>.json by more
# than 15 % (and the unit's floor). Output: BENCH.md in the log,
# artifacts/perf-bench/{results.json,BENCH.md}.
set -euo pipefail
rounds=3 launches=2 idle=60 active=30 settle=30 cmux=build gate=0 maxload=4
browsers="cmux-chromium,cmux-webkit,cmux-terminal,chrome,helium,ardia,dia,safari"
for arg in "$@"; do
  case "$arg" in
    rounds=*) rounds="${arg#rounds=}" ;;
    launches=*) launches="${arg#launches=}" ;;
    idle=*) idle="${arg#idle=}" ;;
    active=*) active="${arg#active=}" ;;
    settle=*) settle="${arg#settle=}" ;;
    cmux=*) cmux="${arg#cmux=}" ;;
    gate=*) gate="${arg#gate=}" ;;
    maxload=*) maxload="${arg#maxload=}" ;;
    browsers=*) browsers="${arg#browsers=}" ;;
    *) echo "perf-bench.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
cd "$(git rev-parse --show-toplevel)"
sha="$(git rev-parse HEAD)"
out="artifacts/perf-bench"
work=".build/perf-bench"
rm -rf "$out" "$work" /private/tmp/xbench
mkdir -p "$out" "$work"
chip="$(sysctl -n machdep.cpu.brand_string)"
echo "PERF-BENCH-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) sha=$sha model=$(sysctl -n hw.model) chip=\"$chip\" cores=$(sysctl -n hw.ncpu) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )) macos=$(sw_vers -productVersion) load=\"$(uptime | sed 's/.*load averages*: //')\""

apps=()
case "$cmux" in
  build)
    CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag perfbench --release > "$work/reload.log" 2>&1 \
      || { tail -n 80 "$work/reload.log"; exit 1; }
    app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$work/reload.log" | tail -n 1)"
    [[ -n "$app" && -d "$app" ]] || { echo "perf-bench: reload printed no app path" >&2; tail -n 40 "$work/reload.log"; exit 1; }
    apps+=(--app "cmux=$app")
    ;;
  nightly) ;;
  *) echo "perf-bench.sh: cmux=build or cmux=nightly" >&2; exit 2 ;;
esac
want=()
for name in chrome helium ardia dia; do
  [[ ",$browsers," == *",$name,"* ]] && want+=("$name")
done
[ "$cmux" = nightly ] && want+=(cmux-nightly)
if [ "${#want[@]}" -gt 0 ]; then
  while IFS= read -r line; do
    case "$line" in
      cmux-nightly=*) apps+=(--app "cmux=${line#cmux-nightly=}") ;;
      *=*) apps+=(--app "$line") ;;
    esac
  done < <(python3 scripts/perf-bench/fetch_browsers.py "${want[@]}")
fi

status=0
python3 scripts/perf-bench/xbench.py run --out "$work/run" ${apps[@]+"${apps[@]}"} --browsers "$browsers" \
  --rounds "$rounds" --launches "$launches" --idle "$idle" --active "$active" --settle "$settle" \
  --max-load "$maxload" --cmux-ref "$sha" || status=$?
python3 scripts/perf-bench/xbench.py report --out "$work/run" --md "$out/BENCH.md" --json "$out/results.json" || status=$?
slug="$(echo "$chip" | tr 'A-Z ' 'a-z-' | tr -cd 'a-z0-9-')-macos$(sw_vers -productVersion | cut -d. -f1)"
echo "PERF-BENCH-BASELINE-KEY $slug"
if [ "$gate" = 1 ]; then
  baseline="scripts/perf-bench/baseline/$slug.json"
  if [ -f "$baseline" ]; then
    python3 scripts/perf-bench/xbench.py gate --results "$out/results.json" --baseline "$baseline" || status=$?
  else
    echo "PERF-BENCH-GATE SKIP no baseline $baseline"
  fi
fi
exit "$status"
