#!/usr/bin/env bash
# Copies the app platform files the Swift module CmuxNextApps still needs
# from their owners into Packages/macOS/CmuxNext/Sources/CmuxNextApps/Resources/AppPlatform:
#   cmux-tui/crates/cmux-app-host/generated/scopes.json -> scopes.json (permission policy)
#   samples/apps/<name>/{cmux-app.json,assets/}         -> samples/<name>/ (demo transport, store icons)
# The app supervisor in the daemon runs apps (step 3), so the client bundles
# no runtime, schema, fixtures or app code.
# The app platform lead owns the sources (plans/cmux-next/app-platform.md);
# never edit the copies. `--check` exits 1 when a copy differs from its source.
# CMUX_APP_HOST_DIR and CMUX_APP_SAMPLES_DIR override the source directories.
# Usage: scripts/cmux-next/sync-app-runtime.sh [--check]
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
host="${CMUX_APP_HOST_DIR:-$root/cmux-tui/crates/cmux-app-host}"
samples="${CMUX_APP_SAMPLES_DIR:-$root/samples/apps}"
dest="$root/Packages/macOS/CmuxNext/Sources/CmuxNextApps/Resources/AppPlatform"
mode="sync"
[[ "${1:-}" == "--check" ]] && mode="check"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

copy() { # source relative-destination
  local from="$1" to="$stage/$2"
  [[ -e "$from" ]] || { echo "sync-app-runtime: missing $from" >&2; exit 1; }
  mkdir -p "$(dirname "$to")"
  cp -R "$from" "$to"
}

copy "$host/generated/scopes.json" scopes.json
mkdir -p "$stage/samples"
if [[ -d "$samples" ]]; then
  for app in "$samples"/*/; do
    name="$(basename "$app")"
    [[ -f "$app/cmux-app.json" ]] || continue
    copy "$app/cmux-app.json" "samples/$name/cmux-app.json"
    if [[ -d "$app/assets" ]]; then copy "$app/assets" "samples/$name/assets"; fi
  done
fi
# Empty directories do not survive git; keep a marker in each.
find "$stage" -type d -empty -exec touch {}/.keep \;

if [[ "$mode" == "check" ]]; then
  if ! diff -r "$stage" "$dest" >/dev/null 2>&1; then
    diff -rq "$stage" "$dest" >&2 || true
    echo "sync-app-runtime: CmuxNextApps resources are stale; run scripts/cmux-next/sync-app-runtime.sh" >&2
    exit 1
  fi
  echo "sync-app-runtime: up to date"
  exit 0
fi
rm -rf "$dest"
mkdir -p "$(dirname "$dest")"
cp -R "$stage" "$dest"
echo "sync-app-runtime: wrote $dest"
