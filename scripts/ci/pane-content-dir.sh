#!/usr/bin/env bash
# Moves a built pane (build-agent-pane-web.sh --out BUILT) to PARENT/acpmux-agent-pane-<hash of its
# files> and stamps every file and folder with one fixed old time; prints the new path.
#
# acpmux's build.rs embeds the pane with `include_str!` and asks Cargo to rerun on each file, and
# Cargo judges both by mtime. A fresh pane build stamps every file new, so every CI run recompiled
# acpmux even when no byte changed. Here the directory name carries the content (a changed byte is a
# new ACPMUX_BUNDLED_APP_ASSETS_DIR, which reruns build.rs and changes every include path), so the
# mtimes can be fixed: the same pane is fresh, a different pane is a different path.
#
#   scripts/ci/pane-content-dir.sh BUILT PARENT
set -euo pipefail
[ $# -eq 2 ] || { echo "usage: $0 BUILT PARENT" >&2; exit 2; }
built="$1" parent="$2"
if command -v sha256sum >/dev/null 2>&1; then sum() { sha256sum; }; else sum() { shasum -a 256; }; fi
# Names and bytes, in a fixed order, so the hash is the pane's content and nothing else.
hash="$(cd "$built" && find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do
  printf '%s %s\n' "$file" "$(sum < "$file" | cut -d' ' -f1)"
done | sum | cut -c1-16)"
dest="$parent/acpmux-agent-pane-$hash"
[ ! -e "$dest" ] || { echo "error: $dest already exists" >&2; exit 1; }
mv "$built" "$dest"
find "$dest" -exec touch -t 200001010000 {} +
printf '%s\n' "$dest"
