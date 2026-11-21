#!/usr/bin/env bash
# nightly.yml publish-nightly-next-github: "Publish nightly-next release assets". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# Off the feed's path: this job may wait out the limit as long as its timeout allows.
set -euo pipefail
args=(--immutable "nightly-out/${CHANNEL_DMG_PREFIX}-arm64-${NIGHTLY_BUILD}.dmg")
for daemon in linux-arm64 linux-amd64 darwin-arm64 darwin-amd64; do
  args+=(--immutable "nightly-out/cmuxd-remote-${daemon}-${NIGHTLY_BUILD}")
done
args+=(--immutable "nightly-out/cmuxd-remote-checksums-${NIGHTLY_BUILD}.txt")
args+=(--immutable "nightly-out/cmuxd-remote-manifest-${NIGHTLY_BUILD}.json")
args+=(--immutable "nightly-out/cmuxd-remote-THIRD_PARTY_LICENSES-${NIGHTLY_BUILD}.txt")
python3 "$PUBLISH_TOOLING/ci/publish-release-assets.py" \
  --repo "$GITHUB_REPOSITORY" --tag "$CHANNEL_RELEASE_TAG" \
  --github-output "$GITHUB_OUTPUT" "${args[@]}"
