#!/usr/bin/env bash
# nightly.yml resolve-nightly-cmux-tui-client: "Leave a sign stage a newer published build superseded".
# A sign stage (nightly_next_sign_stage) signs an earlier push run's unsigned app. When a feed already offers a
# build at or above it (a newer build published first), it writes superseded=true: the build and sign jobs skip,
# before the signer's whole-Mac claim. The feeds are the ones sign-refuse-superseded-resume.sh reads; that
# refusal and the feed's compare-and-swap still stand behind this check.
set -euo pipefail
: "${NIGHTLY_BUILD:?missing the resumed build number}"
: "${NIGHTLY_NEXT_FEED_BASE:?missing NIGHTLY_NEXT_FEED_BASE}"
feeds=()
for appcast in appcast.xml appcast-arm64.xml appcast-x86_64.xml; do
  feeds+=(--feed "${NIGHTLY_NEXT_FEED_BASE}/${appcast}" --feed "https://files.cmux.com/nightly/${appcast}")
done
out=$(python3 scripts/ci/nightly_version.py check-build --build "$NIGHTLY_BUILD" --superseded-ok "${feeds[@]}")
printf '%s\n' "$out"
if printf '%s\n' "$out" | grep -qx 'superseded=true'; then
  echo "superseded=true" >> "$GITHUB_OUTPUT"
  echo "::notice::build $NIGHTLY_BUILD: a newer build is already published; this sign stage signs nothing"
else
  echo "superseded=false" >> "$GITHUB_OUTPUT"
fi
