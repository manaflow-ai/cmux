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
# Only while the old feed is fresh: cmux NEXT publishes every ~10 min and a sign starts 20-40 min
# after legacy-identity-target picked its build, so every sign was superseded and the old feed sat
# at 4093446036501 for 28 hours (runs 41129836857..41138268545, 2026-10-30). Once the old feed's
# newest Nightly item is older than LEGACY_SUPERSEDE_MINUTES (or has no readable date), a build
# newer than it is signed; publish-nightly-identity-legacy's order check still refuses one the feed
# has passed. LEGACY_NOW_EPOCH is the tests' clock.
old_age_minutes="$(python3 -I - "$RUNNER_TEMP/old-nightly.xml" "${LEGACY_NOW_EPOCH:-}" <<'PY'
import email.utils, re, sys, time
items = re.findall(r"<item>.*?</item>", open(sys.argv[1]).read(), re.S)
def build(chunk):
    m = re.search(r"<sparkle:version>(\d+)</sparkle:version>", chunk)
    return int(m.group(1)) if m else -1
newest = max(items, key=build, default="")
m = re.search(r"<pubDate>([^<]+)</pubDate>", newest)
try:
    published = email.utils.parsedate_to_datetime(m.group(1)).timestamp() if m else None
except (TypeError, ValueError):
    published = None
now = float(sys.argv[2]) if sys.argv[2] else time.time()
print("" if published is None else int((now - published) // 60))
PY
)"
if [ -z "$old_age_minutes" ] || [ "$old_age_minutes" -ge "${LEGACY_SUPERSEDE_MINUTES:-60}" ]; then
  echo "old feed is stale (newest Nightly item ${old_age_minutes:-of unknown age} min old); a newer cmux NEXT build does not supersede build $NIGHTLY_BUILD"
  echo "skip=false" >> "$GITHUB_OUTPUT"
  exit 0
fi
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
