#!/usr/bin/env bash
# Lag spikes of cmux NEXT's first launch after a real Sparkle update, against its second launch, on a fleet Mac with
# a console session (measurement only; scripts/measure/post-update-hitches.py does the driving).
#   cmux-ci run --class exclusive --label measure --display \
#     --script scripts/measure/post-update-hitches.sh --ref <sha> \
#     [--arg=from=BUILD] [--arg=to=BUILD] [--arg=workspaces=8] [--arg=seconds=180] [--arg=frames=0] \
#     --artifact .build/post-update-hitches/report.tgz --timeout 3600
#   from=BUILD / to=BUILD  feed builds (default: the feed's second-newest and newest)
# The host must run no other copy of com.cmuxterm.app.nightly.cmux-next (the script refuses, exit 3).
# Prints PUH lines (the summary) and keeps report.json, probe, samples, log stream and app output in report.tgz.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 3
out="$PWD/.build/post-update-hitches"
rm -rf "$out" && mkdir -p "$out"
extra=()
for arg in "$@"; do
  case "$arg" in
    from=*) extra+=(--from "${arg#from=}") ;;
    to=*) extra+=(--to "${arg#to=}") ;;
    workspaces=*) extra+=(--workspaces "${arg#workspaces=}") ;;
    seconds=*) extra+=(--seconds "${arg#seconds=}") ;;
    chat_turns=*) extra+=(--chat-turns "${arg#chat_turns=}") ;;
    frames=0) extra+=(--no-frames) ;;
    frames=1) ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
echo "PUH host $(hostname -s) chip=\"$(sysctl -n machdep.cpu.brand_string)\" macOS $(sw_vers -productVersion) session $(launchctl managername) load $(sysctl -n vm.loadavg)"
python3 scripts/measure/post-update-hitches.py --out "$out" ${extra[@]+"${extra[@]}"} 2>&1 | tee "$out/run.log"
rc=${PIPESTATUS[0]}
tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . 2>/dev/null || true
exit "$rc"
