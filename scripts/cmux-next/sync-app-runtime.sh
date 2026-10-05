#!/usr/bin/env bash
# Copies the app platform files the Swift module CmuxNextApps bundles from
# their owners into Packages/macOS/CmuxNext/Sources/CmuxNextApps/Resources/AppPlatform:
#   cmux-tui/crates/cmux-app-host/js/dist/cmux-app-runtime.js -> runtime/
#   cmux-tui/crates/cmux-app-host/js/ABI.md                   -> runtime/ (when present)
#   cmux-tui/crates/cmux-app-host/schema/cmux-app.schema.json + fixtures/ -> schema/
#   cmux-tui/crates/cmux-app-host/generated/scopes.json      -> scopes.json
#   cmux-tui/crates/cmux-app-host/schema/v2/scope-classes.json -> scope-classes.json (risk class per scope)
#   first-party-apps/<name>/{cmux-app.json,cmux-app.v2.json,dist/,assets/} -> first-party/<name>/ (only apps with a
#     BUNDLED marker: they ship inside cmux, installed by default and hideable)
#   samples/apps/<name>/{cmux-app.json,dist/,assets/}        -> samples/<name>/ (built samples only;
#     a sample with a NOT_BUNDLED file stays out, e.g. one that needs a manifest
#     feature the Swift validator does not decode yet)
# The app platform lead owns the sources (plans/cmux-next/app-platform.md);
# never edit the copies. `--check` exits 1 when a copy differs from its source.
# CMUX_APP_HOST_DIR and CMUX_APP_SAMPLES_DIR override the source directories.
# Usage: scripts/cmux-next/sync-app-runtime.sh [--check]
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
host="${CMUX_APP_HOST_DIR:-$root/cmux-tui/crates/cmux-app-host}"
samples="${CMUX_APP_SAMPLES_DIR:-$root/samples/apps}"
first_party="${CMUX_APP_FIRST_PARTY_DIR:-$root/first-party-apps}"
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
copy "$host/schema/v2/scope-classes.json" scope-classes.json
mkdir -p "$stage/samples"
if [[ -d "$samples" ]]; then
  for app in "$samples"/*/; do
    name="$(basename "$app")"
    [[ -f "$app/cmux-app.json" ]] || continue
    [[ -f "$app/NOT_BUNDLED" ]] && continue
    copy "$app/cmux-app.json" "samples/$name/cmux-app.json"
    [[ -d "$app/dist" ]] && copy "$app/dist" "samples/$name/dist"
    [[ -d "$app/assets" ]] && copy "$app/assets" "samples/$name/assets"
  done
fi
mkdir -p "$stage/first-party"
if [[ -d "$first_party" ]]; then
  for app in "$first_party"/*/; do
    name="$(basename "$app")"
    [[ -f "$app/BUNDLED" ]] || continue
    [[ -f "$app/cmux-app.json" || -f "$app/cmux-app.v2.json" ]] || continue
    [[ -f "$app/cmux-app.json" ]] && copy "$app/cmux-app.json" "first-party/$name/cmux-app.json"
    [[ -f "$app/cmux-app.v2.json" ]] && copy "$app/cmux-app.v2.json" "first-party/$name/cmux-app.v2.json"
    [[ -d "$app/dist" ]] && copy "$app/dist" "first-party/$name/dist"
    [[ -d "$app/assets" ]] && copy "$app/assets" "first-party/$name/assets"
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
