#!/usr/bin/env bash
# When GitHub refuses the GhosttyKit release download (2026-11-26: 403 for an hour, four
# nightlies failed after 31 tries each), download-prebuilt-ghosttykit.sh takes the same
# pinned bytes from our CI cache bucket after the first refusal instead of retrying GitHub,
# and a bucket copy that fails the checksum is never used.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/download-prebuilt-ghosttykit.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SHA="7dd589824d4c9bda8265355718800cccaf7189a0"
mkdir -p "$WORK/fixture/GhosttyKit.xcframework" "$WORK/bin"
printf 'fixture\n' > "$WORK/fixture/GhosttyKit.xcframework/marker.txt"
(cd "$WORK/fixture" && COPYFILE_DISABLE=1 tar czf "$WORK/GhosttyKit.xcframework.tar.gz" GhosttyKit.xcframework)
ARCHIVE_SHA256="$(shasum -a 256 "$WORK/GhosttyKit.xcframework.tar.gz" | awk '{print $1}')"
printf '%s %s\n' "$SHA" "$ARCHIVE_SHA256" > "$WORK/checksums.txt"
printf 'import sys\nsys.exit(0)\n' > "$WORK/validator.py"
printf 'corrupt' > "$WORK/bad.tar.gz"

# GitHub (any github.com URL) answers 403; the bucket URL serves TEST_BUCKET_FILE.
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
output="" url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
echo "$url" >> "${TEST_CURL_LOG:?}"
case "$url" in
  *ci-cache.test/v1/any/objects/ghosttykit-*.tar.gz)
    [ -n "${TEST_BUCKET_FILE:-}" ] || { echo "curl: (22) 404" >&2; exit 22; }
    cp "$TEST_BUCKET_FILE" "$output" ;;
  *) echo "curl: (22) The requested URL returned error: 403" >&2; exit 22 ;;
esac
EOF
chmod +x "$WORK/bin/curl"

run_download() {
  local out_dir="$1" bucket="$2"
  rm -f "$WORK/curl.log"
  (
    cd "$WORK"
    PATH="$WORK/bin:$PATH" \
    TEST_CURL_LOG="$WORK/curl.log" \
    TEST_BUCKET_FILE="$bucket" \
    GHOSTTY_SHA="$SHA" \
    GHOSTTYKIT_CHECKSUMS_FILE="$WORK/checksums.txt" \
    GHOSTTYKIT_ARCHIVE_VALIDATOR="$WORK/validator.py" \
    GHOSTTYKIT_OUTPUT_DIR="$out_dir" \
    GHOSTTYKIT_ARCHIVE_CACHE_DIR= \
    GHOSTTYKIT_DOWNLOAD_RETRIES=3 \
    GHOSTTYKIT_DOWNLOAD_RETRY_DELAY=0 \
    CI_CACHE_R2_PUBLIC_URL=https://ci-cache.test \
    CMUX_LAN_CACHE_SOCKET="$WORK/no-socket" \
      "$SCRIPT"
  ) > "$WORK/out.log" 2>&1
}

# 1. GitHub 403 -> the bucket's verified copy is used after one GitHub try.
run_download "$WORK/out1/GhosttyKit.xcframework" "$WORK/GhosttyKit.xcframework.tar.gz" || {
  echo "FAIL: a GitHub 403 with the archive in the bucket must succeed"; cat "$WORK/out.log"; exit 1; }
[ -f "$WORK/out1/GhosttyKit.xcframework/marker.txt" ] || { echo "FAIL: bucket copy was not extracted"; exit 1; }
grep -Fq "from the CI cache bucket" "$WORK/out.log" || { echo "FAIL: must say it used the bucket"; cat "$WORK/out.log"; exit 1; }
gh_calls="$(grep -c 'github.com' "$WORK/curl.log" || true)"
[ "$gh_calls" = 1 ] || { echo "FAIL: expected 1 GitHub try before the bucket, saw $gh_calls"; cat "$WORK/curl.log"; exit 1; }

# 2. A bucket copy that fails the checksum is never used; the run fails after GitHub's retries.
if run_download "$WORK/out2/GhosttyKit.xcframework" "$WORK/bad.tar.gz"; then
  echo "FAIL: a corrupt bucket copy must not be accepted"; cat "$WORK/out.log"; exit 1
fi
[ ! -e "$WORK/out2/GhosttyKit.xcframework" ] || { echo "FAIL: corrupt copy was extracted"; exit 1; }

# 3. GHOSTTYKIT_R2_FALLBACK=0 never asks the bucket.
rm -f "$WORK/curl.log"
if (cd "$WORK"; PATH="$WORK/bin:$PATH" TEST_CURL_LOG="$WORK/curl.log" TEST_BUCKET_FILE="$WORK/GhosttyKit.xcframework.tar.gz" \
    GHOSTTY_SHA="$SHA" GHOSTTYKIT_CHECKSUMS_FILE="$WORK/checksums.txt" GHOSTTYKIT_ARCHIVE_VALIDATOR="$WORK/validator.py" \
    GHOSTTYKIT_OUTPUT_DIR="$WORK/out3/G.xcframework" GHOSTTYKIT_ARCHIVE_CACHE_DIR= GHOSTTYKIT_DOWNLOAD_RETRIES=1 \
    GHOSTTYKIT_DOWNLOAD_RETRY_DELAY=0 GHOSTTYKIT_R2_FALLBACK=0 CI_CACHE_R2_PUBLIC_URL=https://ci-cache.test \
    CMUX_LAN_CACHE_SOCKET="$WORK/no-socket" "$SCRIPT") > "$WORK/out.log" 2>&1; then
  echo "FAIL: with the fallback off, a 403 must fail"; exit 1
fi
! grep -q 'ci-cache.test' "$WORK/curl.log" || { echo "FAIL: fallback off still asked the bucket"; exit 1; }

echo "PASS: GhosttyKit download falls back to the CI cache bucket on a GitHub refusal"
