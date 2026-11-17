#!/usr/bin/env bash
# Copies the app platform files the Swift module CmuxNextApps still needs
# from their owners into Packages/macOS/CmuxNext/Sources/CmuxNextApps/Resources/AppPlatform:
#   cmux-tui/crates/cmux-app-host/generated/scopes.json      -> scopes.json (permission policy)
#   cmux-tui/crates/cmux-app-host/schema/v2/scope-classes.json -> scope-classes.json (risk class per scope)
#   first-party-apps/<name>/{cmux-app.v2.json (else cmux-app.json),dist/,assets/,catalog/} -> first-party/<name>/
#     (only apps with a BUNDLED marker: whole packages, because the App points the
#     local daemon's app supervisor at this directory as CMUX_APPS_FIRST_PARTY_DIR;
#     they are installed for everyone and hideable)
#   samples/apps/<name>/{cmux-app.json,assets/}              -> samples/<name>/ (demo transport and
#     store icons; a sample with a NOT_BUNDLED file stays out)
# and, as build output (gitignored, never committed; Leo, 2026-10-21: "don't commit generatable
# files"), the App Store packages the App hands its daemon as CMUX_APPS_DIRS, in store/:
#   samples/apps/<name>/{cmux-app.v2.json,dist/,assets/,catalog/} -> store/<name>/ (apps with a STORE
#     marker: the App Store examples)
#   first-party-apps/<name>/{manifest v2,dist/,assets/,catalog/,screenshots/} -> store/<name>/ (a STORE
#     marker and no BUNDLED one: first-party store apps such as the widgets, listed, never installed by default)
# Every app build path writes store/ before it compiles: scripts/cmux-next/build-web-bundles.sh runs
# `--store` (dev reloads, CI, nightly and release builds), its `--verify` (the Xcode build phase) runs
# `--store --check`, and scripts/cmux-next/check-app-bundle.sh fails a built app that lacks a package.
# The app supervisor in the daemon runs apps and validates manifests (step 3),
# so the client bundles no runtime, schema, fixtures or sample code.
# The app platform lead owns the sources (plans/cmux-next/app-platform.md); never edit the copies.
#   (no flag)        write every copy, store/ included
#   --check          exit 1 when a committed copy differs from its source (store/ is not looked at)
#   --store          write store/ only
#   --store --check  exit 1 when store/ is missing or differs from its sources
# CMUX_APP_HOST_DIR, CMUX_APP_SAMPLES_DIR and CMUX_APP_FIRST_PARTY_DIR override the source
# directories, CMUX_APP_PLATFORM_DIR the destination (tests).
# Usage: scripts/cmux-next/sync-app-runtime.sh [--store] [--check]
set -euo pipefail
# From the script's own place, not the working directory: the Xcode build phase runs it too.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
host="${CMUX_APP_HOST_DIR:-$root/cmux-tui/crates/cmux-app-host}"
samples="${CMUX_APP_SAMPLES_DIR:-$root/samples/apps}"
first_party="${CMUX_APP_FIRST_PARTY_DIR:-$root/first-party-apps}"
dest="${CMUX_APP_PLATFORM_DIR:-$root/Packages/macOS/CmuxNext/Sources/CmuxNextApps/Resources/AppPlatform}"
mode="sync"
scope="all"
for arg in "$@"; do
  case "$arg" in
    --check) mode="check" ;;
    --store) scope="store" ;;
    *) echo "usage: $0 [--store] [--check]" >&2; exit 2 ;;
  esac
done

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

copy() { # source relative-destination
  local from="$1" to="$stage/$2"
  [[ -e "$from" ]] || { echo "sync-app-runtime: missing $from" >&2; exit 1; }
  mkdir -p "$(dirname "$to")"
  cp -R "$from" "$to"
}

# The committed copies: the scope tables, the sample manifests and the BUNDLED first-party apps.
stage_committed() {
  local app name
  copy "$host/generated/scopes.json" scopes.json
  copy "$host/schema/v2/scope-classes.json" scope-classes.json
  mkdir -p "$stage/samples"
  if [[ -d "$samples" ]]; then
    for app in "$samples"/*/; do
      name="$(basename "$app")"
      [[ -f "$app/cmux-app.json" ]] || continue
      [[ -f "$app/NOT_BUNDLED" ]] && continue
      copy "$app/cmux-app.json" "samples/$name/cmux-app.json"
      [[ -d "$app/assets" ]] && copy "$app/assets" "samples/$name/assets"
    done
  fi
  mkdir -p "$stage/first-party"
  if [[ -d "$first_party" ]]; then
    for app in "$first_party"/*/; do
      name="$(basename "$app")"
      [[ -f "$app/BUNDLED" ]] || continue
      [[ -f "$app/cmux-app.json" || -f "$app/cmux-app.v2.json" ]] || continue
      # The supervisor reads the v2 manifest in its first-party directory; the v1 file goes only without one.
      if [[ -f "$app/cmux-app.v2.json" ]]; then
        copy "$app/cmux-app.v2.json" "first-party/$name/cmux-app.v2.json"
      else
        copy "$app/cmux-app.json" "first-party/$name/cmux-app.json"
      fi
      [[ -d "$app/dist" ]] && copy "$app/dist" "first-party/$name/dist"
      [[ -d "$app/assets" ]] && copy "$app/assets" "first-party/$name/assets"
      [[ -d "$app/catalog" ]] && copy "$app/catalog" "first-party/$name/catalog"
    done
  fi
  # Empty directories do not survive git; keep a marker in each.
  find "$stage" -type d -empty -exec touch {}/.keep \;
}

