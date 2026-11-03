#!/usr/bin/env bash
# Tagged-build hidden chat draft/scroll/cover check. Runs as class exclusive.
# cmux-ci run --display --class exclusive --measurement --label measure \
#   --script scripts/measure/hidden-chat-wake.sh --ref SHA
# Uses reload.sh's warm fleet compile inputs; only the WebKit runtime check needs a Mac.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
  rm -rf GhosttyKit.xcframework
  if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
    export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
  fi
  ./scripts/download-prebuilt-ghosttykit.sh
fi
out="$PWD/.build/hidden-chat-wake"
mkdir -p "$out"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag chatwake --config bench "$@" 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
[[ -n "$app" && -d "$app" ]] || { echo "hidden-chat-wake: tagged build printed no app path" >&2; exit 1; }
CMUX_BENCH_LAUNCH=direct python3 scripts/cmux-next/hidden-chat-wake.py --app "$app" --out "$out"
tar -czf "$out/evidence.tar.gz" -C "$out" report.json before.png after.png wake-frames
