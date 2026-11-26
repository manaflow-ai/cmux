#!/usr/bin/env bash
# Point cmux-tui/channels/linux-nightly.json at the Linux build of the commit the NEXT NIGHTLY ships, so
# `install.sh --channel nightly` (and a Linux host on that channel) runs the same cmux-tui as the NIGHTLY Mac
# app. The NIGHTLY's commit is the first <cmux:sourceCommit> of its appcast; its Linux build is the signed
# cmux-tui/<commit>/release.json that feat-cmux-next's push published. That file is re-signed for the nightly
# channel (cmux-machine-channel.py repoint) with a sequence above the channel's, and only the channel moves
# (cmux-machine-channel-point.sh --channel-only, `newer --follow`): to an older commit too, after a NIGHTLY
# rollback; never rewritten for the same commit until it nears expiry.
#
# usage: scripts/ci/cmux-linux-nightly-follow.sh DIR
# Reads SIGNING_KEY, LINUX_RELEASE_SIGNING_KEY, R2_ENDPOINT and the R2 credentials as
# cmux-machine-channel-point.sh. NIGHTLY_APPCAST overrides the feed URL (tests).
set -euo pipefail
dir=$1
mkdir -p "$dir" && chmod 700 "$dir"
ptr=scripts/cmux-next/web-ota-pointer.py
keys=Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json
appcast="${NIGHTLY_APPCAST:-https://files-next.cmux.com/nightly-next/appcast-arm64.xml}"
curl -fsS --retry 3 --max-time 60 -o "$dir/appcast.xml" "$appcast?linux-nightly=${GITHUB_RUN_ID:-0}"
# The newest build's commit only: an <item> without one never falls through to an older build's.
commit="$(python3 -c '
import re, sys
# <item/> self-closed, or <item ...> to its own </item> (an <enclosure .../> inside does not end it).
item = re.search(r"<item\b[^>]*?(?:/>|>.*?</item>)", open(sys.argv[1]).read(), re.S)
found = item and re.search(r"<cmux:sourceCommit>\s*([0-9a-f]{40})\s*</cmux:sourceCommit>", item.group(0))
print(found.group(1) if found else "")' "$dir/appcast.xml")"
if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "::warning::the NIGHTLY appcast names no source commit; linux-nightly stays"
  exit 0
fi
code="$(curl -sS -o "$dir/release.json" -w '%{http_code}' --max-time 60 \
  "https://files.cmux.com/cmux-tui/$commit/release.json?linux-nightly=${GITHUB_RUN_ID:-0}" || true)"
if [[ "$code" != 200 ]]; then
  echo "::warning::the NIGHTLY's commit ${commit:0:12} has no signed Linux build (HTTP $code); linux-nightly stays"
  exit 0
fi
curl -sS --max-time 60 -o "$dir/current.json" \
  "https://files.cmux.com/cmux-tui/channels/linux-nightly.json?sequence=${GITHUB_RUN_ID:-0}" || true
current="$(python3 "$ptr" sequence --pointer "$dir/current.json" --keys "$keys" --channel nightly)"
python3 scripts/ci/cmux-machine-channel.py repoint --release "$dir/release.json" --keys "$keys" --channel nightly \
  --commit "$commit" --min-sequence "$((current + 1))" --out "$dir/payload.json"
scripts/ci/cmux-machine-channel-point.sh "$dir/payload.json" "$dir" --channel-only
