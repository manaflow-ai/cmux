#!/usr/bin/env bash
# Fleet entry for terminal typing while the sidebar rearranges (sidebar-churn-typing): builds a tagged cmux-next
# app at this checkout, then runs scripts/cmux-next/sidebar-churn-typing.py against it (keys into a `cat`
# terminal, idle and while a thread moves workspaces, changes task status, groups and status pills; key-to-frame
# p50/p95/max, main-thread hangs, frames, optional Time Profiler). Needs a logged-in console (an owned mini).
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/sidebar-churn-typing.sh \
#     --ref <sha> --artifact artifacts/sidebar-churn-typing [--arg=--trace] [--arg=--gate-p95-ms=8]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
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
tag="sidebar-churn-typing"
out="$(pwd)/artifacts/sidebar-churn-typing"
mkdir -p "$out"
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" 2>&1 | tee "$out/reload.log" | tail -n 40
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "sidebar-churn-typing: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
exec python3 scripts/cmux-next/sidebar-churn-typing.py --tag "$tag" --app "$app" --out "$out" --json "$out/report.json" "$@"
