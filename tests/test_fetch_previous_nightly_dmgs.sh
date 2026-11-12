#!/usr/bin/env bash
# Behavioral check for scripts/ci/fetch-previous-nightly-dmgs.py through a fake gh.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT_DIR/scripts/ci/fetch-previous-nightly-dmgs.py"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-fetch-previous.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"

# Each asset's bytes are "fixture-<id>". The listing carries the digest of those
# bytes, except asset 9, whose listed digest does not match what it serves.
digest() { printf 'sha256:%s' "$(printf 'fixture-%s' "$1" | shasum -a 256 | cut -d' ' -f1)"; }
asset() { # id name
  printf ' {"id":%s,"name":"%s","state":"uploaded","apiUrl":"https://api.example.invalid/assets/%s","digest":"%s"}' \
    "$1" "$2" "$1" "$(digest "$1")"
}
{
  printf '{"assets":[\n'
  asset 1 cmux-nightly-macos-arm64-300.dmg; printf ',\n'
  asset 2 cmux-nightly-macos-arm64-100.dmg; printf ',\n'
  asset 3 cmux-nightly-macos-x86_64-200.dmg; printf ',\n'
  asset 4 cmux-nightly-macos-arm64-200.dmg; printf ',\n'
  asset 5 cmux-nightly-macos-arm64-300-200.delta; printf ',\n'
  asset 6 cmux-nightly-macos-arm64.dmg; printf ',\n'
  asset 7 cmux-nightly-macos-arm64-50.dmg; printf ',\n'
  asset 8 cmux-rc-macos-arm64-400.dmg; printf ',\n'
  asset 10 cmux-rc-macos-arm64-410.dmg; printf ',\n'
  printf ' {"id":9,"name":"cmux-nightly-macos-universal-250.dmg","state":"uploaded","apiUrl":"https://api.example.invalid/assets/9","digest":"sha256:%064d"},\n' 0
  printf ' {"id":11,"name":"cmux-nightly-macos-universal-240.dmg","state":"uploaded","apiUrl":"https://api.example.invalid/assets/11","digest":"%s"},\n' "$(digest 11)"
  printf ' {"id":12,"name":"cmux-nightly-macos-universal-230.dmg","state":"uploaded","apiUrl":"https://api.example.invalid/assets/12","digest":"%s"},\n' "$(digest 12)"
  printf ' {"id":13,"name":"cmux-nightly-macos-universal-220.dmg","state":"starter","apiUrl":"https://api.example.invalid/assets/13","digest":"%s"}\n' "$(digest 13)"
  printf ']}\n'
} > "$TMP_DIR/release.json"

cat > "$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >> "$CMUX_TEST_CALL_LOG"
case "$1 $2" in
  "release view")
    cat "$CMUX_TEST_RELEASE_JSON"
    ;;
  "release download")
    # Real gh resolves --pattern against the REST release object, whose embedded
    # asset list is incomplete on a release with ~1000 assets. Model the newest
    # assets being absent there even though the paginated listing has them.
    echo "no assets match the file pattern" >&2
    exit 1
    ;;
  "api "*)
    url="${*: -1}"
    id="${url##*/}"
    if [ "$id" = "12" ]; then
      echo "HTTP 502: Bad Gateway" >&2
      exit 1
    fi
    printf 'fixture-%s' "$id"
    ;;
  *)
    echo "unexpected gh call: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$TMP_DIR/bin/gh"
export CMUX_TEST_CALL_LOG="$TMP_DIR/calls.log"
export CMUX_TEST_RELEASE_JSON="$TMP_DIR/release.json"
fail() { echo "FAIL: $*" >&2; exit 1; }
run_tool() { PATH="$TMP_DIR/bin:$PATH" python3 "$TOOL" --repo o/r "$@"; }

