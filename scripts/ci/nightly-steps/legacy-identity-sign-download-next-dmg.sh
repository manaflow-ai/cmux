#!/usr/bin/env bash
# nightly.yml sign-nightly-identity-legacy: "Download the published cmux NEXT DMG". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
mkdir -p next-in
if [ -n "$SOURCE_RUN" ]; then
  mkdir -p prepared-in
  gh run download "$SOURCE_RUN" --repo "$GITHUB_REPOSITORY" \
    --pattern "cmux-nightly-prepared-app-arm64-*" --dir prepared-in
else
  # The release is public: fetch the DMG from its download URL (the
  # address the publish step checks), not the API. gh release
  # download spent GITHUB_TOKEN calls and failed with "API rate limit
  # exceeded for installation" (runs 40234225207, 40240049419).
  # R2 first: publish-nightly puts it there before the feed names it, and
  # the release copy follows later (publish-nightly-next-github).
  name="${CHANNEL_DMG_PREFIX}-arm64-${NIGHTLY_BUILD}.dmg"
  curl -fsSL --proto '=https' --retry 3 --retry-delay 5 --connect-timeout 20 \
      -o "next-in/$name" "${NIGHTLY_NEXT_FEED_BASE}/$name" \
    || curl -fsSL --proto '=https' --retry 5 --retry-all-errors --retry-delay 5 --connect-timeout 20 \
      -o "next-in/$name" "https://github.com/${GITHUB_REPOSITORY}/releases/download/${CHANNEL_RELEASE_TAG}/$name"
fi
if [ -z "$SOURCE_RUN" ]; then
  find next-in -maxdepth 1 -name "${CHANNEL_DMG_PREFIX}-arm64-${NIGHTLY_BUILD}.dmg" -print -quit | grep -q .
else
  find prepared-in -type f -name 'cmux-prepared-app.tar.gz' -print -quit | grep -q .
fi