# The App Store packages (build output): whole packages, because the App hands this folder to its
# daemon as CMUX_APPS_DIRS; they list as apps the person installs, never installed by default.
stage_store() {
  local app name
  mkdir -p "$stage/store"
  # App Store examples (samples/apps/<name> with a STORE marker).
  if [[ -d "$samples" ]]; then
    for app in "$samples"/*/; do
      name="$(basename "$app")"
      [[ -f "$app/STORE" && -f "$app/cmux-app.v2.json" ]] || continue
      copy "$app/cmux-app.v2.json" "store/$name/cmux-app.v2.json"
      for part in dist assets catalog; do
        [[ -d "$app/$part" ]] && copy "$app/$part" "store/$name/$part"
      done
    done
  fi
  # First-party store apps (first-party-apps/<name> with a STORE marker and no BUNDLED one, such as the
  # widgets): listed in the App Store and installed with one click, never by default. Their manifest
  # v2 is cmux-app.v2.json, else a cmux-app.json with manifestVersion 2 (what `cmux ext dev` reads).
  if [[ -d "$first_party" ]]; then
    for app in "$first_party"/*/; do
      name="$(basename "$app")"
      [[ -f "$app/STORE" && ! -f "$app/BUNDLED" ]] || continue
      if [[ -e "$stage/store/$name" ]]; then
        echo "sync-app-runtime: first-party-apps/$name and samples/apps/$name are both App Store packages named $name" >&2
        exit 1
      fi
      if [[ -f "$app/cmux-app.v2.json" ]]; then
        copy "$app/cmux-app.v2.json" "store/$name/cmux-app.v2.json"
      elif grep -q '"manifestVersion": 2' "$app/cmux-app.json" 2>/dev/null; then
        copy "$app/cmux-app.json" "store/$name/cmux-app.v2.json"
      else
        echo "sync-app-runtime: $app has a STORE marker but no manifest v2" >&2
        exit 1
      fi
      for part in dist assets catalog screenshots; do
        [[ -d "$app/$part" ]] && copy "$app/$part" "store/$name/$part"
      done
    done
  fi
  return 0 # the last `[[ -d ]] &&` above may be false: not a failure under set -e
}

# same A B [SKIP]: A and B hold the same files, apart from the top-level entry SKIP.
same() {
  local a="$1" b="$2" skip="${3:-}" name ok=0
  [[ -d "$b" ]] || { echo "sync-app-runtime: $b is missing" >&2; return 1; }
  while IFS= read -r name; do
    [[ -n "$name" && "$name" != "$skip" ]] || continue
    if ! diff -r -x STORE.sig "$a/$name" "$b/$name" >/dev/null 2>&1; then
      diff -rq -x STORE.sig "$a/$name" "$b/$name" >&2 || true
      ok=1
    fi
  done < <({ ls -A "$a"; ls -A "$b"; } | sort -u)
  return "$ok"
}

if [[ "$scope" == "all" ]]; then
  stage_committed
fi
stage_store
# cmux's own store packages get STORE.sig (store-package-sign.py) when the build holds the store key
# (CMUX_STORE_SIGNING_KEY_FILE, CI secret CMUX_STORE_SIGNING_KEY); unsigned ones list as Unverified.
# --check never signs, and `same` leaves STORE.sig out of its comparison.
if [[ "$mode" != "check" && -n "${CMUX_STORE_SIGNING_KEY_FILE:-}" ]]; then
  for app in "$stage/store"/*/; do
    [[ -d "$app" ]] || continue
    python3 "$root/scripts/cmux-next/store-package-sign.py" --key "$CMUX_STORE_SIGNING_KEY_FILE" "$app"
  done
fi

if [[ "$mode" == "check" && "$scope" == "store" ]]; then
  if ! same "$stage/store" "$dest/store"; then
    echo "sync-app-runtime: the App Store packages (AppPlatform/store) are missing or stale; run scripts/cmux-next/sync-app-runtime.sh --store" >&2
    exit 1
  fi
  echo "sync-app-runtime: store packages up to date"
  exit 0
fi
if [[ "$mode" == "check" ]]; then
  # store/ is build output: whatever a build left there is not compared with git's copies.
  if ! same "$stage" "$dest" store; then
    echo "sync-app-runtime: CmuxNextApps resources are stale; run scripts/cmux-next/sync-app-runtime.sh" >&2
    exit 1
  fi
  echo "sync-app-runtime: up to date"
  exit 0
fi
if [[ "$scope" == "store" ]]; then
  mkdir -p "$dest"
  rm -rf "$dest/store"
  cp -R "$stage/store" "$dest/store"
  echo "sync-app-runtime: wrote $dest/store"
  exit 0
fi
rm -rf "$dest"
mkdir -p "$(dirname "$dest")"
cp -R "$stage" "$dest"
echo "sync-app-runtime: wrote $dest"
