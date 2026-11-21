#!/usr/bin/env bash
# Fleet entry for the Clear Browsing Data look on a real Chromium engine: builds a tagged cmux-next app, then
# runs scripts/cmux-next/clear-cache-look.py against it. The driver fills a service worker's Cache Storage in a
# second browser profile, quits the app, starts it again, runs browserProfile.clearBrowsingData (the cache
# option) before Chromium opens that profile, and reads the profile directory and the page's own report.
# Runs alone on the worker because it launches an app and shows a window:
#   cmux-ci run --class exclusive --label measure --script scripts/measure/clear-cache-look.sh --ref <sha> \
#     --artifact artifacts/clear-cache-look.json [--arg=--build-at=SHA]
# --build-at=SHA (first argument) builds the app at SHA, a pull request's head or a base, with that commit's own
# reload.sh, and runs this checkout's driver against it (scripts/measure/app-at-commit.sh).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="clrcache"
build_at=""
if [[ "${1:-}" == --build-at=* ]]; then build_at="${1#--build-at=}"; shift; fi
. scripts/measure/app-at-commit.sh
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
# Remove the scratch folder on every exit (a failed build, a TERM), not only at the end: a leaked one holds a build.
trap 'measure_remove_scratch "$out"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Steps run with a per-step HOME; the account's user-level tools (bun and node for the Debug
# build's web bundles) live under its real home (as perf-bench.sh).
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
done
# The web bundles need the bun webviews/package.json pins; a bench host's shared ~/.bun may hold
# another version. The step gets its own checked copy, first on PATH.
RUNNER_TEMP="$out" GITHUB_PATH="$out/bun-path" ./scripts/cmux-next/private-bun.sh
PATH="$(tail -n 1 "$out/bun-path"):$PATH"
export PATH
if [[ -n "$build_at" ]]; then
  app="$(measure_app_at_commit "$build_at" "$tag" "$out/at")"
else
  CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" 2>&1 | tee "$out/reload.log"
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
fi
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "clear-cache-look: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
mkdir -p artifacts
python3 scripts/cmux-next/clear-cache-look.py --tag "$tag" --app "$app" --out "$out" --json artifacts/clear-cache-look.json "$@"
