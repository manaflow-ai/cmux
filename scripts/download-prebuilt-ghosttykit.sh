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

GHOSTTYKIT_ARCHIVE_CACHE_DIR, when set, keeps each verified archive there under
its pinned sha256 and reuses it instead of downloading again. --verify-only
never reads or writes it.
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

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ghosttykit-download.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
ARCHIVE_BASENAME="$(basename "$ARCHIVE_NAME")"
ARCHIVE_PATH="$TMP_DIR/$ARCHIVE_BASENAME"
EXTRACT_DIR="$TMP_DIR/extract"
mkdir -p "$EXTRACT_DIR"

archive_matches_checksum() {
  [ -f "$ARCHIVE_PATH" ] && [ "$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')" = "$EXPECTED_SHA256" ]
}

# A persistent Mac (an owned CI mini) downloads the same pinned archive for
# every job: 27 s a compile admission on 2026-09-25, at about 6% CPU, while the
# job holds a build root. Keep the verified archive keyed by its pinned sha256
# and reuse it. The checksum and archive validation below still run on every
# use, so a damaged or swapped entry is dropped and downloaded again.
ARCHIVE_CACHE_DIR=""
if [ "$VERIFY_ONLY" -eq 0 ] && [ -n "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ]; then
  ARCHIVE_CACHE_DIR="$GHOSTTYKIT_ARCHIVE_CACHE_DIR"
fi
ARCHIVE_CACHE_KEEP="${GHOSTTYKIT_ARCHIVE_CACHE_KEEP:-4}"
CACHED_ARCHIVE=""
if [ -n "$ARCHIVE_CACHE_DIR" ]; then
  CACHED_ARCHIVE="$ARCHIVE_CACHE_DIR/$EXPECTED_SHA256.tar.gz"
fi

store_archive_in_cache() {
  [ -n "$CACHED_ARCHIVE" ] || return 0
  mkdir -p "$ARCHIVE_CACHE_DIR" 2>/dev/null || return 0
  local staged="$ARCHIVE_CACHE_DIR/.incoming.$$.$RANDOM"
  if cp "$ARCHIVE_PATH" "$staged" 2>/dev/null && mv -f "$staged" "$CACHED_ARCHIVE" 2>/dev/null; then
    echo "Kept $ARCHIVE_NAME in $ARCHIVE_CACHE_DIR"
  else
    rm -f "$staged" 2>/dev/null || true
    return 0
  fi
  # Newest first; drop all but the last few ghostty revisions. The other root
  # on this Mac may prune the same files at once, so a failed listing is fine.
  case "$ARCHIVE_CACHE_KEEP" in ''|*[!0-9]*) ARCHIVE_CACHE_KEEP=4 ;; esac
  { ls -t "$ARCHIVE_CACHE_DIR"/*.tar.gz 2>/dev/null || true; } | tail -n +"$((ARCHIVE_CACHE_KEEP + 1))" | while IFS= read -r stale; do
    rm -f "$stale" 2>/dev/null || true
  done
  # A job cancelled mid-copy leaves a staged file behind; clear old ones.
  find "$ARCHIVE_CACHE_DIR" -maxdepth 1 -name '.incoming.*' -mmin +60 -delete 2>/dev/null || true
  return 0
}

FROM_CACHE=0
if [ -n "$CACHED_ARCHIVE" ] && [ -f "$CACHED_ARCHIVE" ]; then
  if cp "$CACHED_ARCHIVE" "$ARCHIVE_PATH" 2>/dev/null && archive_matches_checksum; then
    FROM_CACHE=1
    touch "$CACHED_ARCHIVE" 2>/dev/null || true
    echo "Using cached $ARCHIVE_NAME for ghostty $GHOSTTY_SHA from $ARCHIVE_CACHE_DIR"
  else
    echo "Discarding cached $ARCHIVE_NAME that does not match the pinned checksum" >&2
    rm -f "$CACHED_ARCHIVE" "$ARCHIVE_PATH" 2>/dev/null || true
  fi
fi

# Each attempt is its own curl process so --continue-at resumes from the bytes
# already on disk; curl's built-in --retry starts the file over.
if [ "$FROM_CACHE" -eq 0 ]; then
  echo "Downloading $ARCHIVE_NAME for ghostty $GHOSTTY_SHA"
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
fi

ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
  echo "$ARCHIVE_NAME checksum mismatch" >&2
  echo "Expected: $EXPECTED_SHA256" >&2
  echo "Actual:   $ACTUAL_SHA256" >&2
  exit 1
fi

python3 "$ARCHIVE_VALIDATOR" "$ARCHIVE_PATH"

if [ "$FROM_CACHE" -eq 0 ]; then
  store_archive_in_cache || true
fi

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
