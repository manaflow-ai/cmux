#!/usr/bin/env bash
# nightly.yml publish-nightly: "Publish nightly release assets". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# A refused upload backs off within 30 minutes (publish-release-assets.py), not 10:
# run 40298250989's built nightly was lost to 10 minutes of refusals (2026-10-26).
# Every wait in this job (notes, assets, archive, gh) shares one hour
# (GH_BUDGET_WAIT_MAX_SECONDS), so the job's 120 minutes keep 60 for the work.
set -euo pipefail
if [ "$NIGHTLY_TRACK" = nightly-next ]; then
  # arm64 only (decide): the x86_64, universal and legacy names keep their last build.
  variants=(arm64)
  aliases=("${CHANNEL_DMG_PREFIX}-arm64.dmg")
else
  variants=(arm64 x86_64 universal)
  aliases=("${CHANNEL_DMG_PREFIX}-arm64.dmg" "${CHANNEL_DMG_PREFIX}-x86_64.dmg" "${CHANNEL_DMG_PREFIX}-universal.dmg" "${CHANNEL_DMG_PREFIX}.dmg")
fi
args=()
for variant in "${variants[@]}"; do
  args+=(--immutable "nightly-out/${CHANNEL_DMG_PREFIX}-${variant}-${NIGHTLY_BUILD}.dmg")
done
for daemon in linux-arm64 linux-amd64 darwin-arm64 darwin-amd64; do
  args+=(--immutable "nightly-out/cmuxd-remote-${daemon}-${NIGHTLY_BUILD}")
done
args+=(--immutable "nightly-out/cmuxd-remote-checksums-${NIGHTLY_BUILD}.txt")
args+=(--immutable "nightly-out/cmuxd-remote-manifest-${NIGHTLY_BUILD}.json")
args+=(--immutable "nightly-out/cmuxd-remote-THIRD_PARTY_LICENSES-${NIGHTLY_BUILD}.txt")
for alias in "${aliases[@]}"; do
  args+=(--alias "nightly-out/$alias")
done
for feed in $NIGHTLY_FEEDS; do
  args+=(--feed "nightly-out/$feed")
done
python3 "$PUBLISH_TOOLING/ci/publish-release-assets.py" \
  --repo "$GITHUB_REPOSITORY" --tag "$CHANNEL_RELEASE_TAG" \
  --github-output "$GITHUB_OUTPUT" \
  --replace-feeds "${args[@]}"
