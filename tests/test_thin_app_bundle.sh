#!/usr/bin/env bash
# Behavioral check for scripts/thin-app-bundle.sh using real fat system binaries.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
THIN="$ROOT_DIR/scripts/thin-app-bundle.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-thin-bundle.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

fat_source="$TMP_DIR/fat-hello"
if command -v clang >/dev/null 2>&1; then
  printf '#include <stdio.h>\nint main(void){puts("hi");return 0;}\n' > "$TMP_DIR/hello.c"
  if ! clang -arch arm64 -arch x86_64 -o "$fat_source" "$TMP_DIR/hello.c" 2>/dev/null; then
    fat_source=""
  fi
else
  fat_source=""
fi
if [ -z "$fat_source" ]; then
  echo "SKIP: clang cannot produce a fat test binary on this machine"
  exit 0
fi

APP="$TMP_DIR/Sample.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" \
  "$APP/Contents/Library/Helper.app/Contents/MacOS" "$APP/Contents/Frameworks"
cp "$fat_source" "$APP/Contents/MacOS/Sample"
cp "$fat_source" "$APP/Contents/Resources/bin/helper"
cp "$fat_source" "$APP/Contents/Library/Helper.app/Contents/MacOS/helper"
lipo "$fat_source" -thin arm64 -output "$APP/Contents/Frameworks/libalready.dylib"
printf '#!/bin/sh\necho hi\n' > "$APP/Contents/Resources/bin/script"
chmod 755 "$APP/Contents/Resources/bin/script"
printf 'plain text\n' > "$APP/Contents/Resources/notes.txt"
ln -s helper "$APP/Contents/Resources/bin/helper-link"

"$THIN" "$APP" arm64

fail() { echo "FAIL: $*" >&2; exit 1; }
for bin in "$APP/Contents/MacOS/Sample" "$APP/Contents/Resources/bin/helper" \
  "$APP/Contents/Library/Helper.app/Contents/MacOS/helper" "$APP/Contents/Frameworks/libalready.dylib"; do
  archs="$(lipo -archs "$bin")"
  [ "$archs" = "arm64" ] || fail "$bin has archs '$archs', expected arm64"
done
[ -x "$APP/Contents/Resources/bin/helper" ] || fail "thinned helper lost its executable bit"
[ -L "$APP/Contents/Resources/bin/helper-link" ] || fail "symlink was replaced"
[ "$(cat "$APP/Contents/Resources/notes.txt")" = "plain text" ] || fail "non-Mach-O file was modified"
[ "$(sed -n 2p "$APP/Contents/Resources/bin/script")" = "echo hi" ] || fail "shell script was modified"
if [ "$(uname -m)" = "arm64" ]; then
  [ "$("$APP/Contents/MacOS/Sample")" = "hi" ] || fail "thinned binary does not run"
fi

# A bundle whose Mach-O lacks the requested slice must be rejected.
BAD="$TMP_DIR/Bad.app"
mkdir -p "$BAD/Contents/MacOS"
lipo "$fat_source" -thin arm64 -output "$BAD/Contents/MacOS/Bad"
if "$THIN" "$BAD" x86_64 2>/dev/null; then
  fail "thinning accepted a bundle without the requested slice"
fi

echo "PASS: thin-app-bundle thins fat Mach-O files and leaves other files alone"
