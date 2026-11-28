#!/usr/bin/env bash
# idle-renderer-born (ram-baseline, cmuxterm-hq goals/ram-baseline.md): names each process the untouched idle
# published NIGHTLY starts or ends during a soak, with its full command line and the app's log around it.
#   cmux-ci run --class exclusive --measurement --label bench --script scripts/measure/idle-renderer-born.sh \
#     --ref SHA --artifact artifacts/idle-renderer-born/result.json [--arg=soak=300] [--arg=poll=2]
set -euo pipefail
soak=300 poll=2
for arg in "$@"; do
  case "$arg" in
    soak=*) soak="${arg#soak=}" ;;
    poll=*) poll="${arg#poll=}" ;;
    *) echo "idle-renderer-born.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
cd "$(git rev-parse --show-toplevel)"
out="artifacts/idle-renderer-born"
mkdir -p "$out"
echo "IDLE-BORN-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) sha=$(git rev-parse HEAD) macos=$(sw_vers -productVersion) load=\"$(uptime | sed 's/.*load averages*: //')\""
app=""
while IFS= read -r line; do
  case "$line" in cmux-nightly=*) app="${line#cmux-nightly=}" ;; esac
done < <(python3 scripts/perf-bench/fetch_browsers.py cmux-nightly)
[ -n "$app" ] || { echo "idle-renderer-born.sh: no NIGHTLY bundle" >&2; exit 1; }
python3 scripts/measure/idle-renderer-born.py --app "$app" --soak "$soak" --poll "$poll" --out "$out"
