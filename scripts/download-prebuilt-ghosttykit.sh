#!/usr/bin/env bash
set -euo pipefail

VERIFY_ONLY=0
PRINT_RELEASE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --verify-only)
      VERIFY_ONLY=1
      ;;
    --print-release)
      PRINT_RELEASE=1
      ;;
    -h|--help)
      cat <<'EOF'
Usage: download-prebuilt-ghosttykit.sh [--verify-only | --print-release]

Download, verify, and extract the pre-built GhosttyKit.xcframework. The
--verify-only mode performs the same release URL, checksum, and archive checks
without extracting the framework; CI uses it to validate release provenance
independently of build caches. --print-release prints the release tag and
archive name for GHOSTTY_SHA (or the submodule) and exits, without reading the
checksums (scripts/cmux-next/ghosttykit-checksum.sh pins them from it).

GHOSTTYKIT_VERIFY_BY_DIGEST=1 makes --verify-only accept the release asset's
published sha256 digest when it equals the pin, without downloading.

GHOSTTYKIT_ARCHIVE_CACHE_DIR, when set, keeps each verified archive there under
its pinned sha256 and reuses it instead of downloading again. Unset, it defaults
to /Users/Shared/cmux-build-fleet/ci/ghosttykit-archives when that directory
exists (a fleet mini); set it empty to turn the cache off. --verify-only never
reads or writes it.

When GitHub refuses the release download (403, 404, 429), the script asks our
own cache bucket for the same pinned bytes before retrying GitHub:
$CI_CACHE_R2_PUBLIC_URL/v1/any/objects/ghosttykit-<sha256>.tar.gz (default
https://ci-cache.cmux.com; GHOSTTYKIT_R2_FALLBACK=0 turns it off). A download
from GitHub with GHOSTTYKIT_R2_ACCESS_KEY_ID, GHOSTTYKIT_R2_SECRET_ACCESS_KEY,
GHOSTTYKIT_R2_ENDPOINT and GHOSTTYKIT_R2_BUCKET set stores the archive there.
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
if [ "$PRINT_RELEASE" = 1 ]; then
  echo "$TAG $ARCHIVE_NAME"
  exit 0
fi
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
# Every nightly job on a mini shares the one fleet cache, not only the steps that name it:
# build-nightly-app's install step named none, so it went to GitHub for every run.
FLEET_ARCHIVE_CACHE_DIR=/Users/Shared/cmux-build-fleet/ci/ghosttykit-archives
if [ "$VERIFY_ONLY" -eq 0 ]; then
  if [ -n "${GHOSTTYKIT_ARCHIVE_CACHE_DIR+set}" ]; then
    ARCHIVE_CACHE_DIR="$GHOSTTYKIT_ARCHIVE_CACHE_DIR"
  elif [ -d "$FLEET_ARCHIVE_CACHE_DIR" ]; then
    ARCHIVE_CACHE_DIR="$FLEET_ARCHIVE_CACHE_DIR"
  fi
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

# A release download that keeps failing goes once through the release-assets API, which serves the same file
# another way (2026-11-08: every release download answered 504 for hours while the API served the same bytes).
# The checksum below judges what it gets.
fetch_via_release_api() {
  [[ "$DOWNLOAD_URL" =~ ^https://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/([^/]+)$ ]] || return 1
  local api="https://api.github.com/repos/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}" name="${BASH_REMATCH[4]}" asset_url
  echo "Fetching $ARCHIVE_NAME through the release-assets API" >&2
  asset_url="$(curl --fail --silent --show-error --location --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" \
    --max-time "$DOWNLOAD_MAX_TIME" \
    -H 'Accept: application/vnd.github+json' "$api/releases/tags/${BASH_REMATCH[3]}" \
    | python3 -c 'import json, sys; print(next(a["url"] for a in json.load(sys.stdin)["assets"] if a["name"] == sys.argv[1]))' "$name")" \
    || return 1
  rm -f "$ARCHIVE_PATH"
  curl --fail --show-error --location --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" --max-time "$DOWNLOAD_MAX_TIME" \
    -H 'Accept: application/octet-stream' -o "$ARCHIVE_PATH" "$asset_url"
}

# Our own copy of the pinned archive, keyed by its sha256, in the CI cache bucket. 2026-11-26:
# GitHub answered 403 to every release download from the fleet's site for an hour (Nightly
# macOS build runs 45734242541 through 45738487881 failed after 31 tries each), and retrying
# GitHub for ten minutes only adds to what it is refusing. The checksum judges what comes back.
R2_FALLBACK="${GHOSTTYKIT_R2_FALLBACK:-1}"
R2_PUBLIC_URL="${CI_CACHE_R2_PUBLIC_URL:-https://ci-cache.cmux.com}"
R2_OBJECT="v1/any/objects/ghosttykit-$EXPECTED_SHA256.tar.gz"
FROM_R2=0
fetch_from_r2() {
  [ "$R2_FALLBACK" = 1 ] && [ -n "$R2_PUBLIC_URL" ] || return 1
  rm -f "$ARCHIVE_PATH"
  local lan="$SCRIPT_DIR/ci/lan_cache_fetch.py" status=1
  if [ -f "$lan" ]; then
    python3 "$lan" "$R2_PUBLIC_URL" "$R2_OBJECT" "$ARCHIVE_PATH" 2>/dev/null && status=0 || status=$?
  fi
  # 3: the bucket has no such object, so the direct download would miss too.
  if [ "$status" -ne 0 ] && [ "$status" -ne 3 ]; then
    curl --fail --silent --show-error --location --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" \
      --max-time "$DOWNLOAD_MAX_TIME" -o "$ARCHIVE_PATH" "${R2_PUBLIC_URL%/}/$R2_OBJECT" 2>/dev/null && status=0 || status=1
  fi
  if [ "$status" -eq 0 ] && archive_matches_checksum; then
    FROM_R2=1
    echo "Using $ARCHIVE_NAME for ghostty $GHOSTTY_SHA from the CI cache bucket (${R2_PUBLIC_URL%/}/$R2_OBJECT)"
    return 0
  fi
  rm -f "$ARCHIVE_PATH"
  echo "The CI cache bucket has no usable $R2_OBJECT" >&2
  return 1
}

# A verified archive that came from GitHub goes to the bucket, so the next refusal finds it.
store_archive_in_r2() {
  [ -n "${GHOSTTYKIT_R2_ACCESS_KEY_ID:-}" ] && [ -n "${GHOSTTYKIT_R2_SECRET_ACCESS_KEY:-}" ] &&
    [ -n "${GHOSTTYKIT_R2_ENDPOINT:-}" ] && [ -n "${GHOSTTYKIT_R2_BUCKET:-}" ] || return 0
  local url="${GHOSTTYKIT_R2_ENDPOINT%/}/$GHOSTTYKIT_R2_BUCKET/$R2_OBJECT" code
  # If-None-Match: * never replaces an object another job stored first (412).
  code="$(printf 'user = "%s:%s"\n' "$GHOSTTYKIT_R2_ACCESS_KEY_ID" "$GHOSTTYKIT_R2_SECRET_ACCESS_KEY" \
    | curl --config - --silent --show-error --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 600 \
        --aws-sigv4 "aws:amz:auto:s3" -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" \
        -H 'If-None-Match: *' -H 'content-type: application/gzip' \
        -o /dev/null -w '%{http_code}' -T "$ARCHIVE_PATH" "$url")" || code=000
  case "$code" in
    200) echo "Stored $ARCHIVE_NAME in the CI cache bucket as $R2_OBJECT" ;;
    412) echo "The CI cache bucket already holds $R2_OBJECT" ;;
    *) echo "::warning::could not store $ARCHIVE_NAME in the CI cache bucket (HTTP $code)" >&2 ;;
  esac
  return 0
}

