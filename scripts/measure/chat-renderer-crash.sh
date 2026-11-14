#!/usr/bin/env bash
# Fleet entry for the chat renderer crash test and bench (Leo, 2026-11-14, process-sharing row 2: agent
# chats capped at 8 per cmux-page renderer): builds a tagged cmux-next DEV app at this checkout, then runs
# scripts/cmux-next/chat_renderer_crash.py: 20 answered chats on the acpmux test agent (renderers,
# chat pages per renderer and footprint at 1, 10 and 20 chats), then at 20 chats a SIGKILL of the
# renderer holding the most chat pages. It passes when at most 8 pages reloaded and no page of another
# renderer lost its script state. Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/chat-renderer-crash.sh \
#     --ref <sha> --artifact artifacts/chat-renderer-crash/report.json [--arg=--chats=20] [--arg=--crash-at=20]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# A step's checkout has empty submodules: reload.sh needs Ghostty's headers (GhosttyKit itself comes
# from the pinned cache) and ghostty-next for the bundled cmux-tui.
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
tag="chatcrash"
out="$PWD/artifacts/chat-renderer-crash"
mkdir -p "$out"
echo "CHAT-RENDERERS-HOST host=$(scutil --get ComputerName 2>/dev/null || hostname) sha=$(git rev-parse HEAD) ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 )) macos=$(sw_vers -productVersion)"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --no-global-cli-links 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "chat-renderer-crash: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
# A fleet step has no LaunchServices session: run the app binary itself (bench_memory.launch).
CMUX_BENCH_LAUNCH=direct python3 scripts/cmux-next/chat_renderer_crash.py --app "$app" --out "$out/report.json" "$@"
