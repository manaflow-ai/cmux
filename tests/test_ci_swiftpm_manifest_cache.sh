#!/usr/bin/env bash
# Pins scripts/ci/swiftpm-manifest-cache.sh. SwiftPM keys each cached manifest
# on the process environment, so a resolve that leaks per-run variables never
# hits the cache it restored; and the key must follow the manifests it covers.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/ci/swiftpm-manifest-cache.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/home"
cat > "$TMP_DIR/bin/xcodebuild" <<'STUB'
#!/bin/sh
echo "Xcode ${STUB_XCODE_VERSION:-26.3}"
STUB
cat > "$TMP_DIR/bin/print-env" <<'STUB'
#!/bin/sh
env | sort
STUB
chmod +x "$TMP_DIR/bin/xcodebuild" "$TMP_DIR/bin/print-env"

run_env() {
  env HOME="$TMP_DIR/home" PATH="$TMP_DIR/bin:$PATH" DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    GITHUB_RUN_ID="$1" GITHUB_OUTPUT="/tmp/step-$1" "$SCRIPT" run print-env
}
first="$(run_env 1)"
second="$(run_env 2)"
if [ "$first" != "$second" ] || grep -q '^GITHUB_' <<<"$first"; then
  echo "FAIL: run must drop per-run variables so the manifest cache key is stable"
  exit 1
fi
if ! grep -Fxq 'PATH=/usr/bin:/bin:/usr/sbin:/sbin' <<<"$first" \
  || ! grep -Fxq 'DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer' <<<"$first"; then
  echo "FAIL: run must fix PATH and keep the selected Xcode"
  exit 1
fi
echo "PASS: run gives every job the same environment and finds the command on the caller's PATH"

mkdir -p "$TMP_DIR/repo/Packages/A"
git -C "$TMP_DIR/repo" init -q
printf '// swift-tools-version:5.9\n' > "$TMP_DIR/repo/Packages/A/Package.swift"
git -C "$TMP_DIR/repo" add -A
key_of() { (cd "$TMP_DIR/repo" && PATH="$TMP_DIR/bin:$PATH" "$SCRIPT" key); }
base="$(key_of)"
again="$(key_of)"
printf '// changed\n' >> "$TMP_DIR/repo/Packages/A/Package.swift"
git -C "$TMP_DIR/repo" add -A
changed="$(key_of)"
other_xcode="$(STUB_XCODE_VERSION=26.5 key_of)"
prefix_of() { sed -n 's/^prefix=//p' <<<"$1"; }
full_of() { sed -n 's/^key=//p' <<<"$1"; }
if [ "$base" != "$again" ] \
  || [ "$(full_of "$base")" = "$(full_of "$changed")" ] \
  || [ "$(prefix_of "$base")" != "$(prefix_of "$changed")" ] \
  || [ "$(prefix_of "$base")" = "$(prefix_of "$other_xcode")" ] \
  || [[ "$(full_of "$base")" != "$(prefix_of "$base")"* ]]; then
  echo "FAIL: the key must follow Package.swift contents and the prefix must follow only the toolchain"
  exit 1
fi
echo "PASS: the key follows the manifests and the prefix follows the toolchain"

if command -v sqlite3 >/dev/null; then
  cache="$TMP_DIR/home/Library/Caches/org.swift.swiftpm/manifests"
  mkdir -p "$cache"
  sqlite3 "$cache/manifest.db" 'PRAGMA journal_mode=WAL; CREATE TABLE MANIFEST_CACHE (key TEXT PRIMARY KEY, value BLOB); INSERT INTO MANIFEST_CACHE VALUES ("a", "x");' >/dev/null
  HOME="$TMP_DIR/home" "$SCRIPT" stage "$TMP_DIR/staged" >/dev/null
  rm -rf "$cache"
  HOME="$TMP_DIR/home" "$SCRIPT" install "$TMP_DIR/staged" >/dev/null
  if [ "$(sqlite3 "$cache/manifest.db" 'select count(*) from MANIFEST_CACHE')" != 1 ] \
    || [ "$(ls "$TMP_DIR/staged")" != manifest.db ]; then
    echo "FAIL: stage and install must round-trip the manifest cache as one database file"
    exit 1
  fi
  HOME="$TMP_DIR/home" "$SCRIPT" install "$TMP_DIR/missing" >/dev/null
  echo "PASS: stage and install round-trip the manifest cache; a missing restore is not an error"
else
  echo "SKIP: sqlite3 not installed; stage/install not exercised"
fi
