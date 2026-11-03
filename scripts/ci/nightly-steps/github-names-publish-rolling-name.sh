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
# The rolling name ${CHANNEL_DMG_PREFIX}-arm64.dmg (cmux.com/next, the release body) is
# not written here: it holds the cmux NIGHTLY build (com.cmuxterm.app.nightly), and only
# publish-nightly-identity-legacy writes it (legacy-identity-publish.sh; user msg 20276).
python3 "$PUBLISH_TOOLING/ci/publish-release-assets.py" \
  --repo "$GITHUB_REPOSITORY" --tag "$CHANNEL_RELEASE_TAG" \
  --immutable "nightly-out/${CHANNEL_DMG_PREFIX}-arm64-${NIGHTLY_BUILD}.dmg" \
  --replace-feeds "${feeds[@]}"
echo "newest=true" >> "$GITHUB_OUTPUT"
