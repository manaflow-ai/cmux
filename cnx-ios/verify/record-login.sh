#!/usr/bin/env bash
# Record the signed-out flow (launch -> welcome, launch -> welcome -> email
# step) on one headless simulator in both appearances.
# usage: verify/record-login.sh <udid> <label> <evidence dir>
set -euo pipefail
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd "$(dirname "$0")/.."
udid=$1 label=$2 dir=$3
mkdir -p "$dir"
export CNX_RECORD_CODEC=${CNX_RECORD_CODEC:-hevc}
for mode in dark light; do
  CNX_CLEAR_AUTH=1 verify/record.sh "$udid" "$dir/$label-welcome-$mode.mp4" 9 "$mode"
  CNX_CLEAR_AUTH=1 verify/record.sh "$udid" "$dir/$label-email-$mode.mp4" 10 "$mode" -cnx-email ""
done
