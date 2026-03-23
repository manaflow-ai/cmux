#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/cmux-paths.sh"
cmux_paths_init "${BASH_SOURCE[0]}"

if [ -n "${GHOSTTY_SHA:-}" ]; then
  GHOSTTY_SHA="$GHOSTTY_SHA"
else
  if [ ! -d "$CMUX_GHOSTTY_DIR" ] || ! git -C "$CMUX_GHOSTTY_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Missing ghostty submodule. Run ./scripts/setup.sh or git submodule update --init --recursive first." >&2
    exit 1
  fi
  GHOSTTY_SHA="$(git -C "$CMUX_GHOSTTY_DIR" rev-parse HEAD)"
fi

TAG="xcframework-$GHOSTTY_SHA"
ARCHIVE_NAME="${GHOSTTYKIT_ARCHIVE_NAME:-GhosttyKit.xcframework.tar.gz}"
OUTPUT_DIR="${GHOSTTYKIT_OUTPUT_DIR:-$CMUX_GHOSTTYKIT_PATH}"
OUTPUT_PARENT_DIR="$(dirname "$OUTPUT_DIR")"
CHECKSUMS_FILE="${GHOSTTYKIT_CHECKSUMS_FILE:-$SCRIPT_DIR/ghosttykit-checksums.txt}"
DOWNLOAD_URL="${GHOSTTYKIT_URL:-https://github.com/manaflow-ai/ghostty/releases/download/$TAG/$ARCHIVE_NAME}"
DOWNLOAD_RETRIES="${GHOSTTYKIT_DOWNLOAD_RETRIES:-30}"
DOWNLOAD_RETRY_DELAY="${GHOSTTYKIT_DOWNLOAD_RETRY_DELAY:-20}"

if [ ! -f "$CHECKSUMS_FILE" ]; then
  echo "Missing checksum file: $CHECKSUMS_FILE" >&2
  exit 1
fi

EXPECTED_SHA256="$(
  awk -v sha="$GHOSTTY_SHA" '
    $1 == sha {
      print $2
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$CHECKSUMS_FILE" || true
)"

if [ -z "$EXPECTED_SHA256" ]; then
  echo "Missing pinned GhosttyKit checksum for ghostty $GHOSTTY_SHA in $CHECKSUMS_FILE" >&2
  exit 1
fi

echo "Downloading $ARCHIVE_NAME for ghostty $GHOSTTY_SHA"
mkdir -p "$OUTPUT_PARENT_DIR"
curl --fail --show-error --location \
  --retry "$DOWNLOAD_RETRIES" \
  --retry-delay "$DOWNLOAD_RETRY_DELAY" \
  --retry-all-errors \
  -o "$OUTPUT_PARENT_DIR/$ARCHIVE_NAME" \
  "$DOWNLOAD_URL"

ACTUAL_SHA256="$(shasum -a 256 "$OUTPUT_PARENT_DIR/$ARCHIVE_NAME" | awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
  echo "$ARCHIVE_NAME checksum mismatch" >&2
  echo "Expected: $EXPECTED_SHA256" >&2
  echo "Actual:   $ACTUAL_SHA256" >&2
  exit 1
fi

rm -rf "$OUTPUT_DIR"
tar -C "$OUTPUT_PARENT_DIR" -xzf "$OUTPUT_PARENT_DIR/$ARCHIVE_NAME"
rm "$OUTPUT_PARENT_DIR/$ARCHIVE_NAME"
test -d "$OUTPUT_DIR"

echo "Verified and extracted $OUTPUT_DIR"
