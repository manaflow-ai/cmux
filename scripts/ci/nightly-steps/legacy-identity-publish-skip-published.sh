#!/usr/bin/env bash
# nightly.yml publish-nightly-identity-legacy: "Skip a build the old feed already has". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
[[ "$NIGHTLY_BUILD" =~ ^[0-9]+$ ]] || { echo "invalid build '$NIGHTLY_BUILD'" >&2; exit 1; }
# The old feed may list a Dev build above its Nightly one, and a
# Nightly build older than that Dev build is still published. Skipped:
# a build the feed already lists, or one no newer than its newest
# Nightly item.
curl -fsSL --retry 3 -A "cmux-nightly-legacy/1" -o "$RUNNER_TEMP/old-feed.xml" "${NIGHTLY_NEXT_LEGACY_FEED_BASE}/${LEGACY_APPCAST}"
python3 scripts/ci/nightly_next_ring.py select --feed "$RUNNER_TEMP/old-feed.xml" --out "$RUNNER_TEMP/old-nightly.xml" --channel cmux-next >/dev/null
current="$(sed -n 's#.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*#\1#p' "$RUNNER_TEMP/old-nightly.xml" | sort -n | tail -1)"
if grep -q "<sparkle:version>${NIGHTLY_BUILD}</sparkle:version>" "$RUNNER_TEMP/old-feed.xml" \
   || { [ -n "$current" ] && [ "$NIGHTLY_BUILD" -le "$current" ]; }; then
  echo "skip=true" >> "$GITHUB_OUTPUT"
  echo "### Old feed already has build $NIGHTLY_BUILD or a newer Nightly ($current); not published again" >> "$GITHUB_STEP_SUMMARY"
else
  echo "skip=false" >> "$GITHUB_OUTPUT"
fi
