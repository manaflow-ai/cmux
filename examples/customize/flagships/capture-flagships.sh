#!/usr/bin/env bash
# Screenshot each flagship theme (cmux#47278) in a side copy of Leo's NIGHTLY, never in his app, and stitch
# the shots into a short video. Run on the Mac that has /Applications/cmux NIGHTLY.app, from a cmux checkout
# (for side-instance.sh):
#   capture-flagships.sh CMUX_CHECKOUT [THEME...]     (default: all six)
#
# It never runs a CLI settings or theme write. `cmux --app-socket S settings set` goes to the daemon the
# calling terminal's environment names, which on Leo's Mac serves his own ~/.config/cmux/cmux-next.json, even
# with CMUX_NEXT_CONFIG_FILE pinned (seen 2026-11-19 on NIGHTLY 34acb491; the fix is c03c5b3c). So:
# - a theme is picked by writing `appearance.themeFile` into the copy's own settings file, which the copy reloads;
# - the CLI runs only reads and window screenshots, with a stripped environment (no daemon or socket variables
#   from this terminal) and the copy's socket;
# - Leo's settings file is hashed before the run and after every step, and the run stops at the first change.
# Output: one line per theme, `THEME themeFile=... shot=PATH`, then the video path; all in $OUT.
set -uo pipefail
CHECKOUT=${1:?cmux checkout}; shift
NIGHTLY="/Applications/cmux NIGHTLY.app"
SIDE="$CHECKOUT/scripts/cmux-next/side-instance.sh"
NAME=flagships
OUT=${OUT:-/tmp/flagships-$(date -u +%Y%m%dT%H%M%SZ)}
CLI="$NIGHTLY/Contents/Resources/bin/cmux"
BASE=https://raw.githubusercontent.com/manaflow-ai/cmux/lane/riced-themes/Resources/theme-files
THEMES=("$@"); [ ${#THEMES[@]} -gt 0 ] || THEMES=(sakura sakura-yoru sumi frutiger-aero-2027 one-bit earthly-delights)
mkdir -p "$OUT"

LEO="$HOME/.config/cmux/cmux-next.json"
leo_hash() { shasum -a 256 "$LEO" 2>/dev/null | cut -c1-64; }
leo_before=$(leo_hash)
guard() {  # guard STEP: stop the run if Leo's settings file changed
  [ "$(leo_hash)" = "$leo_before" ] && return 0
  echo "STOP at $1: Leo's cmux-next.json changed; restore it from before the run (sha256 $leo_before)"
  exit 4
}

build=$("$NIGHTLY/Contents/Resources/bin/cmux-tui" --version --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("build_commit",""))')
echo "nightly build_commit=$build"

"$SIDE" make "$NAME" --from "$NIGHTLY" --neutral-shell >/dev/null || { echo "side-instance make failed"; exit 1; }
trap '"$SIDE" remove "$NAME" >/dev/null 2>&1; [ "$(leo_hash)" = "$leo_before" ] && echo "leo-settings unchanged" || echo "WARNING: Leo cmux-next.json changed during the run"' EXIT
"$SIDE" launch "$NAME" >/dev/null
SOCK=$("$SIDE" socket "$NAME")
CFG="$(dirname "$("$SIDE" path "$NAME")")/config"
SETTINGS="$CFG/cmux-next.json"
case "$SETTINGS" in "$HOME/.config/cmux/"*) echo "refusing: settings path is Leo's own ($SETTINGS)"; exit 3;; esac
guard launch

# Reads and screenshots only, with none of this terminal's cmux variables.
side() { env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR="${TMPDIR:-/tmp}" \
  CMUX_NEXT_CONFIG_FILE="$SETTINGS" "$CLI" --app-socket "$SOCK" "$@"; }
for _ in $(seq 60); do side ping >/dev/null 2>&1 && break; sleep 1; done
guard ping

pick() {  # pick THEME: set appearance.themeFile in the copy's own settings file
  /usr/bin/python3 - "$SETTINGS" "$1" <<'PY'
import json, os, sys
path, theme = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
data["appearance.themeFile"] = theme
data["agentPane.display.font.ui"] = "hanken"
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
os.replace(tmp, path)
PY
}

shot() {  # shot FILE: the copy's first window, never focused or raised
  local win
  win=$(side window list --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); w=d if isinstance(d,list) else d.get("windows",[]); print(w[0].get("id","") if w else "")')
  [ -n "$win" ] && side window screenshot --target "$win" --out "$1" >/dev/null 2>&1 && echo "$1"
}

# Step 0: the copy reloads its own settings file and reads themes from its own folder, or nothing below counts.
mkdir -p "$CFG/themes"
printf '{ "appearance.accent": "magenta", "colors": { "background": "#ff00ff" } }\n' > "$CFG/themes/fl-probe.json"
pick fl-probe; sleep 3; guard step0
p=$(shot "$OUT/00-probe.png"); guard step0-shot
echo "step0 settings=$SETTINGS shot=${p:-FAIL} (should be magenta: check it before trusting the rest)"
[ -n "$p" ] || { echo "the copy's window could not be shot: stop"; exit 2; }

i=1
for t in "${THEMES[@]}"; do
  curl -fsSLo "$CFG/themes/$t.json" "$BASE/$t.json" || { echo "$t: download failed"; continue; }
  pick "$t"; sleep 3; guard "$t"   # the color transition and the backdrop load
  got=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("appearance.themeFile"))' "$SETTINGS")
  f=$(printf '%s/%02d-%s.png' "$OUT" "$i" "$t"); s=$(shot "$f"); guard "$t-shot"
  echo "$t themeFile=$got shot=${s:-FAIL}"
  i=$((i + 1))
done

# A short video: each shot for 3 s, in order (a slideshow of the real window shots, not a screen recording).
if command -v ffmpeg >/dev/null; then
  ls "$OUT"/0[1-9]-*.png >/dev/null 2>&1 && ffmpeg -loglevel error -y -framerate 1/3 -pattern_type glob -i "$OUT/0[1-9]-*.png" \
    -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p" -r 30 "$OUT/flagships.mp4" && echo "video=$OUT/flagships.mp4"
else
  echo "video: ffmpeg missing; record the copy with screencapture -v while re-running with one theme at a time"
fi
echo "out=$OUT"
