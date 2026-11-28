#!/usr/bin/env bash
# Behavioral check for scripts/ci/finalize-sparkle-deltas.sh: generate_appcast's
# app-named deltas become track-specific release assets and the appcast follows.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT_DIR/scripts/ci/finalize-sparkle-deltas.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-finalize-deltas.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/archives" "$TMP_DIR/out"
printf 'delta-a' > "$TMP_DIR/archives/cmux NIGHTLY300-200.delta"
printf 'delta-b' > "$TMP_DIR/archives/cmux NIGHTLY300-100.delta"
printf 'dmg' > "$TMP_DIR/archives/cmux-nightly-macos-arm64-300.dmg"
cat > "$TMP_DIR/appcast.xml" <<'EOF'
<item>
  <enclosure url="https://example.com/nightly/cmux-nightly-macos-arm64-300.dmg" sparkle:version="300" length="3" type="application/octet-stream"/>
  <sparkle:deltas>
    <enclosure url="https://example.com/nightly/cmux%20NIGHTLY300-200.delta" sparkle:version="300" sparkle:deltaFrom="200" length="7" type="application/octet-stream"/>
    <enclosure url="https://example.com/nightly/cmux%20NIGHTLY300-100.delta" sparkle:version="300" sparkle:deltaFrom="100" length="7" type="application/octet-stream"/>
  </sparkle:deltas>
</item>
EOF
"$TOOL" "$TMP_DIR/appcast.xml" "$TMP_DIR/archives" "$TMP_DIR/out" "cmux-nightly-macos-arm64-" >/dev/null
fail() { echo "FAIL: $*" >&2; exit 1; }
[ -f "$TMP_DIR/out/cmux-nightly-macos-arm64-300-200.delta" ] || fail "delta 300-200 was not renamed into the output dir"
[ -f "$TMP_DIR/out/cmux-nightly-macos-arm64-300-100.delta" ] || fail "delta 300-100 was not renamed into the output dir"
[ "$(cat "$TMP_DIR/out/cmux-nightly-macos-arm64-300-200.delta")" = "delta-a" ] || fail "renamed delta content changed"
[ -z "$(ls "$TMP_DIR/archives"/*.delta 2>/dev/null)" ] || fail "app-named deltas remain in the archives dir"
grep -q 'url="https://example.com/nightly/cmux-nightly-macos-arm64-300-200.delta"' "$TMP_DIR/appcast.xml" || fail "appcast still points at the app-named delta"
grep -q 'url="https://example.com/nightly/cmux-nightly-macos-arm64-300-100.delta"' "$TMP_DIR/appcast.xml" || fail "second delta URL was not rewritten"
! grep -q 'cmux%20NIGHTLY' "$TMP_DIR/appcast.xml" || fail "percent-encoded app name survives in the appcast"
grep -q 'cmux-nightly-macos-arm64-300.dmg' "$TMP_DIR/appcast.xml" || fail "the full-archive enclosure was altered"
[ -f "$TMP_DIR/archives/cmux-nightly-macos-arm64-300.dmg" ] || fail "the DMG was moved"
# A delta the appcast never references is a generation bug, not something to ship silently.
printf 'orphan' > "$TMP_DIR/archives/cmux NIGHTLY300-50.delta"
if "$TOOL" "$TMP_DIR/appcast.xml" "$TMP_DIR/archives" "$TMP_DIR/out" "cmux-nightly-macos-arm64-" >/dev/null 2>&1; then
  fail "an unreferenced delta was accepted"
fi
echo "PASS: Sparkle deltas are renamed per track and the appcast follows"
