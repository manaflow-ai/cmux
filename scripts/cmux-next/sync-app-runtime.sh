#!/usr/bin/env bash
# Copies the app platform files the Swift module CmuxNextApps bundles from
# their owners into Packages/macOS/CmuxNext/Sources/CmuxNextApps/Resources/AppPlatform:
#   cmux-tui/crates/cmux-app-host/js/dist/cmux-app-runtime.js -> runtime/
#   cmux-tui/crates/cmux-app-host/js/ABI.md                   -> runtime/ (when present)
#   cmux-tui/crates/cmux-app-host/schema/cmux-app.schema.json + fixtures/ -> schema/
#   cmux-tui/crates/cmux-app-host/generated/scopes.json      -> scopes.json
# samples/ under that directory is a frozen copy of the manifest v1 samples the
# JavaScriptCore prototype reads (its manifest model is v1); the samples moved
# to manifest v2, so they are no longer synced. The Swift lane deletes the copy
# with the prototype (app platform step 3).
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

copy "$host/js/dist/cmux-app-runtime.js" runtime/cmux-app-runtime.js
[[ -f "$host/js/ABI.md" ]] && copy "$host/js/ABI.md" runtime/ABI.md
copy "$host/schema/cmux-app.schema.json" schema/cmux-app.schema.json
for kind in valid invalid; do
  mkdir -p "$stage/schema/fixtures/$kind"
  if [[ -d "$host/schema/fixtures/$kind" ]]; then
    find "$host/schema/fixtures/$kind" -maxdepth 1 -name '*.json' -exec cp {} "$stage/schema/fixtures/$kind/" \;
  fi
done
copy "$host/generated/scopes.json" scopes.json
# Empty directories do not survive git; keep a marker in each.
find "$stage" -type d -empty -exec touch {}/.keep \;

# Only the synced paths are compared and replaced; the frozen samples stay.
synced=(runtime schema scopes.json)
if [[ "$mode" == "check" ]]; then
  stale=0
  for path in "${synced[@]}"; do
    diff -r "$stage/$path" "$dest/$path" >/dev/null 2>&1 || { diff -rq "$stage/$path" "$dest/$path" >&2 || true; stale=1; }
  done
  if (( stale )); then
    echo "sync-app-runtime: CmuxNextApps resources are stale; run scripts/cmux-next/sync-app-runtime.sh" >&2
    exit 1
  fi
  echo "sync-app-runtime: up to date"
  exit 0
fi
mkdir -p "$dest"
for path in "${synced[@]}"; do
  rm -rf "${dest:?}/$path"
  cp -R "$stage/$path" "$dest/$path"
done
echo "sync-app-runtime: wrote $dest"
