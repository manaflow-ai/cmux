#!/usr/bin/env bash
# Record every shell flow on one simulator in both appearances.
# usage: verify/shell-flows.sh <udid> <label> <evidence dir>
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd "$(dirname "$0")/.."
udid=$1 label=$2 dir=$3
mkdir -p "$dir"
setup_done() { xcrun simctl spawn "$udid" defaults write dev.cmux.cnx cnx.setupComplete -bool "$1"; }
for mode in dark light; do
  setup_done true
  CNX_MOCK_AUTH=1 verify/record.sh "$udid" "$dir/$label-drawer-$mode.mp4" 15 $mode -cnx-tab workspaces -cnx-demo drawer
  CNX_MOCK_AUTH=1 verify/record.sh "$udid" "$dir/$label-rubber-$mode.mp4" 6 $mode -cnx-tab home -cnx-demo rubber
  CNX_MOCK_AUTH=1 verify/record.sh "$udid" "$dir/$label-settings-$mode.mp4" 11 $mode -cnx-demo settings
  CNX_MOCK_AUTH=1 verify/record.sh "$udid" "$dir/$label-states-$mode.mp4" 17 $mode -cnx-demo states
  CNX_MOCK_AUTH=1 verify/record.sh "$udid" "$dir/$label-editor-$mode.mp4" 6 $mode -cnx-tab workspaces -cnx-demo editor
  CNX_CLEAR_AUTH=1 verify/record.sh "$udid" "$dir/$label-welcome-$mode.mp4" 5 $mode
  CNX_CLEAR_AUTH=1 verify/record.sh "$udid" "$dir/$label-email-$mode.mp4" 4 $mode -cnx-email ""
  CNX_CLEAR_AUTH=1 CNX_MOCK_AUTH=1 verify/record.sh "$udid" "$dir/$label-code-$mode.mp4" 4 $mode -cnx-email name@example.com
  setup_done false
  CNX_MOCK_AUTH=1 verify/record.sh "$udid" "$dir/$label-setup-$mode.mp4" 4 $mode
done
setup_done true
