#!/usr/bin/env bash
# Relaunch to the first live chat event (scripts/cmux-next/bench_relaunch_reconnect.py): a bench
# build with 6 local agent chats, one streaming, quit and relaunched 3 times in each mode (warm: the
# daemon keeps running; update: the bundle is replaced in place, so the daemon is handed off;
# cold: the daemon is stopped), each phase from process start to the shown chat's first live event.
# Leo, 2026-11-04 (manaflow-ai/cmuxterm-hq#6338). Run alone, on a display worker (the chat pages
# render in a window):
#   cmux-ci run --class exclusive --measurement --display --label measure \
#     --script scripts/measure/perf-relaunch-reconnect.sh --ref SHA \
#     --artifact artifacts/perf-relaunch-reconnect.json [--arg=modes=warm,update,cold] [--arg=rounds=3] [--arg=chats=6]
# The log prints the median phase table between PERF-RELAUNCH-TABLE-BEGIN and -END.
set -euo pipefail
config=bench
modes=""
rounds=""
chats=""
for arg in "$@"; do
  case "$arg" in
    config=*) config="${arg#config=}" ;;
    modes=*) modes="${arg#modes=}"; [[ "$modes" =~ ^[a-z,]+$ ]] || { echo "perf-relaunch-reconnect.sh: modes=warm,update,cold" >&2; exit 2; } ;;
    rounds=*) rounds="${arg#rounds=}"; [[ "$rounds" =~ ^[0-9]+$ ]] || { echo "perf-relaunch-reconnect.sh: rounds=N" >&2; exit 2; } ;;
    chats=*) chats="${arg#chats=}"; [[ "$chats" =~ ^[0-9]+$ ]] || { echo "perf-relaunch-reconnect.sh: chats=N" >&2; exit 2; } ;;
    *) echo "perf-relaunch-reconnect.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
cd "$(git rev-parse --show-toplevel)"
work=".build/perf-relaunch-reconnect"
rm -rf "$work"; mkdir -p "$work" artifacts
echo "PERF-RELAUNCH-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) sha=$(git rev-parse HEAD) model=$(sysctl -n hw.model) cores=$(sysctl -n hw.ncpu) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )) macos=$(sw_vers -productVersion) config=$config load=\"$(uptime | sed 's/.*load averages*: //')\""
# A fleet step checks out no submodules (only their empty gitlink directories): the app build needs
# Ghostty's headers and the ghostty-next tree, and GhosttyKit.xcframework (a prebuilt download).
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
release=()
[ "$config" = "Release" ] && release=(--release)
[ "$config" = "bench" ] && release=(--config bench)
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag perfrelaunch "${release[@]}" 2>&1 | tee "$work/reload.log" || { tail -n 80 "$work/reload.log"; exit 1; }
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$work/reload.log" | tail -n 1)"
[[ -n "$app" && -d "$app" ]] || { echo "perf-relaunch-reconnect: reload printed no app path" >&2; tail -n 40 "$work/reload.log"; exit 1; }
extra=()
[ -n "$modes" ] && extra+=(--modes "$modes")
[ -n "$rounds" ] && extra+=(--rounds "$rounds")
[ -n "$chats" ] && extra+=(--chats "$chats")
python3 scripts/cmux-next/bench_relaunch_reconnect.py --app "$app" \
  --out artifacts/perf-relaunch-reconnect.json --md artifacts/perf-relaunch-reconnect.md ${extra[@]+"${extra[@]}"}
