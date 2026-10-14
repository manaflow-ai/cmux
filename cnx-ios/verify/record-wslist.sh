#!/usr/bin/env bash
# Workspaces list walkthrough (ChatGPT-style list, Mac chips) with real HID
# touches (axe), recorded. Pull-down search, each kind of chip (online with
# workspaces, offline with workspaces, offline empty, online empty), an
# offline row's explanation, New Workspace on the chosen Mac, the row menu
# (Rename), swipe left to Close, and a relaunch that keeps the chip.
# A screenshot per step plus 2 fps frames.
# usage: verify/record-wslist.sh <udid> <out-dir> [dark|light] [content-size]
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
udid=$1 dir=$2 look=${3:-dark} size=${4:-large}
mkdir -p "$dir"
xcrun simctl ui "$udid" appearance "$look"
xcrun simctl ui "$udid" content_size "$size"
launch() {
  SIMCTL_CHILD_CNX_MOCK_AUTH=1 xcrun simctl launch --terminate-running-process "$udid" dev.cmux.cnx \
    -cnx.setupComplete YES -cnx-tab workspaces "$@" >/dev/null
  sleep 4
}
shot() { sleep "${2:-1}"; xcrun simctl io "$udid" screenshot "$dir/$1.png" >/dev/null 2>&1; echo "$1"; }
tap() { axe tap --udid "$udid" --wait-timeout 3 "$@" >/dev/null; }
at() { axe tap -x "$1" -y "$2" --udid "$udid" >/dev/null; }
hold() { axe touch -x "$1" -y "$2" --down --up --delay 1.2 --udid "$udid" >/dev/null; }
# Center y of a row by its accessibility id.
rowy() {
  axe describe-ui --udid "$udid" | python3 -c '
import json,sys
want=sys.argv[1]
def walk(n):
    if n.get("AXUniqueId")==want:
        f=n["frame"]; print(int(f["x"]+f["width"]/2), int(f["y"]+f["height"]/2)); sys.exit()
    for c in n.get("children") or []: walk(c)
for n in json.load(sys.stdin): walk(n)' "$1"
}

# Taps a Mac chip, first scrolling the chip row when it is off screen.
chip() {
  local x y
  read -r x y < <(rowy "workspaces.chip.$1")
  if [ "$x" -gt 360 ]; then
    axe swipe --start-x 380 --start-y "$y" --end-x 40 --end-y "$y" --duration 0.4 --udid "$udid" >/dev/null; sleep 0.8
  elif [ "$x" -lt 40 ]; then
    axe swipe --start-x 40 --start-y "$y" --end-x 380 --end-y "$y" --duration 0.4 --udid "$udid" >/dev/null; sleep 0.8
  fi
  tap --id "workspaces.chip.$1"
}

xcrun simctl terminate "$udid" dev.cmux.cnx 2>/dev/null || true
launch -cnx.workspaces.macFilter.team-manaflow ""
log=$(mktemp)
xcrun simctl io "$udid" recordVideo --codec h264 --force "$dir/walk.mp4" >"$log" 2>&1 &
rec=$!
until grep -q "Recording started" "$log"; do sleep 0.1; done
shot 01-all 0.5
axe swipe --start-x 200 --start-y 260 --end-x 200 --end-y 460 --duration 0.8 --udid "$udid" >/dev/null
shot 02-pulled-search
at 150 139; sleep 0.6; axe type "cm" --udid "$udid" >/dev/null
shot 03-search-results
at 363 92
chip mac-studio; shot 04-studio
chip mbp; shot 05-offline-mac
read -r x y < <(rowy workspace.row.ws-notes); at "$x" "$y"; shot 06-offline-explained
tap --label OK
chip mini-office; shot 07-offline-empty
chip mba; shot 08-online-empty
# The empty state's New Workspace capsule (large text; NEW_Y for other sizes).
at 201 "${NEW_Y:-561}"; shot 09-created-pushed 1.5
axe drag --start-x 1 --start-y 450 --end-x 300 --end-y 450 --duration 0.5 --steps 40 --udid "$udid" >/dev/null
shot 10-back-on-air 1.5
chip all
read -r x y < <(rowy workspace.row.ws-web); hold "$x" "$y"; shot 11-row-menu
tap --label Rename; shot 12-rename
axe type " site" --udid "$udid" >/dev/null
tap --label Rename --element-type Button; shot 13-renamed 1.2
read -r x y < <(rowy workspace.row.ws-infra)
axe swipe --start-x 330 --start-y "$y" --end-x 150 --end-y "$y" --duration 0.4 --udid "$udid" >/dev/null
shot 14-swipe-close
tap --label Close --element-type Button; shot 15-close-confirm
tap --label "Close Workspace" --element-type Button; shot 16-closed 1.2
chip mac-mini-2; shot 17-mini2 0.8
kill -INT $rec; wait $rec || true
# Relaunch: the chip is remembered for the team.
xcrun simctl terminate "$udid" dev.cmux.cnx
SIMCTL_CHILD_CNX_MOCK_AUTH=1 xcrun simctl launch "$udid" dev.cmux.cnx -cnx.setupComplete YES -cnx-tab workspaces >/dev/null
shot 18-relaunched 4
chip all; shot 19-back-to-all
rm -rf "$dir/frames"; mkdir -p "$dir/frames"
ffmpeg -loglevel error -y -i "$dir/walk.mp4" -vf "fps=2,scale=300:-1" "$dir/frames/f%03d.png"
ls "$dir/frames" | wc -l
