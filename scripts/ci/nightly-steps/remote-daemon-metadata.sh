#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Resolve immutable SSH daemon metadata". The version and build
# number build-nightly-remote-daemon stamps into the cmuxd-remote assets.
# Env: TRACK, SHOULD_PUBLISH, NIGHTLY_NEXT_FEED_BASE, NIGHTLY_NEXT_LEGACY_FEED_BASE.
set -euo pipefail
app="build-universal/Build/Products/Release/cmux.app"
base_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="${GITHUB_RUN_ID}$(printf '%02d' "${GITHUB_RUN_ATTEMPT:-1}")"
track="$TRACK"
version="$(python3 scripts/ci/nightly_version.py marketing --track "$track" \
  --project-version "$base_version" --build "$build" --next-base "$(python3 scripts/ci/nightly_version.py next-base)")"
if [[ "$track" == "nightly-next" && "$SHOULD_PUBLISH" == "true" ]]; then
  # cmux-next and main's NIGHTLY install as the same app, so a published
  # cmux-next build must be above every build on both feeds: no feed
  # ever offers a downgrade after a switch between the two.
  feeds=()
  for appcast in appcast.xml appcast-arm64.xml appcast-x86_64.xml; do
    feeds+=(--feed-if-present "${NIGHTLY_NEXT_FEED_BASE}/${appcast}" --feed "${NIGHTLY_NEXT_LEGACY_FEED_BASE}/${appcast}" --feed "https://files.cmux.com/nightly/${appcast}")
  done
  python3 scripts/ci/nightly_version.py check-build --build "$build" "${feeds[@]}"
fi
echo "build=$build" >> "$GITHUB_OUTPUT"
echo "version=$version" >> "$GITHUB_OUTPUT"
