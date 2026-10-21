#!/usr/bin/env bash
# design-variations.py writes a gallery page for a folder of design variations: one tile per
# variation file in name order, each tagged cmux-variation-<n> (so a design mode highlight on it is
# the pick) with its caption, a live frame of the file, and nothing from outside the folder.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
dir="$TMP/vars"; mkdir -p "$dir"
printf '<title>Calm</title><p>a</p>' > "$dir/1-calm.html"
printf '<title>Bold &amp; loud</title><p>b</p>' > "$dir/2-bold.html"
printf 'not a variation' > "$dir/notes.txt"
out=$(python3 -I "$ROOT/scripts/cmux-next/design-variations.py" "$dir")
page="$dir/index.html"
[[ "$out" == "$page" ]] || { echo "design-variations: printed '$out', want $page" >&2; exit 1; }
grep -q 'data-testid="cmux-variation-1"' "$page" || { echo 'design-variations: no tile 1' >&2; exit 1; }
grep -q 'data-testid="cmux-variation-2-title">2. Bold &amp; loud<' "$page" || { cat "$page" >&2; echo 'design-variations: tile 2 caption' >&2; exit 1; }
grep -q 'src="1-calm.html"' "$page" || { echo 'design-variations: tile 1 frame' >&2; exit 1; }
! grep -q 'notes.txt' "$page" || { echo 'design-variations: a non-HTML file became a tile' >&2; exit 1; }
! grep -q 'cmux-variation-3' "$page" || { echo 'design-variations: extra tile' >&2; exit 1; }
# Running it again does not turn its own page into a tile.
python3 -I "$ROOT/scripts/cmux-next/design-variations.py" "$dir" >/dev/null
! grep -q 'src="index.html"' "$page" || { echo 'design-variations: the gallery framed itself' >&2; exit 1; }
# --open shows the page right of the Home chat through `cmux browser right navigate`.
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/args"\n' "$TMP" > "$TMP/cmux"; chmod +x "$TMP/cmux"
CMUX_BIN="$TMP/cmux" python3 -I "$ROOT/scripts/cmux-next/design-variations.py" "$dir" --open --agent "Chief" >/dev/null
[[ "$(tr '\n' ' ' < "$TMP/args")" == "browser right navigate file://$dir/index.html --agent Chief " ]] \
  || { cat "$TMP/args" >&2; echo 'design-variations: --open did not navigate the right column' >&2; exit 1; }
echo 'design-variations: ok'
