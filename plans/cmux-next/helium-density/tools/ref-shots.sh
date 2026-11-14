#!/bin/bash
# usage: ref-shots.sh APP_NAME(Helium|Chrome) MODE(light|dark) OUTDIR
set -u
APPN=$1; MODE=$2; OUT=$3
case $APPN in
  Helium) APP=~/Applications/Helium.app; BIN="$APP/Contents/MacOS/Helium";;
  Chrome) APP="/Applications/Google Chrome.app"; BIN="$APP/Contents/MacOS/Google Chrome";;
esac
PROF=~/density-helium/profiles/$APPN-$MODE
rm -rf "$PROF"; mkdir -p "$PROF/Default" "$OUT"
SCHEME=$([ $MODE = light ] && echo 1 || echo 2)
cat > "$PROF/Default/Preferences" <<J
{"browser":{"theme":{"color_scheme2":$SCHEME,"color_scheme":$SCHEME},"has_seen_welcome_page":true},"bookmark_bar":{"show_on_all_tabs":false},"helium":{"onboarding":{"completed":true}}}
J
echo '{}' > "$PROF/First Run"; touch "$PROF/First Run"
open -n -a "$APP" --args --user-data-dir="$PROF" --no-first-run --no-default-browser-check --disable-sync --window-position=40,60 --window-size=1400,700 \
  "https://example.com/" "https://www.iana.org/help/example-domains" "https://example.org/"
sleep 10
PID=$(pgrep -f -- "--user-data-dir=$PROF" | head -1)
WIN=$(python3 ~/density-helium/cua.py list_windows "{\"pid\":$PID}" | python3 -c "import json,sys; d=json.load(sys.stdin); w=[x for x in d['windows'] if x['bounds']['height']>300]; print(w[0]['window_id'] if w else '')")
echo "pid $PID win $WIN"
python3 ~/density-helium/cua.py get_window_state "{\"pid\":$PID,\"window_id\":$WIN,\"max_elements\":1,\"include_screenshot\":true,\"screenshot_out_file\":\"$OUT/$APPN-$MODE.png\"}" >/dev/null; sips -g pixelWidth -g pixelHeight "$OUT/$APPN-$MODE.png" | tail -2
echo $PID > "$OUT/$APPN-$MODE.pid"
