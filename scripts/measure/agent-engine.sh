#!/usr/bin/env bash
# Fleet entry for the agent chat engine spike (the `agent.chromium` Debug toggle): builds a tagged
# cmux-next DEBUG app at this checkout, then runs scripts/cmux-next/agent-engine-bench.py (the chat on
# its own WebKit host, on the page host in WebKit and on the page host in Chromium: open time, memory
# for 1 and 10 chats, flings, composer typing, and with --activate which window takes the keys).
# Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --label measure --script scripts/measure/agent-engine.sh --ref <sha> \
#     --artifact artifacts/agent-engine.json [--arg=--activate]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# A step's checkout has empty submodules: reload.sh needs Ghostty's headers (GhosttyKit itself comes
# from the pinned cache) and ghostty-next for the bundled cmux-tui.
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
tag="agentengine"
out="$(mktemp -d)"
# --config=<debug|release|bench> picks reload.sh's build configuration (bench: Release optimization with the
# debug.* control commands kept); every other argument goes to the bench.
reload_config=() bench_args=()
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    *) bench_args+=("$arg") ;;
  esac
done
set -- ${bench_args[@]+"${bench_args[@]}"}
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" ${reload_config[@]+"${reload_config[@]}"} 2>&1 | tee "$out/reload.log" | tail -n 40
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "agent-engine: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
mkdir -p artifacts
exec python3 scripts/cmux-next/agent-engine-bench.py --tag "$tag" --app "$app" --out "$out" \
  --json artifacts/agent-engine.json "$@"
