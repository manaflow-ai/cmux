#!/usr/bin/env bash
# Behavioral check for scripts/ci/fetch-previous-nightly-dmgs.py through a fake gh.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT_DIR/scripts/ci/fetch-previous-nightly-dmgs.py"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-fetch-previous.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >> "$CMUX_TEST_CALL_LOG"
case "$1 $2" in
  "release view")
    cat <<'JSON'
{"assets":[
 {"name":"cmux-nightly-macos-arm64-300.dmg"},
 {"name":"cmux-nightly-macos-arm64-100.dmg"},
 {"name":"cmux-nightly-macos-x86_64-200.dmg"},
 {"name":"cmux-nightly-macos-arm64-200.dmg"},
 {"name":"cmux-nightly-macos-arm64-300-200.delta"},
 {"name":"cmux-nightly-macos-arm64.dmg"},
 {"name":"cmux-nightly-macos-arm64-50.dmg"}
]}
JSON
    ;;
  "release download")
    while [ $# -gt 0 ]; do case "$1" in --pattern) name="$2"; shift;; --dir) dir="$2"; shift;; esac; shift; done
    printf 'fixture' > "$dir/$name"
    ;;
esac
EOF
chmod +x "$TMP_DIR/bin/gh"
export CMUX_TEST_CALL_LOG="$TMP_DIR/calls.log"
fail() { echo "FAIL: $*" >&2; exit 1; }
PATH="$TMP_DIR/bin:$PATH" python3 "$TOOL" --repo o/r --release-tag nightly --variant arm64 --exclude-build 300 --count 2 --out "$TMP_DIR/prev" >/dev/null
[ -f "$TMP_DIR/prev/cmux-nightly-macos-arm64-200.dmg" ] || fail "newest previous arm64 build was not downloaded"
[ -f "$TMP_DIR/prev/cmux-nightly-macos-arm64-100.dmg" ] || fail "second previous arm64 build was not downloaded"
[ ! -f "$TMP_DIR/prev/cmux-nightly-macos-arm64-300.dmg" ] || fail "the current build was downloaded as a previous build"
[ ! -f "$TMP_DIR/prev/cmux-nightly-macos-arm64-50.dmg" ] || fail "more than --count builds were downloaded"
[ ! -f "$TMP_DIR/prev/cmux-nightly-macos-x86_64-200.dmg" ] || fail "another track's build was downloaded"
[ "$(grep -c '^gh release download' "$CMUX_TEST_CALL_LOG")" -eq 2 ] || fail "expected exactly two downloads"
# First publish of a track: nothing to fetch, still exit 0 with an empty dir.
: > "$CMUX_TEST_CALL_LOG"
PATH="$TMP_DIR/bin:$PATH" python3 "$TOOL" --repo o/r --release-tag nightly --variant universal --exclude-build 300 --count 2 --out "$TMP_DIR/none" >/dev/null || fail "no previous build must not fail the job"
[ -z "$(ls -A "$TMP_DIR/none")" ] || fail "unexpected download for a track with no history"
echo "PASS: previous nightly builds are fetched per track, newest first, excluding the current build"
