#!/usr/bin/env bash
# GHOSTTYKIT_ARCHIVE_CACHE_DIR lets a persistent Mac reuse the pinned GhosttyKit
# archive instead of downloading it for every job. The cache must stay behind
# the pinned checksum: a hit skips curl, a damaged entry is dropped and
# downloaded again, --verify-only never touches it, and old revisions are
# pruned.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/download-prebuilt-ghosttykit.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/ci-macos.yml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SHA="7dd589824d4c9bda8265355718800cccaf7189a0"
mkdir -p "$WORK/fixture/GhosttyKit.xcframework" "$WORK/bin" "$WORK/cache"
printf 'fixture\n' > "$WORK/fixture/GhosttyKit.xcframework/marker.txt"
(cd "$WORK/fixture" && COPYFILE_DISABLE=1 tar czf "$WORK/GhosttyKit.xcframework.tar.gz" GhosttyKit.xcframework)
ARCHIVE_SHA256="$(shasum -a 256 "$WORK/GhosttyKit.xcframework.tar.gz" | awk '{print $1}')"
printf '%s %s\n' "$SHA" "$ARCHIVE_SHA256" > "$WORK/checksums.txt"
printf 'import sys\nsys.exit(0)\n' > "$WORK/validator.py"

cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
echo call >> "${TEST_CURL_LOG:?}"
cp "${TEST_FIXTURE_ARCHIVE:?}" "$output"
EOF
chmod +x "$WORK/bin/curl"

run_download() {
  local out_dir="$1"
  shift
  (
    cd "$WORK"
    PATH="$WORK/bin:$PATH" \
    TEST_CURL_LOG="$WORK/curl.log" \
    TEST_FIXTURE_ARCHIVE="$WORK/GhosttyKit.xcframework.tar.gz" \
    GHOSTTY_SHA="$SHA" \
    GHOSTTYKIT_CHECKSUMS_FILE="$WORK/checksums.txt" \
    GHOSTTYKIT_ARCHIVE_VALIDATOR="$WORK/validator.py" \
    GHOSTTYKIT_OUTPUT_DIR="$out_dir" \
    GHOSTTYKIT_DOWNLOAD_RETRY_DELAY=0 \
      "$SCRIPT" "$@"
  ) > "$WORK/out.log" 2>&1 || {
    echo "FAIL: download-prebuilt-ghosttykit.sh $* exited nonzero"
    cat "$WORK/out.log"
    exit 1
  }
}

curl_calls() {
  if [ -f "$WORK/curl.log" ]; then wc -l < "$WORK/curl.log" | tr -d ' '; else echo 0; fi
}

export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$WORK/cache"
CACHED="$WORK/cache/$ARCHIVE_SHA256.tar.gz"

# 1. A cold cache downloads once and keeps the verified archive.
run_download "$WORK/out1/GhosttyKit.xcframework"
[ "$(curl_calls)" = 1 ] || { echo "FAIL: cold cache must download once"; exit 1; }
[ -f "$CACHED" ] || { echo "FAIL: verified archive was not kept at $CACHED"; ls -la "$WORK/cache"; exit 1; }
[ -f "$WORK/out1/GhosttyKit.xcframework/marker.txt" ] || { echo "FAIL: cold run did not extract"; exit 1; }

# 2. A warm cache extracts without calling curl.
run_download "$WORK/out2/GhosttyKit.xcframework"
[ "$(curl_calls)" = 1 ] || { echo "FAIL: a cache hit must not download"; cat "$WORK/out.log"; exit 1; }
grep -Fq "Using cached" "$WORK/out.log" || { echo "FAIL: a cache hit must say so"; exit 1; }
[ -f "$WORK/out2/GhosttyKit.xcframework/marker.txt" ] || { echo "FAIL: cache hit did not extract"; exit 1; }

# 3. A damaged entry is discarded and downloaded again, then re-kept intact.
printf 'corrupt' > "$CACHED"
run_download "$WORK/out3/GhosttyKit.xcframework"
[ "$(curl_calls)" = 2 ] || { echo "FAIL: a damaged cache entry must be downloaded again"; exit 1; }
[ "$(shasum -a 256 "$CACHED" | awk '{print $1}')" = "$ARCHIVE_SHA256" ] || { echo "FAIL: the re-downloaded archive was not re-kept"; exit 1; }
[ -f "$WORK/out3/GhosttyKit.xcframework/marker.txt" ] || { echo "FAIL: damaged-entry run did not extract"; exit 1; }

# 4. --verify-only checks the release itself: it downloads and never reads the cache.
run_download "$WORK/out4/GhosttyKit.xcframework" --verify-only
[ "$(curl_calls)" = 3 ] || { echo "FAIL: --verify-only must download, not use the cache"; exit 1; }

# 5. Old revisions are pruned down to GHOSTTYKIT_ARCHIVE_CACHE_KEEP entries.
for i in 1 2 3 4 5; do
  printf 'old %s' "$i" > "$WORK/cache/old$i.tar.gz"
  touch -t "20200101000$i" "$WORK/cache/old$i.tar.gz"
done
rm -f "$CACHED"
GHOSTTYKIT_ARCHIVE_CACHE_KEEP=2 run_download "$WORK/out5/GhosttyKit.xcframework"
kept="$(ls "$WORK/cache"/*.tar.gz | wc -l | tr -d ' ')"
[ "$kept" = 2 ] || { echo "FAIL: expected 2 kept archives, found $kept"; ls -la "$WORK/cache"; exit 1; }
[ -f "$CACHED" ] || { echo "FAIL: pruning dropped the archive just kept"; exit 1; }
[ -f "$WORK/cache/old5.tar.gz" ] || { echo "FAIL: pruning must keep the newest entries"; exit 1; }

# 6. An unwritable cache directory never fails the download.
rm -rf "$WORK/cache"
printf 'not a directory' > "$WORK/cache"
run_download "$WORK/out6/GhosttyKit.xcframework"
[ -f "$WORK/out6/GhosttyKit.xcframework/marker.txt" ] || { echo "FAIL: an unusable cache dir must not block extraction"; exit 1; }

# 7. Compile admission on an owned Mac passes the shared cache directory.
step="$(awk '/^  macos-compile-admission:/{job=1} job && /^  [a-z0-9-]+:$/ && !/macos-compile-admission/{job=0}
  job && /- name: Download pre-built GhosttyKit.xcframework/{grab=1; next}
  grab && /- name:/{grab=0} grab' "$WORKFLOW")"
printf '%s\n' "$step" | grep -Fq "GHOSTTYKIT_ARCHIVE_CACHE_DIR: \${{ startsWith(env.CMUX_PRODUCT_RUNNER, 'glaeda-') && '/Users/Shared/cmux-build-fleet/ci/ghosttykit-archives' || '' }}" || {
  echo "FAIL: compile admission must pass the owned Mac's GhosttyKit archive cache"
  printf '%s\n' "$step"
  exit 1
}

echo "PASS: GhosttyKit archive cache reuses verified archives and stays behind the pinned checksum"
