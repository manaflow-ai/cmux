#!/usr/bin/env bash
# cleanup-dev-builds.sh never deletes the build of the app opened last: the
# app writes ~/Library/Application Support/cmux/last-app-cli at launch
# (plans/cmux-next/version-skew.md), and a fleet or Tag Opener build never
# writes reload.sh's legacy /tmp/cmux-last-cli-path. Dry run with a fake HOME.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FAKE_HOME="$(mktemp -d)"
trap 'rm -rf "$FAKE_HOME"' EXIT

opened="zzptropened$$"
stale="zzptrstale$$"
derived="$FAKE_HOME/Library/Developer/Xcode/DerivedData"
for tag in "$opened" "$stale"; do
  mkdir -p "$derived/cmux-$tag/Build/Products/Debug/cmux DEV $tag.app/Contents/Resources/bin"
done
mkdir -p "$FAKE_HOME/Library/Application Support/cmux"
printf '%s\n' "$derived/cmux-$opened/Build/Products/Debug/cmux DEV $opened.app/Contents/Resources/bin/cmux" \
  > "$FAKE_HOME/Library/Application Support/cmux/last-app-cli"

out="$(HOME="$FAKE_HOME" "$ROOT_DIR/scripts/cleanup-dev-builds.sh")"
skipping="$(sed -n '/^skipping:/,/^$/p' <<<"$out")"
deleting="$(sed -n '/^would delete:/,/^$/p' <<<"$out")"

fail=0
grep -q "$opened" <<<"$skipping" || { echo "FAIL: the app opened last ($opened) is not skipped"; fail=1; }
grep -q "$opened" <<<"$deleting" && { echo "FAIL: the app opened last ($opened) would be deleted"; fail=1; }
grep -q "$stale" <<<"$deleting" || { echo "FAIL: the stale build ($stale) is not planned for deletion"; fail=1; }
if [[ "$fail" -ne 0 ]]; then
  printf '%s\n' "$out"
  exit 1
fi
echo "PASS: cleanup-dev-builds keeps the app opened last"
