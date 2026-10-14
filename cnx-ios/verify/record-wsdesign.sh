#!/usr/bin/env bash
# Workspaces "Inbox" list walkthrough (verify/workspaces-design-loop.md) with
# real HID touches (axe), recorded: the list at launch, the Mac filter menu
# (each Mac, then All), an offline Mac's folded line expanded, an offline
# row's explanation, search, the row menu, swipe-left Close, New Workspace
# (tap and hold), and opening a needs-you workspace on its waiting tab.
# A screenshot per step plus 2 fps frames.
# usage: verify/record-wsdesign.sh <udid> <out-dir> [dark|light] [content-size]
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
udid=$1 dir=$2 look=${3:-dark} size=${4:-large}
mkdir -p "$dir"
xcrun simctl ui "$udid" appearance "$look"
xcrun simctl ui "$udid" content_size "$size"
shot() { sleep "${2:-1}"; xcrun simctl io "$udid" screenshot "$dir/$1.png" >/dev/null 2>&1; echo "$1"; }
tap() { axe tap --udid "$udid" --wait-timeout 3 "$@" >/dev/null; }
at() { axe tap -x "$1" -y "$2" --udid "$udid" >/dev/null; }
hold() { axe touch -x "$1" -y "$2" --down --up --delay 1.2 --udid "$udid" >/dev/null; }
back() { axe drag --start-x 1 --start-y 450 --end-x 300 --end-y 450 --duration 0.5 --steps 40 --udid "$udid" >/dev/null; }
# Center of an element by accessibility id (or label with a second argument "label").
where() {
  axe describe-ui --udid "$udid" | python3 -c '
import json,sys
want,key=sys.argv[1],sys.argv[2]
def walk(n):
    if n.get(key)==want:
        f=n["frame"]; print(int(f["x"]+f["width"]/2), int(f["y"]+f["height"]/2)); sys.exit()
    for c in n.get("children") or []: walk(c)
for n in json.load(sys.stdin): walk(n)
sys.exit(1)' "$1" "${2:-AXUniqueId}"
}
# Scrolls the list until an element is on screen (above the tab bar).
reveal() {
  local x y
  for _ in 1 2 3 4 5 6; do
    if read -r x y < <(where "$1") && [ "$y" -lt 700 ] && [ "$y" -gt 220 ]; then echo "$x $y"; return; fi
    axe drag --start-x 200 --start-y 650 --end-x 200 --end-y 420 --duration 1.0 --steps 30 --udid "$udid" >/dev/null; sleep 0.8
  done
  where "$1"
}
top() { axe swipe --start-x 200 --start-y 300 --end-x 200 --end-y 750 --duration 0.3 --udid "$udid" >/dev/null; sleep 0.6; }
filter() { sleep 0.5; tap --id workspaces.filter; sleep 1.5; read -r x y < <(where "$1" AXLabel); at "$x" "$y"; }

xcrun simctl terminate "$udid" dev.cmux.cnx 2>/dev/null || true
SIMCTL_CHILD_CNX_MOCK_AUTH=1 xcrun simctl launch "$udid" dev.cmux.cnx \
  -cnx.setupComplete YES -cnx-tab workspaces -cnx.workspaces.macFilter.team-manaflow "" >/dev/null
sleep 4
log=$(mktemp)
xcrun simctl io "$udid" recordVideo --codec h264 --force "$dir/walk.mp4" >"$log" 2>&1 &
rec=$!
trap 'kill -INT $rec 2>/dev/null || true' EXIT
until grep -q "Recording started" "$log"; do sleep 0.1; done
shot 01-list 0.5
tap --id workspaces.filter; shot 02-filter-menu
read -r x y < <(where "Aziz's Mac Studio" AXLabel); at "$x" "$y"; shot 03-filter-studio
filter "MacBook Pro"; shot 04-filter-offline-mac
read -r x y < <(where workspace.row.ws-notes); at "$x" "$y"; shot 05-offline-explained
tap --label OK
filter "All Macs"; shot 06-filter-all
read -r x y < <(reveal workspaces.fold.mbp); at "$x" "$y"; shot 07-offline-expanded
read -r x y < <(reveal workspace.row.ws-zed); at "$x" "$y"; shot 08-offline-row-tapped
tap --label OK
top
# Pull down until the search field shows under the bar, then tap it.
for _ in 1 2 3; do
  axe swipe --start-x 200 --start-y 260 --end-x 200 --end-y 620 --duration 1.0 --udid "$udid" >/dev/null; sleep 0.8
  if read -r x y < <(where Search AXLabel) && [ "$y" -gt 90 ]; then break; fi
done
shot 09-pulled-search 0.2
at "$x" "$y"
sleep 0.6; axe type "fix" --udid "$udid" >/dev/null
shot 10-search-results
tap --label Close --element-type Button || true
sleep 0.8; top
read -r x y < <(reveal workspace.row.ws-web); hold "$x" "$y"; shot 11-row-menu
axe key 41 --udid "$udid" >/dev/null; sleep 0.8
read -r x y < <(reveal workspace.row.ws-design)
axe swipe --start-x 340 --start-y "$y" --end-x 120 --end-y "$y" --duration 0.4 --udid "$udid" >/dev/null
shot 12-swipe-close
tap --id workspace.swipe.close; shot 13-close-confirm
tap --label "Close Workspace" --element-type Button; shot 14-closed 1.2
top
tap --id workspaces.new; shot 15-new-pushed 1.5
back; shot 16-new-in-list 1.5
read -r x y < <(where workspaces.new); hold "$x" "$y"; shot 17-new-options
# Dismiss the menu (Escape; a tap can land on a full-height AX menu).
axe key 41 --udid "$udid" >/dev/null; sleep 0.8
read -r x y < <(top; reveal workspace.row.ws-ghostty); at "$x" "$y"; shot 18-opened-waiting-tab 2
back; shot 19-back 1.5
kill -INT $rec; wait $rec || true
rm -rf "$dir/frames"; mkdir -p "$dir/frames"
ffmpeg -loglevel error -y -i "$dir/walk.mp4" -vf "fps=2,scale=300:-1" "$dir/frames/f%03d.png"
ls "$dir/frames" | wc -l