# --verify-only with GHOSTTYKIT_VERIFY_BY_DIGEST=1 asks the release-assets API for the asset's
# sha256 (GitHub computes it at upload) and stops when it equals the pin: the published bytes are
# the pinned bytes, without downloading 123 MB. On 2026-11-23 a runner holding about 100 KB/s
# spent 17 min on that download and failed (job 137831575500). Any other answer (no digest, a
# different one, an API error) falls through to the download and full check below; a PR that
# changes the pin, which runs no Mac job to unpack it, leaves the variable unset.
if [ "$VERIFY_ONLY" -eq 1 ] && [ "${GHOSTTYKIT_VERIFY_BY_DIGEST:-0}" = 1 ] &&
   [[ "$DOWNLOAD_URL" =~ ^https://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/([^/]+)$ ]]; then
  digest_auth=()
  [ -n "${GITHUB_TOKEN:-}" ] && digest_auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  published_digest="$(curl --fail --silent --show-error --location --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" \
    --max-time 60 "${digest_auth[@]}" -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}/releases/tags/${BASH_REMATCH[3]}" \
    | python3 -c 'import json, sys; print(next((a.get("digest") or "" for a in json.load(sys.stdin)["assets"] if a["name"] == sys.argv[1]), ""))' "${BASH_REMATCH[4]}" \
    2>/dev/null || true)"
  if [ "$published_digest" = "sha256:$EXPECTED_SHA256" ]; then
    echo "Verified $ARCHIVE_NAME for ghostty $GHOSTTY_SHA (release asset digest equals the pinned sha256)"
    exit 0
  fi
  echo "Release asset digest '${published_digest:-none}' is not sha256:$EXPECTED_SHA256; downloading to check" >&2
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
    # 22: an HTTP error (curl --fail). The first one asks our bucket once before GitHub again.
    if [ "$status" -eq 22 ] && [ "$FROM_R2" -eq 0 ] && [ "${R2_TRIED:-0}" -eq 0 ]; then
      R2_TRIED=1
      if fetch_from_r2; then
        status=0
        break
      fi
    fi
    if [ "$attempt" -gt "$DOWNLOAD_RETRIES" ]; then
      break
    fi
    # 33: the server refused the byte range, so the partial file cannot be resumed.
    if [ "$status" -eq 33 ]; then
      rm -f "$ARCHIVE_PATH"
    fi
    echo "Download attempt $attempt failed (curl exit $status); retrying in ${DOWNLOAD_RETRY_DELAY}s" >&2
    sleep "$DOWNLOAD_RETRY_DELAY"
  done
  # The API fallback runs once, after the retries, never inside the sleeping loop:
  # the loop must not call the GitHub API (tests/test_ci_no_github_token_polling.py).
  if [ "$status" -ne 0 ] && ! archive_matches_checksum; then
    if ! { fetch_via_release_api && archive_matches_checksum; } && ! fetch_from_r2; then
      echo "Failed to download $ARCHIVE_NAME after $attempt attempts (curl exit $status)" >&2
      exit 1
    fi
  fi
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
if [ "$FROM_CACHE" -eq 0 ] && [ "$FROM_R2" -eq 0 ]; then
  store_archive_in_r2 || true
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
