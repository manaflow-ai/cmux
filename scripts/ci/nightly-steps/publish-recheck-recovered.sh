#!/usr/bin/env bash
# nightly.yml publish-nightly: "Recheck the recovered build against both feeds". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
feeds=()
for appcast in appcast.xml appcast-arm64.xml appcast-x86_64.xml; do
  feeds+=(--feed-if-present "${NIGHTLY_NEXT_FEED_BASE}/${appcast}" --feed "${NIGHTLY_NEXT_LEGACY_FEED_BASE}/${appcast}" --feed "https://files.cmux.com/nightly/${appcast}")
done
result="$(python3 "$PUBLISH_TOOLING/ci/nightly_version.py" check-build --already-published-ok --build "$NIGHTLY_BUILD" "${feeds[@]}")"
printf '%s\n' "$result"
if [ "$(tail -n 1 <<< "$result")" = already_published=true ]; then
  echo "::notice title=Nothing to publish::build $NIGHTLY_BUILD is already published; nothing to do"
  echo "already_published=true" >> "$GITHUB_OUTPUT"
fi
