#!/usr/bin/env bash
# Screenshot each flagship theme (cmux#47278) in a side copy of Leo's NIGHTLY, never in his app, and stitch
# the shots into a short video. Run on the Mac that has /Applications/cmux NIGHTLY.app, from a cmux checkout
# (for side-instance.sh):
#   capture-flagships.sh CMUX_CHECKOUT [THEME...]     (default: all six)
# It makes side instance `flagships`, writes each theme file into the copy's own config folder, applies it
# through the copy's socket with CMUX_NEXT_CONFIG_FILE pinned to the copy's settings (the CLI otherwise writes
# ~/.config/cmux/cmux-next.json, Leo's), reads the theme back, screenshots the copy's window, then removes the
# copy. It hashes Leo's settings file before and after and says if it changed.
# Output: one line per theme, `THEME themeFile=... accent=... shot=PATH`, then the video path; all in $OUT.
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

build=$("$NIGHTLY/Contents/Resources/bin/cmux-tui" --version --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("build_commit",""))')
echo "nightly build_commit=$build"

"$SIDE" make "$NAME" --from "$NIGHTLY" --neutral-shell >/dev/null || { echo "side-instance make failed"; exit 1; }
"$SIDE" launch "$NAME" >/dev/null
SOCK=$("$SIDE" socket "$NAME")
CFG="$(dirname "$("$SIDE" path "$NAME")")/config"
SETTINGS="$CFG/cmux-next.json"
case "$SETTINGS" in "$HOME/.config/cmux/"*) echo "refusing: settings path is Leo's own ($SETTINGS)"; "$SIDE" remove "$NAME"; exit 3;; esac
side() { CMUX_BUNDLE_ID= CMUX_NEXT_CONFIG_FILE="$SETTINGS" "$CLI" --app-socket "$SOCK" "$@"; }
LEO="$HOME/.config/cmux/cmux-next.json"
leo_before=$(shasum "$LEO" 2>/dev/null | cut -c1-40)
trap '"$SIDE" remove "$NAME" >/dev/null 2>&1; [ "$(shasum "$LEO" 2>/dev/null | cut -c1-40)" = "$leo_before" ] && echo "leo-settings unchanged" || echo "WARNING: Leo cmux-next.json changed during the run"' EXIT
for _ in $(seq 60); do side ping >/dev/null 2>&1 && break; sleep 1; done

# Step 0: the copy reads themes from its own config folder, or nothing below is a read-back.
mkdir -p "$CFG/themes"
printf '{ "appearance.accent": "magenta" }\n' > "$CFG/themes/fl-probe.json"
side settings set appearance.themeFile fl-probe >/dev/null
probe=$(side theme get appearance.accent 2>&1)
echo "step0 themes-dir=$CFG/themes accent=$probe $([[ $probe == *magenta* ]] && echo ok || echo FAIL)"
[[ $probe == *magenta* ]] || { echo "the copy does not read $CFG/themes: stop"; exit 2; }

shot() {  # shot FILE: the copy's first window, never focused or raised
  local win
  win=$(side window list --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); w=d if isinstance(d,list) else d.get("windows",[]); print(w[0].get("id","") if w else "")')
  [ -n "$win" ] && side window screenshot --target "$win" --out "$1" >/dev/null 2>&1 && echo "$1"
}
shot "$OUT/00-probe.png" >/dev/null

i=1
for t in "${THEMES[@]}"; do
  curl -fsSLo "$CFG/themes/$t.json" "$BASE/$t.json" || { echo "$t: download failed"; continue; }
  side settings set appearance.themeFile "$t" >/dev/null
  # Builds before #47278 refuse font keys in a theme file: set the chat face as a setting too.
  side settings set agentPane.display.font.ui hanken >/dev/null 2>&1
  side theme check 2>&1 | sed "s/^/$t check: /"
  sleep 3  # the color transition and the backdrop load
  got=$(side settings get appearance.themeFile 2>&1); acc=$(side theme get appearance.accent 2>&1)
  f=$(printf '%s/%02d-%s.png' "$OUT" "$i" "$t"); s=$(shot "$f")
  echo "$t themeFile=$got accent=$acc shot=${s:-FAIL}"
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
