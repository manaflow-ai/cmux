#!/usr/bin/env bash
# Fleet entry for chat-open-bench.py: click to first content for a sidebar chat, a chat opened
# again, a subagent, a chat of thousands of turns and a chat restored after a relaunch, idle and
# under an agent-like load at default priority, at utility QoS and at nice 20 (Leo, 2026-10-29:
# "as in i want ours to load fast too :(" and "how much of this is simply putting the desktop at
# higher priority?"). Builds a tagged cmux-next app at this checkout (bench configuration: Release
# optimization with the debug.* control methods kept), then runs the bench. Runs alone on the
# worker because it launches an app and loads every core:
#   cmux-ci run --class exclusive --label measure --script scripts/measure/chat-open.sh --ref <sha> \
#     --artifact artifacts/chat-open.json --artifact artifacts/chat-open.md [--arg=--runs=3]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# A step's checkout has empty submodules: reload.sh needs Ghostty's headers (GhosttyKit itself comes
# from the pinned cache) and ghostty-next for the bundled cmux-tui.
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
tag="chatopen"
out="$(mktemp -d)"
reload_config=(--config bench) bench_args=()
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    *) bench_args+=("$arg") ;;
  esac
done
set -- ${bench_args[@]+"${bench_args[@]}"}
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" "${reload_config[@]}" 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "chat-open: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
mkdir -p artifacts
# A fleet step has no LaunchServices session: the bench launches the app binary directly.
CMUX_BENCH_LAUNCH=direct exec python3 scripts/cmux-next/chat-open-bench.py --app "$app" \
  --json artifacts/chat-open.json --md artifacts/chat-open.md "$@"
