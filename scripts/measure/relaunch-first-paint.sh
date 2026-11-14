#!/usr/bin/env bash
# Fleet entry for the first launch after an update, as the person sees it (Leo, 2026-11-14, after a nightly
# update: "terminal is instantly shown, then browser, and then the agent chat after a bit and after a jolt of
# rendering"): builds a tagged cmux-next app at this checkout (bench config: Release optimization with the
# debug.* commands kept) and runs scripts/cmux-next/bench_relaunch_reconnect.py against it with an idle chat of
# a long transcript shown beside a terminal and a browser pane. Each round quits the app and relaunches it as
# its mode says (warm: the same bundle; new-version: the bundle replaced by the next version of itself, as an
# update installs it), and times from the window's first frame (a) the terminal's content, (b) the browser's
# first paint, (c) the chat's transcript on screen and (d) the chat final, with no layout shift after it.
# It launches an app, so it runs alone on a display worker:
#   cmux-ci run --class exclusive --measurement --label measure --display --script scripts/measure/relaunch-first-paint.sh \
#     --ref <sha> --artifact artifacts/relaunch-first-paint.json [--arg=modes=warm,new-version] [--arg=rounds=3] \
#     [--arg=chats=6] [--arg=turns=40]
# The log prints the median table between PERF-RELAUNCH-TABLE-BEGIN and -END.
set -euo pipefail
modes="warm,new-version"
rounds=3
chats=6
turns=40
for arg in "$@"; do
  case "$arg" in
    modes=*) modes="${arg#modes=}"; [[ "$modes" =~ ^[a-z,-]+$ ]] || { echo "relaunch-first-paint.sh: modes=warm,update,new-version,cold" >&2; exit 2; } ;;
    rounds=*) rounds="${arg#rounds=}"; [[ "$rounds" =~ ^[0-9]+$ ]] || { echo "relaunch-first-paint.sh: rounds=N" >&2; exit 2; } ;;
    chats=*) chats="${arg#chats=}"; [[ "$chats" =~ ^[0-9]+$ ]] || { echo "relaunch-first-paint.sh: chats=N" >&2; exit 2; } ;;
    turns=*) turns="${arg#turns=}"; [[ "$turns" =~ ^[0-9]+$ ]] || { echo "relaunch-first-paint.sh: turns=N" >&2; exit 2; } ;;
    *) echo "relaunch-first-paint.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
cd "$(git rev-parse --show-toplevel)"
work=".build/relaunch-first-paint"
rm -rf "$work"; mkdir -p "$work" artifacts
echo "RELAUNCH-FIRST-PAINT-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) sha=$(git rev-parse HEAD) model=$(sysctl -n hw.model) cores=$(sysctl -n hw.ncpu) macos=$(sw_vers -productVersion) load=\"$(uptime | sed 's/.*load averages*: //')\""
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
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag rfpaint --config bench 2>&1 | tee "$work/reload.log" || { tail -n 80 "$work/reload.log"; exit 1; }
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$work/reload.log" | tail -n 1)"
[[ -n "$app" && -d "$app" ]] || { echo "relaunch-first-paint: reload printed no app path" >&2; tail -n 40 "$work/reload.log"; exit 1; }
python3 scripts/cmux-next/bench_relaunch_reconnect.py --app "$app" --modes "$modes" --rounds "$rounds" --chats "$chats" \
  --shown idle --turns "$turns" --browser --out artifacts/relaunch-first-paint.json --md artifacts/relaunch-first-paint.md
