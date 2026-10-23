#!/usr/bin/env bash
# The "Bundle Ghostty resources" phase of the cmux-next app copies Ghostty's
# shell integration from ghostty-next, the Ghostty that GhosttyNextKit and
# libghostty-vt build from (not the classic `ghostty` submodule). The bundled
# shell-integration tree must equal ghostty-next/src/shell-integration file for
# file, so the app and the cmux-tui daemon (which embeds the same files) inject
# the same scripts. One exception, the same in both: bash/ghostty.bash ends with
# cmux-tui's shell_integration/ghostty-preexec.bash (no fork per command on bash
# 5.3), appended once however often the phase runs, and the phase fails without
# it. Interim: with the ghostty-next bump to 72578da this exception goes
# (see ghostty-preexec.bash).
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
bash_fix=cmux-tui/crates/cmux-tui-core/src/shell_integration/ghostty-preexec.bash
for path in Resources/ghostty Resources/cmux-themes Resources/terminfo-overlay Resources/shell-integration Resources/cmux-cli-path "$bash_fix"; do
  if [[ -e "$ROOT/$path" ]]; then mkdir -p "$src/$(dirname "$path")"; ln -s "$ROOT/$path" "$src/$path"; fi
done
# An app bundle built before the classic tree stopped shipping: the phase removes it.
mkdir -p "$TMP/build/app.app/Contents/Resources/shell-integration/fish"
echo stale >"$TMP/build/app.app/Contents/Resources/shell-integration/fish/config.fish"
# Twice, as an incremental build runs it: the bash fix must not pile up.
for run in 1 2; do
  env -i PATH=/usr/bin:/bin TARGET_BUILD_DIR="$TMP/build" UNLOCALIZED_RESOURCES_FOLDER_PATH=app.app/Contents/Resources \
    SRCROOT="$src" bash "$ROOT/scripts/cmux-next/bundle-ghostty-resources.sh" >"$TMP/log" 2>&1 \
    || { cat "$TMP/log" >&2; echo "FAIL: the phase failed (run $run)" >&2; exit 1; }
done
bundled="$TMP/build/app.app/Contents/Resources/ghostty/shell-integration"
[[ -d "$bundled" ]] || { cat "$TMP/log" >&2; echo "FAIL: no bundled shell integration" >&2; exit 1; }
# This tree is Ghostty's alone, and the classic app's scripts
# (Resources/shell-integration), which no cmux-next shell sources, are not
# shipped at all.
fail=0
[[ ! -e "$TMP/build/app.app/Contents/Resources/shell-integration" ]] \
  || { echo "FAIL: the classic Resources/shell-integration is bundled (or an old copy stayed)" >&2; fail=1; }
diff -r -x ghostty.bash "$source_tree" "$bundled" >"$TMP/diff" 2>&1 || { cat "$TMP/diff" >&2; echo "FAIL: bundled shell integration differs from ghostty-next" >&2; fail=1; }
cat "$source_tree/bash/ghostty.bash" "$ROOT/$bash_fix" >"$TMP/ghostty.bash"
cmp -s "$TMP/ghostty.bash" "$bundled/bash/ghostty.bash" \
  || { echo "FAIL: bundled bash/ghostty.bash is not ghostty-next's with $bash_fix appended once" >&2; fail=1; }
# The layers that keep the bundled `cmux` first on PATH (BundledCLIEnvironment).
diff -r "$ROOT/Resources/cmux-cli-path" "$TMP/build/app.app/Contents/Resources/cmux-cli-path" >"$TMP/diff2" 2>&1 \
  || { cat "$TMP/diff2" >&2; echo "FAIL: bundled cmux-cli-path differs from Resources/cmux-cli-path" >&2; fail=1; }
# cmux's own themes (Resources/cmux-themes) land next to Ghostty's.
for theme in "$ROOT"/Resources/cmux-themes/*; do
  cmp -s "$theme" "$TMP/build/app.app/Contents/Resources/ghostty/themes/$(basename "$theme")" \
    || { echo "FAIL: $(basename "$theme") is not bundled in ghostty/themes" >&2; fail=1; }
done
# A source tree without the fix file (sparse checkout, a moved file) fails the
# phase instead of shipping Ghostty's forking hook next to the daemon's fixed copy.
nofix="$TMP/nofix"
mkdir -p "$nofix/Resources"
ln -s "$ROOT/ghostty-next" "$nofix/ghostty-next"
if env -i PATH=/usr/bin:/bin TARGET_BUILD_DIR="$TMP/build-nofix" UNLOCALIZED_RESOURCES_FOLDER_PATH=app.app/Contents/Resources \
  SRCROOT="$nofix" bash "$ROOT/scripts/cmux-next/bundle-ghostty-resources.sh" >"$TMP/log-nofix" 2>&1; then
  echo "FAIL: the phase passed without $bash_fix" >&2; fail=1
fi
[[ $fail -eq 0 ]] || exit 1
echo "PASS: bundled shell integration equals ghostty-next/src/shell-integration (bash/ghostty.bash with the cmux fix appended once)"
