#!/usr/bin/env bash
# Baseline RAM bench (ask-7040f43163): the physical footprint of every process of an idle cmux-next
# app at launch and under a small load (one chat, one browser tab and terminals), for several
# Chromium switch sets on one build. Each variant is its own launch on a scratch HOME
# (scripts/cmux-next/bench_memory.py, CMUX_NEXT_CEF_EXTRA_SWITCHES: Debug builds only), run in turn
# on the same idle worker, so the deltas between variants come from the switches alone. A fleet step
# has no LaunchServices session, so the app starts as a child (CMUX_BENCH_LAUNCH=direct).
# Run alone on a worker (it launches an app):
#   cmux-ci run --class exclusive --measurement --label measure \
#     --script scripts/measure/baseline-ram.sh --ref SHA [--arg=counts=1,4] [--arg=measure=20] \
#     [--arg=rounds=2] [--arg=variant=NAME=SWITCH:SWITCH ...]
# Without a variant= argument it measures the default list below. rounds: each variant runs that many
# times, interleaved (base, a, b, base, a, b), so a drift in the host shows up in base.
# Output: BASELINE-RAM lines (one per variant, round, sample and kind, plus a total); JSON under
# .build/baseline-ram.
set -euo pipefail
counts="1,4"
measure=20
rounds=2
variants=()
for arg in "$@"; do
  case "$arg" in
    counts=*) counts="${arg#counts=}" ;;
    measure=*) measure="${arg#measure=}" ;;
    rounds=*) rounds="${arg#rounds=}" ;;
    variant=*) variants+=("${arg#variant=}") ;;
    *) echo "baseline-ram.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
if [[ ${#variants[@]} -eq 0 ]]; then
  variants=(
    "base="
    "no-spare-renderer=disable-features=SpareRendererForSitePerProcess"
    "network-in-process=enable-features=NetworkServiceInProcess2"
    "no-bfcache=disable-features=BackForwardCache"
    "no-background-networking=disable-background-networking"
    "v8-optimize-for-size=js-flags=--optimize-for-size"
  )
fi
root="$(git rev-parse --show-toplevel)"
cd "$root"
work="$root/.build/baseline-ram"
rm -rf "$work"
mkdir -p "$work"
echo "BASELINE-RAM-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) sha=$(git rev-parse HEAD) cores=$(sysctl -n hw.ncpu) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )) macos=$(sw_vers -productVersion)"
# A fleet step checks out no submodules (as perf-10x-idle.sh).
for sub in ghostty ghostty-next; do
  [ -e "$sub/.git" ] || git submodule update --init --depth 1 "$sub"
done
if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
  rm -rf GhosttyKit.xcframework
  if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
    export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
  fi
  ./scripts/download-prebuilt-ghosttykit.sh
fi
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag baseram 2>&1 | tee "$work/reload.log" || { tail -n 80 "$work/reload.log"; exit 1; }
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$work/reload.log" | tail -n 1)"
[[ -n "$app" && -d "$app" ]] || { echo "baseline-ram: reload printed no app path" >&2; tail -n 40 "$work/reload.log"; exit 1; }
status=0
for ((round = 1; round <= rounds; round++)); do
  for variant in "${variants[@]}"; do
    name="${variant%%=*}"
    switches="${variant#*=}"
    out="$work/$name-$round.json"
    echo "BASELINE-RAM-RUN variant=$name round=$round switches=${switches:-none} load=\"$(uptime | sed 's/.*load averages*: //')\""
    CMUX_BENCH_LAUNCH=direct python3 scripts/cmux-next/bench_memory.py --app "$app" --workspaces "$counts" \
      --mix terminal+chat,terminal+browser,terminal --fake-agent cmux-tui/crates/acpmux/tests/fake_agent.py \
      --cef-switches "$switches" --settle 20 --measure "$measure" --top 12 --out "$out" \
      > "$work/$name-$round.log" 2>&1 || { status=$?; tail -n 40 "$work/$name-$round.log"; continue; }
    python3 - "$out" "$name" "$round" <<'PY' || status=$?
import json, sys
path, name, rnd = sys.argv[1:]
data = json.load(open(path))
for s in data.get("samples", []):
    print(f"BASELINE-RAM variant={name} round={rnd} sample={s['label']} kind=total n={len(s['processes'])} "
          f"footprint_mb={s['total_footprint_mb']} rss_mb={s['total_rss_mb']}")
    for kind, e in s["kinds"].items():
        print(f"BASELINE-RAM variant={name} round={rnd} sample={s['label']} kind={kind} n={e['count']} "
              f"footprint_mb={e['footprint_mb']} rss_mb={e['rss_mb']} cpu_pct={e.get('cpu_pct')}")
PY
  done
done
exit "$status"
