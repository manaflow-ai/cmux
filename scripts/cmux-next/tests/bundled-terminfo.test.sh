#!/usr/bin/env bash
# The cmux-next app ships the terminfo that the "Bundle Ghostty resources" phase
# writes: Ghostty's entries with cmux's overlay copied on top. The bundled
# entries must carry ghostty-next's capabilities (dim in sgr, overline Smol and
# Rmol, Se resetting to the default cursor) and still keep cmux's patch that
# sends colors 8-15 as 256-color indexes (38;5;n / 48;5;n), not bright SGR
# 90-97 / 100-107 (the zsh-autosuggestions fg=8 fix). The Ghostty entries
# advertise the program status protocol (OSC 7501) with Pst, as its
# specification asks of terminals that implement it.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
command -v infocmp >/dev/null || { echo "FAIL: infocmp (ncurses) is required" >&2; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
src="$TMP/src"
mkdir -p "$src/Resources"
for path in Resources/ghostty Resources/terminfo-overlay; do ln -s "$ROOT/$path" "$src/$path"; done
env -i PATH=/usr/bin:/bin TARGET_BUILD_DIR="$TMP/build" UNLOCALIZED_RESOURCES_FOLDER_PATH=app.app/Contents/Resources \
  SRCROOT="$src" bash "$ROOT/scripts/cmux-next/bundle-ghostty-resources.sh" >"$TMP/log" 2>&1 \
  || { cat "$TMP/log" >&2; echo "FAIL: the phase failed" >&2; exit 1; }
bundled="$TMP/build/app.app/Contents/Resources/terminfo"
# macOS ncurses reads hex directories (78/), Linux ncurses letter directories
# (x/); give infocmp both layouts of the bundled files.
lookup="$TMP/lookup"
for entry in "$bundled"/*/*; do
  name=$(basename "$entry")
  for dir in "$(printf '%x' "'${name:0:1}")" "${name:0:1}"; do mkdir -p "$lookup/$dir"; cp "$entry" "$lookup/$dir/$name"; done
done
fail=0
check() {  # <entry> <description> <grep -F pattern>
  if ! grep -qF -- "$3" "$TMP/$1.src"; then echo "FAIL: $1: $2 (no '$3')" >&2; fail=1; fi
}
for name in xterm-ghostty ghostty xterm-256color; do
  infocmp -x -1 -A "$lookup" "$name" >"$TMP/$name.src" 2>"$TMP/$name.err" \
    || { cat "$TMP/$name.err" >&2; echo "FAIL: $name is not in the bundled terminfo" >&2; fail=1; continue; }
  check "$name" "sgr has no dim" '%?%p5%t;2%;'
  check "$name" "no overline start" 'Smol=\E[53m,'
  check "$name" "no overline end" 'Rmol=\E[55m,'
  check "$name" "Se does not reset to the default cursor" 'Se=\E[0 q,'
  check "$name" "setaf lost the 256-color 8-15 patch" 'setaf=\E[%?%p1%{8}%<%t3%p1%d%e38;5;%p1%d%;m,'
  check "$name" "setab lost the 256-color 8-15 patch" 'setab=\E[%?%p1%{8}%<%t4%p1%d%e48;5;%p1%d%;m,'
  [[ $name == xterm-256color ]] || check "$name" "no program status (OSC 7501) Pst" 'Pst=\E]7501;%p1%s\E\\,'
done
[[ $fail -eq 0 ]] || exit 1
echo "PASS: bundled terminfo has ghostty-next capabilities, Pst and cmux's 256-color 8-15 patch"
