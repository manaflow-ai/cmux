#!/usr/bin/env bash
# nightly.yml publish-nightly-next-github-names: "Publish the rolling DMG name and the feed copy". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the job's and step's env: still set every input.
set -euo pipefail
if ! "$RUNNER_TEMP/still-newest"; then echo "newest=false" >> "$GITHUB_OUTPUT"; exit 0; fi
feeds=()
for feed in $NIGHTLY_FEEDS; do feeds+=(--feed "nightly-out/$feed"); done
# The versioned DMG publish-nightly-next-github uploaded: the publisher needs one
# immutable asset, reuses the remote copy with the same size and digest, and so writes
# the feed copy only while its versioned file is on the release.
# The rolling name ${CHANNEL_DMG_PREFIX}-arm64.dmg (cmux.com/next, the release body) is the
# same cmux NIGHTLY build (com.cmuxterm.app.nightly), moved only while it is the feed's newest.
dmg="nightly-out/${CHANNEL_DMG_PREFIX}-arm64-${NIGHTLY_BUILD}.dmg"
rolling="nightly-out/${CHANNEL_DMG_PREFIX}-arm64.dmg"
cp -c "$dmg" "$rolling" 2>/dev/null || cp "$dmg" "$rolling"
python3 "$PUBLISH_TOOLING/ci/publish-release-assets.py" \
  --repo "$GITHUB_REPOSITORY" --tag "$CHANNEL_RELEASE_TAG" \
  --immutable "$dmg" --alias "$rolling" \
  --replace-feeds "${feeds[@]}"
echo "newest=true" >> "$GITHUB_OUTPUT"
