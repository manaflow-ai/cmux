#!/usr/bin/env bash
# rivals-bench (Leo, 2026-11-25: "the app speed on idle and on load we need to be better tho i recall us not being
# as good as claude code desktop. idk where we stand compared to codex or t3 code and where our "speed of light"
# optimizations stand we need to be working on those"): cmux NIGHTLY against Claude Code desktop, the Codex app and
# T3 Code on one Mac: idle CPU / wakeups / energy / RSS, cold and warm launch to interactive, 10 repeats, p50 and p95.
# Run alone on an idle Mac with a console user:
#   cmux-ci run --class exclusive --measurement --script scripts/measure/rivals-bench.sh --ref SHA \
#     [--target-worker NAME] --artifact artifacts/rivals-bench/results.json [--arg=repeats=10] [--arg=idle=60]
#     [--arg=settle=15] [--arg=apps=cmux,claude,codex,t3code] [--arg=long=1] [--arg=record=0]
# Also runs on any host by hand: scripts/measure/rivals-bench.sh repeats=3
# Method: scripts/cmux-next/rivals-bench.py. Output: artifacts/rivals-bench/{results.json,RIVALS-BENCH.md,recordings/}.
set -euo pipefail
repeats=10 idle=60 settle=15 apps="cmux,claude,codex,t3code" long=0 record=1
for arg in "$@"; do
  case "$arg" in
    repeats=*) repeats="${arg#repeats=}" ;;
    idle=*) idle="${arg#idle=}" ;;
    settle=*) settle="${arg#settle=}" ;;
    apps=*) apps="${arg#apps=}" ;;
    long=*) long="${arg#long=}" ;;
    record=*) record="${arg#record=}" ;;
    *) echo "rivals-bench.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
cd "$(git rev-parse --show-toplevel)"
sha="$(git rev-parse HEAD)"
out="artifacts/rivals-bench"
chmod -R u+w "$out" 2>/dev/null || true
rm -rf "$out"
mkdir -p "$out"
echo "RIVALS-BENCH-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) sha=$sha chip=\"$(sysctl -n machdep.cpu.brand_string)\" macos=$(sw_vers -productVersion) load=\"$(uptime | sed 's/.*load averages*: //')\""
flags=()
[ "$long" = 1 ] && flags+=(--long)
[ "$record" = 0 ] && flags+=(--no-record)
status=0
python3 scripts/cmux-next/rivals-bench.py --out "$out" --apps "$apps" --repeats "$repeats" --idle "$idle" \
  --settle "$settle" --cmux-ref "$sha" ${flags[@]+"${flags[@]}"} || status=$?
[ -f "$out/RIVALS-BENCH.md" ] && cat "$out/RIVALS-BENCH.md"
exit "$status"
