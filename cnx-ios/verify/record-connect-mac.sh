#!/usr/bin/env bash
# Records the Connect your Mac states: the Workspaces empty state
# (`-cnx-demo connect-mac`) and the setup step (`-cnx-setup-pair`), each
# with the Mac appearing a few seconds in. Needs a built app.
# usage: verify/record-connect-mac.sh <udid> <label> [light|dark]
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd "$(dirname "$0")/.."
udid=$1 label=$2 mode=${3:-dark}
out="verify/evidence/$(date +%Y-%m-%d)/wsnew/$label"
mkdir -p "$out"
xcrun simctl spawn "$udid" defaults write dev.cmux.cnx cnx.setupComplete -bool true
xcrun simctl ui "$udid" appearance "$mode"
xcrun simctl status_bar "$udid" override --time 9:41 --batteryLevel 100 --batteryState charged --cellularBars 4 --wifiBars 3
export SIMCTL_CHILD_CNX_MOCK_AUTH=1
record() { # name, launch args...
  local name=$1; shift
  local video="$out/$name-$mode.mp4" reclog
  reclog=$(mktemp)
  xcrun simctl terminate "$udid" dev.cmux.cnx >/dev/null 2>&1 || true
  xcrun simctl io "$udid" recordVideo --codec h264 --force "$video" >"$reclog" 2>&1 &
  local rec=$!
  until grep -q "Recording started" "$reclog"; do sleep 0.1; done
  xcrun simctl launch "$udid" dev.cmux.cnx "$@" >/dev/null
  sleep 12
  kill -INT "$rec"; wait "$rec" || true
  echo "$video"
}
record connect-mac-workspaces -cnx-demo connect-mac
record connect-mac-setup -cnx-setup-pair
