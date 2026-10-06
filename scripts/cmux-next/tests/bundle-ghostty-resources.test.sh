#!/usr/bin/env bash
# The "Bundle Ghostty resources" phase of the cmux-next app copies Ghostty's
# shell integration from ghostty-next, the Ghostty that GhosttyNextKit and
# libghostty-vt build from (not the classic `ghostty` submodule). The bundled
# shell-integration tree must equal ghostty-next/src/shell-integration file for
# file, so the app and the cmux-tui daemon (which embeds the same files) inject
# the same scripts.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
source_tree="$ROOT/ghostty-next/src/shell-integration"
[[ -d "$source_tree" ]] || { echo "FAIL: $source_tree is missing (git submodule update --init ghostty-next)" >&2; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# A source root with ghostty-next and the checked-in resources, but no classic
# `ghostty` submodule: the phase must not need it.
src="$TMP/src"
mkdir -p "$src"
ln -s "$ROOT/ghostty-next" "$src/ghostty-next"
for path in Resources/ghostty Resources/terminfo-overlay Resources/shell-integration; do
  if [[ -e "$ROOT/$path" ]]; then mkdir -p "$src/$(dirname "$path")"; ln -s "$ROOT/$path" "$src/$path"; fi
done
env -i PATH=/usr/bin:/bin TARGET_BUILD_DIR="$TMP/build" UNLOCALIZED_RESOURCES_FOLDER_PATH=app.app/Contents/Resources \
  SRCROOT="$src" bash "$ROOT/scripts/cmux-next/bundle-ghostty-resources.sh" >"$TMP/log" 2>&1 \
  || { cat "$TMP/log" >&2; echo "FAIL: the phase failed" >&2; exit 1; }
bundled="$TMP/build/app.app/Contents/Resources/ghostty/shell-integration"
[[ -d "$bundled" ]] || { cat "$TMP/log" >&2; echo "FAIL: no bundled shell integration" >&2; exit 1; }
# cmux's own scripts (Resources/shell-integration) go to a separate
# <Resources>/shell-integration, so this tree is Ghostty's alone.
fail=0
diff -r "$source_tree" "$bundled" >"$TMP/diff" 2>&1 || { cat "$TMP/diff" >&2; echo "FAIL: bundled shell integration differs from ghostty-next" >&2; fail=1; }
[[ $fail -eq 0 ]] || exit 1
echo "PASS: bundled shell integration equals ghostty-next/src/shell-integration"
