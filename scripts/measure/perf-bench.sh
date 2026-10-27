#!/usr/bin/env bash
# xbench (msg 2654): cmux NEXT against Chrome, Helium, Ardia, Dia and Safari on
# the rows of Ardia's 2026-10-19 comparison (power idle hidden/in view,
# scrolling, video, switching tabs; cold launch; new tab first paint; idle
# wakeups and CPU at 20 tabs; memory at 1/10/20 tabs). Method and rows:
# scripts/perf-bench/README.md. Run alone on an idle mini (it launches apps):
#   cmux-ci run --class exclusive --measurement --label measure \
#     --script scripts/measure/perf-bench.sh --ref SHA --artifact artifacts/perf-bench/results.json \
#     [--arg=rounds=3] [--arg=launches=2] [--arg=idle=60] [--arg=active=30] [--arg=cmux=build|nightly]
#     [--arg=browsers=cmux-chromium,cmux-webkit,cmux-terminal,cmux-budget,chrome,helium,ardia,dia,safari] [--arg=gate=1]
#     [--arg=tabswitch=chromium,webkit,markdown,chat] [--arg=tabcounts=2,10,30] [--arg=palette=on|off]
#     [--arg=budgets=scripts/perf-bench/budgets.json] [--arg=bench_config=debug|bench]
# tabswitch= (default on; tabswitch=off skips it) also builds a tagged Debug app at this checkout and
# runs scripts/cmux-next/tab-switch-matrix.py: real-window tab switch end to end (input event to
# commit) per tab kind at each count, as a "Tab switch" section of BENCH.md and gate rows.
# palette= (default on) runs a182's scripts/cmux-next/palette-open-stages.py on the same Debug app:
# Cmd-Shift-P and Cmd-P key-down to the committed frame from each surface ("Palette open" rows).
# cmux=build (default) builds a Release app at this checkout; cmux=nightly
# measures the latest nightly-next DMG. gate=1 fails the step when a cmux row
# is worse than scripts/perf-bench/baseline/<chip>-macos<major>.json by more
# than 15 % (and the unit's floor). Output: BENCH.md in the log,
# artifacts/perf-bench/{results.json,BENCH.md}.
set -euo pipefail
rounds=3 launches=2 idle=60 active=30 settle=30 cmux=build gate=0 maxload=4 bench_config=debug
tabswitch="chromium,webkit,markdown,chat" tabcounts="2,10,30" palette=on budgets=scripts/perf-bench/budgets.json
browsers="cmux-chromium,cmux-webkit,cmux-terminal,cmux-budget,chrome,helium,ardia,dia,safari"
for arg in "$@"; do
  case "$arg" in
    bench_config=*) bench_config="${arg#bench_config=}" ;;
    rounds=*) rounds="${arg#rounds=}" ;;
    launches=*) launches="${arg#launches=}" ;;
    idle=*) idle="${arg#idle=}" ;;
    active=*) active="${arg#active=}" ;;
    settle=*) settle="${arg#settle=}" ;;
    cmux=*) cmux="${arg#cmux=}" ;;
    gate=*) gate="${arg#gate=}" ;;
    maxload=*) maxload="${arg#maxload=}" ;;
    browsers=*) browsers="${arg#browsers=}" ;;
    tabswitch=*) tabswitch="${arg#tabswitch=}" ;;
    tabcounts=*) tabcounts="${arg#tabcounts=}" ;;
    palette=*) palette="${arg#palette=}" ;;
    budgets=*) budgets="${arg#budgets=}" ;;
    *) echo "perf-bench.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
cd "$(git rev-parse --show-toplevel)"
# Steps run with a per-step HOME; the account's user-level tools (bun and node for the
# Debug build's web bundles) live under its real home.
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
done
sha="$(git rev-parse HEAD)"
out="artifacts/perf-bench"
work=".build/perf-bench"
rm -rf "$out" "$work" /private/tmp/xbench
mkdir -p "$out" "$work"
chip="$(sysctl -n machdep.cpu.brand_string)"
echo "PERF-BENCH-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) sha=$sha model=$(sysctl -n hw.model) chip=\"$chip\" cores=$(sysctl -n hw.ncpu) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )) macos=$(sw_vers -productVersion) load=\"$(uptime | sed 's/.*load averages*: //')\""

debug=0
{ [ "$tabswitch" != off ] || [ "$palette" != off ]; } && debug=1
if [ "$cmux" = build ] || [ "$debug" = 1 ]; then
  # A fleet step checks out no submodules (only their empty gitlink directories): the app build needs
  # Ghostty's headers, the ghostty-next tree and GhosttyKit.xcframework (as scripts/measure/tab-switch.sh).
  for sub in ghostty ghostty-next; do
    [ -e "$sub/.git" ] || git submodule update --init --depth 1 "$sub" >/dev/null
  done
  if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
    rm -rf GhosttyKit.xcframework
    if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
      export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
    fi
    ./scripts/download-prebuilt-ghosttykit.sh
  fi
fi

apps=()
case "$cmux" in
  build)
    CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag perfbench --config release > "$work/reload.log" 2>&1 \
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
  --max-load "$maxload" --cmux-ref "$sha" --budgets "$budgets" || status=$?
switch_json=""
if [ "$debug" = 1 ]; then
  # The matrix and the palette timing drive debug.key / debug.tab_switch / debug.timings, which only a
  # tagged Debug build answers. One build serves both.
  # The tab switch and palette rows drive debug.* commands: bench_config=bench (default debug) builds that
  # app optimized with the commands kept (reload.sh --config bench).
  if CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag pbswitch --config "$bench_config" > "$work/reload-switch.log" 2>&1; then
    switch_app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$work/reload-switch.log" | tail -n 1)"
    if [ "$tabswitch" != off ]; then
      mkdir -p "$work/switch"
      python3 scripts/cmux-next/tab-switch-matrix.py --tag pbswitch --app "$switch_app" --kinds "$tabswitch" \
        --counts "$tabcounts" --json "$out/tab-switch.json" --out "$work/switch" || true
      [ -f "$out/tab-switch.json" ] && switch_json="--tabswitch $out/tab-switch.json"
    fi
    if [ "$palette" != off ]; then
      mkdir -p "$work/palette"
      python3 scripts/cmux-next/palette-open-stages.py --tag pbswitch --app "$switch_app" --no-gate \
        --out "$work/palette" --json "$out/palette-open.json" || true
      [ -f "$out/palette-open.json" ] && switch_json="$switch_json --palette $out/palette-open.json"
    fi
  else
    echo "PERF-BENCH-TABSWITCH tagged Debug build failed:"; tail -n 40 "$work/reload-switch.log"; status=1
  fi
fi
# shellcheck disable=SC2086 # switch_json is empty or flags with their paths
python3 scripts/perf-bench/xbench.py report --out "$work/run" --md "$out/BENCH.md" --json "$out/results.json" $switch_json || status=$?
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
