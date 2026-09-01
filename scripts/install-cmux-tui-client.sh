#!/usr/bin/env bash
# Installs the cmux-tui client into an app bundle as Contents/Resources/bin/cmux-tui,
# the same way the Ghostty CLI helper is bundled: the app carries the exact client
# that talks to cmux Cloud machines, so the Machines panel needs no separate install.
#
# The build comes from the artifacts manifest the cmux-tui-artifacts workflow publishes
# (rolling `latest` by default; a commit-addressed manifest pins one build). Both
# darwin slices are downloaded, sha256-verified against the manifest, and lipo'd into
# one universal binary. Downloads are cached per commit under CMUX_TUI_CLIENT_CACHE.
#
#   scripts/install-cmux-tui-client.sh <app-path> [--manifest-url <url>] [--cache-dir <dir>]
#
# Env: CMUX_TUI_CLIENT_MANIFEST_URL overrides the manifest, CMUX_TUI_CLIENT_LOCAL points at
# a prebuilt universal binary to install instead of downloading (offline/dev builds).
set -euo pipefail

usage() { sed -n '2,13p' "$0"; }

APP_PATH=""
MANIFEST_URL="${CMUX_TUI_CLIENT_MANIFEST_URL:-https://files.cmux.com/cmux-tui/latest/manifest.json}"
CACHE_DIR="${CMUX_TUI_CLIENT_CACHE:-$HOME/Library/Caches/cmux/cmux-tui-client}"
while (( $# )); do
  case "$1" in
    --manifest-url) shift; MANIFEST_URL="${1:?--manifest-url needs a value}" ;;
    --cache-dir) shift; CACHE_DIR="${1:?--cache-dir needs a value}" ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
    *) APP_PATH="$1" ;;
  esac
  shift
done
[[ -n "$APP_PATH" && -d "$APP_PATH/Contents" ]] || { echo "error: app bundle not found at '${APP_PATH:-<missing>}'" >&2; exit 1; }
DEST_DIR="$APP_PATH/Contents/Resources/bin"
DEST="$DEST_DIR/cmux-tui"
mkdir -p "$DEST_DIR"

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

if [[ -n "${CMUX_TUI_CLIENT_LOCAL:-}" ]]; then
  [[ -f "$CMUX_TUI_CLIENT_LOCAL" ]] || { echo "error: CMUX_TUI_CLIENT_LOCAL not found: $CMUX_TUI_CLIENT_LOCAL" >&2; exit 1; }
  install -m 755 "$CMUX_TUI_CLIENT_LOCAL" "$DEST"
  echo "Installed local cmux-tui client at $DEST"
  exit 0
fi

mkdir -p "$CACHE_DIR"
MANIFEST="$CACHE_DIR/manifest.$(printf '%s' "$MANIFEST_URL" | shasum -a 256 | cut -c1-12).json"
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 2 "$MANIFEST_URL" -o "$MANIFEST"
COMMIT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$MANIFEST")"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "error: manifest at $MANIFEST_URL has no commit" >&2; exit 1; }
BASE="${MANIFEST_URL%/manifest.json}"
BUILD_DIR="$CACHE_DIR/$COMMIT"
mkdir -p "$BUILD_DIR"

fetch_slice() { # <artifact-name> -> path
  local name="$1" want got out
  want="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["binaries"].get(sys.argv[2], ""))' "$MANIFEST" "$name")"
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { echo "error: manifest lacks $name" >&2; exit 1; }
  out="$BUILD_DIR/$name"
  if [[ -f "$out" ]] && [[ "$(sha256_of "$out")" == "$want" ]]; then
    printf '%s' "$out"; return
  fi
  curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 2 "$BASE/$name" -o "$out.tmp"
  got="$(sha256_of "$out.tmp")"
  [[ "$got" == "$want" ]] || { echo "error: sha256 mismatch for $name (want $want, got $got)" >&2; rm -f "$out.tmp"; exit 1; }
  mv -f "$out.tmp" "$out"
  printf '%s' "$out"
}

ARM="$(fetch_slice cmux-tui-aarch64-apple-darwin)"
X64="$(fetch_slice cmux-tui-x86_64-apple-darwin)"
UNIVERSAL="$BUILD_DIR/cmux-tui-universal"
if [[ ! -f "$UNIVERSAL" ]]; then
  lipo -create "$ARM" "$X64" -output "$UNIVERSAL.tmp"
  mv -f "$UNIVERSAL.tmp" "$UNIVERSAL"
fi
install -m 755 "$UNIVERSAL" "$DEST"
lipo "$DEST" -verify_arch arm64 x86_64
PROBE="$("$DEST" remote-probe --json 2>/dev/null || true)"
[[ "$PROBE" == *'"app":"cmux-tui"'* ]] || { echo "error: installed binary does not probe as cmux-tui: $PROBE" >&2; exit 1; }
echo "Installed universal cmux-tui client (commit ${COMMIT:0:10}) at $DEST"
