#!/usr/bin/env bash
# Screenshot every Settings page and the toggle-bearing sheets on a headless
# simulator, dark and light (no Simulator.app window).
# usage: verify/toggles-shots.sh <udid> <label> <outdir>
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
udid=$1 label=$2 dir=$3
mkdir -p "$dir"
export SIMCTL_CHILD_CNX_MOCK_AUTH=1
xcrun simctl status_bar "$udid" override --time 9:41 --batteryLevel 100 --batteryState charged --cellularBars 4 --wifiBars 3
shot() { # name seconds args...
  local name=$1 wait=$2; shift 2
  xcrun simctl terminate "$udid" dev.cmux.cnx >/dev/null 2>&1 || true
  xcrun simctl launch "$udid" dev.cmux.cnx -cnx.setupComplete YES "$@" >/dev/null
  sleep "$wait"   # pacing for a still capture, not synchronization
  xcrun simctl io "$udid" screenshot --type png "$dir/$label-$name-$mode.png" >/dev/null 2>&1
}
for mode in dark light; do
  xcrun simctl ui "$udid" appearance "$mode"
  shot settings-top 4 -cnx-tab settings
  shot settings-middle 5 -cnx-demo settings-middle
  shot settings-bottom 5 -cnx-demo settings-bottom
  for page in account team pairedMacs terminal composer notifications acknowledgements; do
    shot "page-$page" 4 -cnx-settings-page "$page"
  done
  shot team-editor 4.5 -cnx-tab workspaces -cnx-demo editor
done
ls "$dir" | grep -c "^$label-"
