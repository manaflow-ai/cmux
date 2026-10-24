#!/usr/bin/env bash
# Scratch test harness for the pl-o-all "No O(all) work per event" batch (not for landing).
# Builds a tagged Debug app at this checkout (as tab-switch.sh), then runs plo-bench.py:
# LIGHT and STRESS Cmd-Tab cycles, control publishes per Cmd-Tab, Cmd-T/Cmd-W signposts,
# a 400-workspace activation-perf session, a sidebar hover proxy and socket behavior checks.
#   cmux-ci run --class exclusive --label measure --script scripts/measure/plo-bench.sh --ref <sha>
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="plobench"
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
out="$(mktemp -d)"
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
done
RUNNER_TEMP="$out" GITHUB_PATH="$out/bun-path" ./scripts/cmux-next/private-bun.sh
PATH="$(tail -n 1 "$out/bun-path"):$PATH"
export PATH
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" 2>&1 | tee "$out/reload.log" | tail -n 40
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "plo-bench: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
mkdir -p artifacts/plo
NX_APP="$app" NX_SRC="$PWD" NX_ARTIFACTS="$PWD/artifacts/plo" python3 scripts/measure/plo-bench.py "$@"
