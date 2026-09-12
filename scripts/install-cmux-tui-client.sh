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
#     [--expected-commit <sha>] [--require-capability <name>]...
#
# Env: CMUX_TUI_CLIENT_MANIFEST_URL overrides the manifest, CMUX_TUI_CLIENT_LOCAL points at
# a prebuilt universal binary to install instead of downloading (offline/dev builds).
set -euo pipefail

usage() { sed -n '2,13p' "$0"; }

APP_PATH=""
MANIFEST_URL="${CMUX_TUI_CLIENT_MANIFEST_URL:-https://files.cmux.com/cmux-tui/latest/manifest.json}"
CACHE_DIR="${CMUX_TUI_CLIENT_CACHE:-$HOME/Library/Caches/cmux/cmux-tui-client}"
EXPECTED_COMMIT=""
REQUIRED_CAPABILITIES=()
while (( $# )); do
  case "$1" in
    --manifest-url) shift; MANIFEST_URL="${1:?--manifest-url needs a value}" ;;
    --cache-dir) shift; CACHE_DIR="${1:?--cache-dir needs a value}" ;;
    --expected-commit) shift; EXPECTED_COMMIT="${1:?--expected-commit needs a value}" ;;
    --require-capability) shift; REQUIRED_CAPABILITIES+=("${1:?--require-capability needs a value}") ;;
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

# R2 custom domains can return a transient 5xx while a regional incident is
# being mitigated. Retry a bounded number of times, but never promote a partial
# response: callers either receive a complete file that is subsequently
# checksum-verified or the install fails closed.
DOWNLOAD_ATTEMPTS=3
DOWNLOAD_RETRY_DELAY_SECONDS="${CMUX_TUI_CLIENT_RETRY_DELAY_SECONDS:-2}"
DOWNLOAD_CONNECT_TIMEOUT=10
DOWNLOAD_MAX_TIME=300

if [[ ! "$DOWNLOAD_RETRY_DELAY_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "error: CMUX_TUI_CLIENT_RETRY_DELAY_SECONDS must be a non-negative number" >&2
  exit 2
fi

download_url() { # <url> <destination>
  local url="$1" destination="$2"
  local temp="${destination}.tmp.$$" attempt status display_url
  display_url="${url%%\?*}"
  [[ -n "$display_url" ]] || display_url="$url"

  for ((attempt = 1; attempt <= DOWNLOAD_ATTEMPTS; attempt++)); do
    if curl --proto '=https' --tlsv1.2 --fail --show-error --location \
      --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" \
      --max-time "$DOWNLOAD_MAX_TIME" \
      --retry 1 --retry-delay 1 --retry-max-time 15 --retry-all-errors \
      -o "$temp" \
      "$url"; then
      mv -f "$temp" "$destination"
      return 0
    else
      status=$?
    fi
    rm -f "$temp"
    if ((attempt < DOWNLOAD_ATTEMPTS)); then
      echo "warning: download failed for $display_url (attempt $attempt/$DOWNLOAD_ATTEMPTS); retrying" >&2
      if [[ "$DOWNLOAD_RETRY_DELAY_SECONDS" != 0 ]]; then
        sleep "$DOWNLOAD_RETRY_DELAY_SECONDS"
      fi
    else
      echo "error: failed to download $display_url after $DOWNLOAD_ATTEMPTS attempts" >&2
      return "$status"
    fi
  done
}

verify_probe() {
  local probe capability
  probe="$("$DEST" remote-probe --json 2>/dev/null || true)"
  [[ "$probe" == *'"app":"cmux-tui"'* ]] || {
    echo "error: installed binary does not probe as cmux-tui: $probe" >&2
    exit 1
  }
  # Bash 3.2 treats an empty array as unset under nounset. Expand no arguments
  # when there are no requirements, while preserving each supplied capability.
  for capability in ${REQUIRED_CAPABILITIES[@]+"${REQUIRED_CAPABILITIES[@]}"}; do
    if ! python3 - "$capability" "$probe" <<'PY'
import json
import sys

capability = sys.argv[1]
probe = json.loads(sys.argv[2])
raise SystemExit(0 if capability in probe.get("capabilities", []) else 1)
PY
    then
      echo "error: required cmux-tui capability is missing: $capability" >&2
      exit 1
    fi
  done
}

if [[ -n "${CMUX_TUI_CLIENT_LOCAL:-}" ]]; then
  [[ -f "$CMUX_TUI_CLIENT_LOCAL" ]] || { echo "error: CMUX_TUI_CLIENT_LOCAL not found: $CMUX_TUI_CLIENT_LOCAL" >&2; exit 1; }
  install -m 755 "$CMUX_TUI_CLIENT_LOCAL" "$DEST"
  verify_probe
  echo "Installed local cmux-tui client at $DEST"
  exit 0
fi

mkdir -p "$CACHE_DIR"
MANIFEST="$CACHE_DIR/manifest.$(printf '%s' "$MANIFEST_URL" | shasum -a 256 | cut -c1-12).json"
download_url "$MANIFEST_URL" "$MANIFEST"
COMMIT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$MANIFEST")"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "error: manifest at $MANIFEST_URL has no commit" >&2; exit 1; }
if [[ -n "$EXPECTED_COMMIT" && "$COMMIT" != "$EXPECTED_COMMIT" ]]; then
  echo "error: cmux-tui manifest commit mismatch (expected $EXPECTED_COMMIT, got $COMMIT)" >&2
  exit 1
fi
BASE="${MANIFEST_URL%/manifest.json}"
# The rolling latest/ prefix is rewritten on every main push, so a slice fetched
# a moment after the manifest can belong to a newer build and fail its checksum.
# The publisher also stores every build under its commit, immutably; fetch the
# slices from there whenever the manifest came from the rolling prefix.
if [[ "$BASE" == */latest ]]; then
  BASE="${BASE%/latest}/$COMMIT"
fi
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
  download_url "$BASE/$name" "$out"
  got="$(sha256_of "$out")"
  [[ "$got" == "$want" ]] || { echo "error: sha256 mismatch for $name (want $want, got $got)" >&2; rm -f "$out"; exit 1; }
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
# One arch per invocation: some lipo builds (Xcode 27 beta 4) consume only one
# arch after -verify_arch and read the second as an extra input file, failing
# with "requires exactly one input file".
for arch in arm64 x86_64; do lipo "$DEST" -verify_arch "$arch"; done
verify_probe
echo "Installed universal cmux-tui client (commit ${COMMIT:0:10}) at $DEST"