: > "$CMUX_TEST_CALL_LOG"
run_tool --release-tag nightly --variant arm64 --exclude-build 300 --count 2 --out "$TMP_DIR/prev" >/dev/null
[ -f "$TMP_DIR/prev/cmux-nightly-macos-arm64-200.dmg" ] || fail "newest previous arm64 build was not downloaded"
[ -f "$TMP_DIR/prev/cmux-nightly-macos-arm64-100.dmg" ] || fail "second previous arm64 build was not downloaded"
[ "$(cat "$TMP_DIR/prev/cmux-nightly-macos-arm64-200.dmg")" = "fixture-4" ] || fail "downloaded bytes are not the listed asset's"
[ ! -f "$TMP_DIR/prev/cmux-nightly-macos-arm64-300.dmg" ] || fail "the current build was downloaded as a previous build"
[ ! -f "$TMP_DIR/prev/cmux-nightly-macos-arm64-50.dmg" ] || fail "more than --count builds were downloaded"
[ ! -f "$TMP_DIR/prev/cmux-nightly-macos-x86_64-200.dmg" ] || fail "another track's build was downloaded"
[ "$(grep -c '^gh api' "$CMUX_TEST_CALL_LOG")" -eq 2 ] || fail "expected exactly two downloads"
! grep -q '^gh release download' "$CMUX_TEST_CALL_LOG" || fail "downloads must use the listed asset id, not a second name lookup"

# First publish of a track: nothing to fetch, still exit 0 with an empty dir.
: > "$CMUX_TEST_CALL_LOG"
run_tool --release-tag nightly --variant x86_64 --exclude-build 200 --count 2 --out "$TMP_DIR/none" >/dev/null || fail "no previous build must not fail the job"
[ -z "$(ls -A "$TMP_DIR/none")" ] || fail "unexpected download for a track with no history"

# Deltas are optional. A digest mismatch or a failed download skips that build
# instead of failing the publish, and never leaves a partial or unverified DMG.
: > "$CMUX_TEST_CALL_LOG"
run_tool --release-tag nightly --variant universal --exclude-build 300 --count 3 --out "$TMP_DIR/universal" >/dev/null 2>"$TMP_DIR/universal.err" \
  || fail "an unusable previous build must not fail the job"
[ ! -e "$TMP_DIR/universal/cmux-nightly-macos-universal-250.dmg" ] || fail "a DMG with a mismatched digest was kept"
[ -f "$TMP_DIR/universal/cmux-nightly-macos-universal-240.dmg" ] || fail "a valid previous universal build was skipped"
[ ! -e "$TMP_DIR/universal/cmux-nightly-macos-universal-230.dmg" ] || fail "a failed download left a file behind"
[ ! -e "$TMP_DIR/universal/cmux-nightly-macos-universal-220.dmg" ] || fail "an incomplete upload was downloaded"
[ -z "$(ls -A "$TMP_DIR/universal" | grep -v '\.dmg$' || true)" ] || fail "temporary download files were left behind"
grep -q 'digest' "$TMP_DIR/universal.err" || fail "the digest mismatch was not reported"

# The RC channel names its immutable DMGs cmux-rc-macos-<variant>-<build>.dmg and
# must never pick up nightly assets that share the release listing shape.
: > "$CMUX_TEST_CALL_LOG"
run_tool --release-tag rc --name-prefix cmux-rc-macos- --variant arm64 --exclude-build 410 --count 2 --out "$TMP_DIR/rc" >/dev/null
[ -f "$TMP_DIR/rc/cmux-rc-macos-arm64-400.dmg" ] || fail "previous rc build was not downloaded"
[ ! -f "$TMP_DIR/rc/cmux-rc-macos-arm64-410.dmg" ] || fail "the current rc build was downloaded as a previous build"
[ -z "$(ls "$TMP_DIR/rc" | grep nightly || true)" ] || fail "nightly assets leaked into the rc track"
[ "$(grep -c '^gh api' "$CMUX_TEST_CALL_LOG")" -eq 1 ] || fail "expected exactly one rc download"
echo "PASS: previous nightly builds are fetched per track by asset id, verified, newest first, and optional"
