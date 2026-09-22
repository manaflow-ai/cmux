#!/usr/bin/env bash
set -euo pipefail

VERIFY_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --verify-only)
      VERIFY_ONLY=1
      ;;
    -h|--help)
      cat <<'EOF'
Usage: download-prebuilt-ghosttykit.sh [--verify-only]

Download, verify, and extract the pre-built GhosttyKit.xcframework. The
--verify-only mode performs the same release URL, checksum, and archive checks
without extracting the framework; CI uses it to validate release provenance
independently of build caches.
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -n "${GHOSTTY_SHA:-}" ]; then
  GHOSTTY_SHA="$GHOSTTY_SHA"
else
  if [ ! -d "$REPO_ROOT/ghostty" ] || ! git -C "$REPO_ROOT/ghostty" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Missing ghostty submodule. Run ./scripts/setup.sh or git submodule update --init --recursive first." >&2
    exit 1
  fi
  GHOSTTY_SHA="$(git -C "$REPO_ROOT/ghostty" rev-parse HEAD)"
fi

GHOSTTYKIT_CRASH_REPORT_SUBDIR="${GHOSTTYKIT_CRASH_REPORT_SUBDIR:-cmux/crash}"
GHOSTTYKIT_BUILD_FLAVOR="${GHOSTTYKIT_BUILD_FLAVOR:-crashsubdir-$(printf '%s' "$GHOSTTYKIT_CRASH_REPORT_SUBDIR" | tr '/=' '--')-sentry-off-noi18n-v2}"
TAG="${GHOSTTYKIT_RELEASE_TAG:-xcframework-$GHOSTTY_SHA-$GHOSTTYKIT_BUILD_FLAVOR}"
ARCHIVE_NAME="${GHOSTTYKIT_ARCHIVE_NAME:-GhosttyKit.xcframework.tar.gz}"
OUTPUT_DIR="${GHOSTTYKIT_OUTPUT_DIR:-GhosttyKit.xcframework}"
CHECKSUMS_FILE="${GHOSTTYKIT_CHECKSUMS_FILE:-$SCRIPT_DIR/ghosttykit-checksums.txt}"
DOWNLOAD_URL="${GHOSTTYKIT_URL:-https://github.com/manaflow-ai/ghostty/releases/download/$TAG/$ARCHIVE_NAME}"
DOWNLOAD_RETRIES="${GHOSTTYKIT_DOWNLOAD_RETRIES:-30}"
DOWNLOAD_RETRY_DELAY="${GHOSTTYKIT_DOWNLOAD_RETRY_DELAY:-20}"
DOWNLOAD_CONNECT_TIMEOUT="${GHOSTTYKIT_DOWNLOAD_CONNECT_TIMEOUT:-10}"
# CI's release mirror can sustain a healthy but slow transfer; keep a bounded
# timeout while allowing the pinned archive to finish on a busy runner.
DOWNLOAD_MAX_TIME="${GHOSTTYKIT_DOWNLOAD_MAX_TIME:-900}"
# A connection that stays under this rate for this long is dropped and the
# transfer resumes on a new one. Without it a crawling connection is held until
# DOWNLOAD_MAX_TIME and then restarted from zero, so it can never finish.
DOWNLOAD_STALL_BYTES_PER_SECOND="${GHOSTTYKIT_DOWNLOAD_STALL_BYTES_PER_SECOND:-262144}"
DOWNLOAD_STALL_SECONDS="${GHOSTTYKIT_DOWNLOAD_STALL_SECONDS:-15}"
ARCHIVE_VALIDATOR="${GHOSTTYKIT_ARCHIVE_VALIDATOR:-$SCRIPT_DIR/validate-xcframework-archive.py}"

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
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ghosttykit-download.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
ARCHIVE_BASENAME="$(basename "$ARCHIVE_NAME")"
ARCHIVE_PATH="$TMP_DIR/$ARCHIVE_BASENAME"
EXTRACT_DIR="$TMP_DIR/extract"
mkdir -p "$EXTRACT_DIR"

archive_matches_checksum() {
  [ -f "$ARCHIVE_PATH" ] && [ "$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')" = "$EXPECTED_SHA256" ]
}

# Each attempt is its own curl process so --continue-at resumes from the bytes
# already on disk; curl's built-in --retry starts the file over.
attempt=0
while :; do
  attempt=$((attempt + 1))
  status=0
  curl --fail --show-error --location \
    --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" \
    --max-time "$DOWNLOAD_MAX_TIME" \
    --speed-limit "$DOWNLOAD_STALL_BYTES_PER_SECOND" \
    --speed-time "$DOWNLOAD_STALL_SECONDS" \
    --continue-at - \
    -o "$ARCHIVE_PATH" \
    "$DOWNLOAD_URL" || status=$?
  if [ "$status" -eq 0 ] || archive_matches_checksum; then
    break
  fi
  if [ "$attempt" -gt "$DOWNLOAD_RETRIES" ]; then
    echo "Failed to download $ARCHIVE_NAME after $attempt attempts (curl exit $status)" >&2
    exit 1
  fi
  # 33: the server refused the byte range, so the partial file cannot be resumed.
  if [ "$status" -eq 33 ]; then
    rm -f "$ARCHIVE_PATH"
  fi
  echo "Download attempt $attempt failed (curl exit $status); retrying in ${DOWNLOAD_RETRY_DELAY}s" >&2
  sleep "$DOWNLOAD_RETRY_DELAY"
done

ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
  echo "$ARCHIVE_NAME checksum mismatch" >&2
  echo "Expected: $EXPECTED_SHA256" >&2
  echo "Actual:   $ACTUAL_SHA256" >&2
  exit 1
fi

python3 "$ARCHIVE_VALIDATOR" "$ARCHIVE_PATH"

if [ "$VERIFY_ONLY" -eq 1 ]; then
  echo "Verified $ARCHIVE_NAME for ghostty $GHOSTTY_SHA (release/checksum only)"
  exit 0
fi

mkdir -p "$(dirname "$OUTPUT_DIR")"
tar --no-same-owner -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"
rm -rf "$OUTPUT_DIR"
mv "$EXTRACT_DIR/GhosttyKit.xcframework" "$OUTPUT_DIR"
test -d "$OUTPUT_DIR"

echo "Verified and extracted $OUTPUT_DIR"
