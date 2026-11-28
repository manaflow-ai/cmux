#!/usr/bin/env bash
# The share this commit's Cloud machine build starts at (RFD 0224 phase 3), on stdout, for
# `cmux-machine-channel.py payload --rollout-pct`: CLOUD_MACHINE_FIRST_PCT, or the share the channel's current build
# reached when its inventory shows machines on it and no update-failed (cmux-machine-channel.py first-pct, the
# fast-head rule), or the current share when the channel already names this commit. Called only when
# CLOUD_MACHINE_FIRST_PCT is set (cmux-machine-channel.yml point-x86_64 and point-linux).
#
# usage: scripts/ci/cmux-machine-channel-first-pct.sh DIR   (reads GITHUB_SHA, CLOUD_MACHINE_FIRST_PCT)
set -euo pipefail
dir=$1
files=https://files.cmux.com
keys=Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json
rm -f "$dir/first-current.json" "$dir/first-inventory.json"
curl -fsS --retry 3 --max-time 60 -o "$dir/first-current.json" \
  "$files/cmux-tui/channels/cloud-machine.json?first=${GITHUB_RUN_ID:-0}" >&2 || rm -f "$dir/first-current.json"
args=()
if [[ -s "$dir/first-current.json" ]]; then
  args=(--current "$dir/first-current.json")
  if before=$(python3 scripts/cmux-next/web-ota-pointer.py verify --pointer "$dir/first-current.json" --keys "$keys" \
      --purpose cmux-cloud-machine-update --channel cloud-machine --allow-expired 2>/dev/null |
      python3 -c 'import json, sys; print(json.load(sys.stdin)["commit"])'); then
    scripts/ci/cmux-machine-channel-inventory.sh "$before" "$dir/first-inventory.json"
    [[ -s "$dir/first-inventory.json" ]] && args+=(--inventory "$dir/first-inventory.json")
  fi
fi
python3 scripts/ci/cmux-machine-channel.py first-pct --first "$CLOUD_MACHINE_FIRST_PCT" --commit "$GITHUB_SHA" \
  --keys "$keys" "${args[@]}"
