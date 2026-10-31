#!/usr/bin/env bash
# nightly.yml sign-nightly-identity-legacy: "Skip a build the old feed already has". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
set -euo pipefail
[[ "$NIGHTLY_BUILD" =~ ^[0-9]+$ ]] || { echo "invalid build '$NIGHTLY_BUILD'" >&2; exit 1; }
# The same rule as the publish job's: skipped is a build the feed
# already lists, or one no newer than its newest Nightly item. A Dev
# item above it does not hold back an older Nightly build.
curl -fsSL --retry 3 -A "cmux-nightly-legacy/1" -o "$RUNNER_TEMP/old-feed.xml" "${NIGHTLY_NEXT_LEGACY_FEED_BASE}/${LEGACY_APPCAST}"
python3 scripts/ci/nightly_next_ring.py select --feed "$RUNNER_TEMP/old-feed.xml" --out "$RUNNER_TEMP/old-nightly.xml" --channel cmux-next >/dev/null
current="$(sed -n 's#.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*#\1#p' "$RUNNER_TEMP/old-nightly.xml" | sort -n | tail -1)"
echo "old feed Nightly build: ${current:-none}; requested: $NIGHTLY_BUILD"
echo "### cmux NIGHTLY-identity requirement in use: required: ${REQUIRED:-none}" >> "$GITHUB_STEP_SUMMARY"
if grep -q "<sparkle:version>${NIGHTLY_BUILD}</sparkle:version>" "$RUNNER_TEMP/old-feed.xml" \
   || { [ -n "$current" ] && [ "$NIGHTLY_BUILD" -le "$current" ]; }; then
  echo "skip=true" >> "$GITHUB_OUTPUT"
  echo "### Old feed already at $current; build $NIGHTLY_BUILD skipped" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi
# Superseded: a new submission of a build older than the cmux NEXT feed's newest Nightly build. The
# run that published that newer build (or a later run's legacy-identity-target, which takes the
# newest) signs it for the old feed, so this one would only cost a Mac and Apple's queue: runs
# 40935345693, 40936301031 and 40940370080 queued their legacy signs 30-60 min for builds already
# behind the NEXT feed. A continuation (LEGACY_ACTION=continue) only asks Apple about a submission
# already made and is kept. A feed that cannot be read skips nothing.
if [ "${LEGACY_ACTION:-}" = new ] && [ -n "${NIGHTLY_NEXT_FEED_BASE:-}" ] \
   && curl -fsSL --retry 3 -A "cmux-nightly-legacy/1" -o "$RUNNER_TEMP/next-feed.xml" "${NIGHTLY_NEXT_FEED_BASE}/${LEGACY_APPCAST}" \
   && python3 scripts/ci/nightly_next_ring.py select --feed "$RUNNER_TEMP/next-feed.xml" --out "$RUNNER_TEMP/next-nightly.xml" --channel cmux-next >/dev/null; then
  newest="$(sed -n 's#.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*#\1#p' "$RUNNER_TEMP/next-nightly.xml" | sort -n | tail -1)"
  echo "cmux NEXT feed Nightly build: ${newest:-none}"
  if [ -n "$newest" ] && [ "$NIGHTLY_BUILD" -lt "$newest" ]; then
    echo "skip=true" >> "$GITHUB_OUTPUT"
    echo "### cmux NEXT already serves build $newest; build $NIGHTLY_BUILD is superseded, not submitted" >> "$GITHUB_STEP_SUMMARY"
    exit 0
  fi
fi
echo "skip=false" >> "$GITHUB_OUTPUT"
