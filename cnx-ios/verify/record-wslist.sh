#!/usr/bin/env bash
# Workspaces list Mac filter walkthrough with real HID taps (axe), recorded.
# Opens the title menu, picks each kind of Mac (online with workspaces,
# online and empty, offline with workspaces, offline and empty), creates a
# workspace from the empty state, goes back, relaunches to check the filter
# survived, and returns to All Macs. A screenshot per step plus 2 fps frames.
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
  sleep 3
}
shot() { sleep "${2:-1}"; xcrun simctl io "$udid" screenshot "$dir/$1.png" >/dev/null 2>&1; echo "$1"; }
title() { axe tap -x 201 -y 79 --udid "$udid" >/dev/null; }
# Menu rows (points): the menu drops from the title at the same place in
# every scope. Online Macs first, as the menu orders them.
pick() {
  local y
  case $1 in
    "All Macs") y=108 ;; "Aziz's Mac Studio") y=217 ;; "cmux mini 2") y=277 ;;
    "MacBook Air") y=337 ;; "MacBook Pro") y=397 ;; "Office mini") y=457 ;;
  esac
  sleep 0.8
  axe tap -x 205 -y "$y" --udid "$udid" >/dev/null
}

xcrun simctl terminate "$udid" dev.cmux.cnx 2>/dev/null || true
# Start from All Macs: clear any stored filter from an earlier run.
launch -cnx.workspaces.macFilter.team-manaflow ""
log=$(mktemp)
xcrun simctl io "$udid" recordVideo --codec h264 --force "$dir/walk.mp4" >"$log" 2>&1 &
rec=$!
until grep -q "Recording started" "$log"; do sleep 0.1; done
shot 01-all 0.5
title; shot 02-menu
pick "Aziz's Mac Studio"; shot 03-studio
title; pick "MacBook Pro"; shot 04-offline-with-workspaces
title; pick "Office mini"; shot 05-offline-empty
title; pick "MacBook Air"; shot 06-online-empty
# The empty state's New Workspace capsule (center of the screen).
axe tap -x 201 -y ${NEW_Y:-497} --udid "$udid" >/dev/null
shot 07-created-pushed 1.5
axe drag --start-x 1 --start-y 450 --end-x 300 --end-y 450 --duration 0.5 --steps 40 --udid "$udid" >/dev/null
shot 08-back-on-air 1.5
kill -INT $rec; wait $rec || true
# Relaunch: the filter is remembered for the team.
xcrun simctl terminate "$udid" dev.cmux.cnx
SIMCTL_CHILD_CNX_MOCK_AUTH=1 xcrun simctl launch "$udid" dev.cmux.cnx -cnx.setupComplete YES -cnx-tab workspaces >/dev/null
shot 09-relaunched 3
title; pick "All Macs"; shot 10-back-to-all
rm -rf "$dir/frames"; mkdir -p "$dir/frames"
ffmpeg -loglevel error -y -i "$dir/walk.mp4" -vf "fps=2,scale=300:-1" "$dir/frames/f%03d.png"
ls "$dir/frames" | wc -l
