#!/usr/bin/env bash
# Fleet entry for the cmux-next crash gate ("Crash ends the app", cmux-next.yml step crash-gate):
# builds a tagged Debug cmux-next app at this checkout, then runs
# scripts/cmux-next/crash-ends-app-gate.py against it, as the CI step does with the app that
# cmux-scheme-compile built. On a feat-cmux-next push that job is skipped, so this is how a tip
# gets the gate. It launches an app with Sentry on and crashes it on purpose, so it runs alone in a
# GUI session:
#   cmux-ci run --class exclusive --label measure --label gui-session-v1 \
#     --script scripts/measure/crash-gate.sh --ref <sha> [--arg=--runs=exception,frozen,suspended]
# Every argument goes to crash-ends-app-gate.py (default: its CI runs, exception and frozen).
# The verdict is the gate's own last line: "PASS every crash ended the app in time" or "FAIL ...".
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
sha="$(git rev-parse HEAD)"
tag="crashgate-${sha:0:8}"
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
out="$(mktemp -d)"
# Steps run with a per-step HOME; the account's user-level tools (bun and node for the Debug
# build's web bundles) live under its real home (as tab-switch.sh).
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
done
RUNNER_TEMP="$out" GITHUB_PATH="$out/bun-path" ./scripts/cmux-next/private-bun.sh
PATH="$(tail -n 1 "$out/bun-path"):$PATH"
export PATH
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --no-global-cli-links 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "crash-gate: the tagged reload printed no app path (not a crash freeze)" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
echo "crash-gate: commit $sha app $app"
# The gate ends each launch's daemons itself (TagTeardown); this also ends what a killed gate left.
trap 'python3 scripts/cmux-next/tag_teardown.py "$app" || true' EXIT
python3 scripts/cmux-next/crash-ends-app-gate.py --app "$app" --out "$out/gate" "$@"
