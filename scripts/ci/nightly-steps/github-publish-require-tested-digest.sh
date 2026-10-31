#!/usr/bin/env bash
# nightly.yml publish-nightly-next-github: "Require the DMG to match a tested digest". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
# The bytes publish-nightly checked and put on R2: the tested digest again, then the
# feed exactly as it went live.
set -euo pipefail
dmg="nightly-out/${CHANNEL_DMG_PREFIX}-arm64-${NIGHTLY_BUILD}.dmg"
actual="$(shasum -a 256 "$dmg" | awk '{print $1}')"
cat tested/*.sha256 | grep -Fxq "$actual  $(basename "$dmg")" || { echo "$dmg ($actual) is not the tested DMG" >&2; exit 1; }
for feed in $NIGHTLY_FEEDS; do cp "next-github/$feed" "nightly-out/$feed"; done
if [ -f next-github/nightly-prs.md ]; then cp next-github/nightly-prs.md "$RUNNER_TEMP/nightly-prs.md"; fi
