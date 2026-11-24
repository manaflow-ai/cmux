#!/usr/bin/env bash
# rivals (Leo, 2026-11-22, ask-7c96907088: "compare to claude and codex and t3 code too. we absolutely need as many
# numbers as possible [...] go look at edge/chrome/safari/slack/helium too"): cmux NEXT (the newest nightly-next
# DMG) against Claude, Codex, T3 Code, Slack, Chrome, Edge, Helium, Safari and Rex (when the host has
# /Applications/Rex.app): first launch of a new install, launch after purge (close to a restart), warm relaunch,
# the CPU and peak RAM each costs, and a 5 minute idle soak (RAM ceiling, growth per minute, CPU, wakeups).
# Method: scripts/perf-bench/rivals.py. Run alone on an idle Mac with a console user (it launches apps):
#   cmux-ci run --class exclusive --measurement --label bench --script scripts/measure/rivals.sh --ref SHA \
#     --artifact artifacts/rivals/results.json [--arg=apps=cmux,claude,...] [--arg=rounds=1] [--arg=warm=3]
#     [--arg=after=20] [--arg=soak=300] [--arg=sample=10] [--arg=maxload=4]
# Output: RIVALS.md in the log, artifacts/rivals/{results.json,RIVALS.md,samples.jsonl}.
set -euo pipefail
apps="cmux,rex,claude,codex,t3code,slack,chrome,edge,helium,safari" rounds=1 warm=3 after=20 soak=300 sample=10 maxload=4
for arg in "$@"; do
  case "$arg" in
    apps=*) apps="${arg#apps=}" ;;
    rounds=*) rounds="${arg#rounds=}" ;;
    warm=*) warm="${arg#warm=}" ;;
    after=*) after="${arg#after=}" ;;
    soak=*) soak="${arg#soak=}" ;;
    sample=*) sample="${arg#sample=}" ;;
    maxload=*) maxload="${arg#maxload=}" ;;
    *) echo "rivals.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
cd "$(git rev-parse --show-toplevel)"
sha="$(git rev-parse HEAD)"
out="artifacts/rivals"
work=".build/rivals"
chmod -R u+w "$out" "$work" 2>/dev/null || true
rm -rf "$out" "$work"
mkdir -p "$out" "$work"
echo "RIVALS-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) sha=$sha chip=\"$(sysctl -n machdep.cpu.brand_string)\" macos=$(sw_vers -productVersion) load=\"$(uptime | sed 's/.*load averages*: //')\""
want=()
IFS=, read -ra names <<< "$apps"
for name in "${names[@]}"; do
  case "$name" in
    cmux) want+=(cmux-nightly) ;;
    safari | rex) ;;
    *) want+=("$name") ;;
  esac
done
bundles=()
while IFS= read -r line; do
  case "$line" in
    cmux-nightly=*) bundles+=(--app "cmux=${line#cmux-nightly=}") ;;
    *=*) bundles+=(--app "$line") ;;
  esac
done < <(python3 scripts/perf-bench/fetch_browsers.py ${want[@]+"${want[@]}"})
status=0
python3 scripts/perf-bench/rivals.py run --out "$work/run" --work "$work/profiles" ${bundles[@]+"${bundles[@]}"} \
  --apps "$apps" --rounds "$rounds" --warm "$warm" --after "$after" --soak "$soak" --sample "$sample" \
  --max-load "$maxload" --cmux-ref "$sha" || status=$?
[ -f "$work/run/meta.json" ] || exit "${status:-1}"
cp "$work/run/samples.jsonl" "$out/" 2>/dev/null || true
python3 scripts/perf-bench/rivals.py report --out "$work/run" --md "$out/RIVALS.md" --json "$out/results.json" || status=$?
chmod -R u+w "$work" 2>/dev/null || true
exit "$status"
