#!/usr/bin/env bash
# cmux-next must never turn a missing pinned daemon into a successful build by
# selecting an unrelated release client from the local cache.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-next-bundle-pin.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

FAKE_REPO="$TEST_DIR/repo"
FAKE_BUILD="$TEST_DIR/build"
FAKE_CACHE="$TEST_DIR/cache"
PIN_COMMIT="1111111111111111111111111111111111111111"

mkdir -p "$FAKE_REPO/scripts/cmux-next" \
         "$FAKE_CACHE/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
         "$FAKE_BUILD"
cp "$ROOT_DIR/scripts/cmux-next/bundle-cmux-tui.sh" "$FAKE_REPO/scripts/cmux-next/"
cat > "$FAKE_REPO/scripts/cmux-next/cmux-tui.pin" <<PIN
commit=$PIN_COMMIT
url=https://files.cmux.com/cmux-tui/$PIN_COMMIT/cmux-tui-aarch64-apple-darwin
run=1
sha256=2222222222222222222222222222222222222222222222222222222222222222
PIN

cat > "$FAKE_CACHE/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/cmux-tui-aarch64-apple-darwin" <<'CLIENT'
#!/bin/sh
printf '%s\n' 'cmux 0.1.0 (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; ghostty test)'
CLIENT
chmod +x "$FAKE_CACHE/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/cmux-tui-aarch64-apple-darwin"

LOG="$TEST_DIR/bundle.log"
if SRCROOT="$FAKE_REPO" \
   TARGET_BUILD_DIR="$FAKE_BUILD" \
   UNLOCALIZED_RESOURCES_FOLDER_PATH='cmux DEV.app/Contents/Resources' \
   NATIVE_ARCH_ACTUAL=arm64 \
   CMUX_TUI_CLIENT_CACHE="$FAKE_CACHE" \
   bash "$FAKE_REPO/scripts/cmux-next/bundle-cmux-tui.sh" >"$LOG" 2>&1; then
  echo "FAIL: bundle accepted a release-cache client when the pinned client was absent" >&2
  cat "$LOG" >&2
  exit 1
fi

grep -Fq "pinned cmux-tui $PIN_COMMIT is not downloaded" "$LOG" || {
  echo "FAIL: bundle did not explain that the pinned cmux-tui was missing" >&2
  cat "$LOG" >&2
  exit 1
}

if [[ -e "$FAKE_BUILD/cmux DEV.app/Contents/Resources/bin/cmux-tui" ]]; then
  echo "FAIL: bundle copied the stale release-cache client before failing" >&2
  exit 1
fi

echo "PASS: cmux-next bundle requires the pinned cmux-tui"
