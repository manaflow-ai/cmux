#!/usr/bin/env bash
# nightly.yml published-in, called by published-in-comment-prs.sh ("Comment the build on its PRs"). Out of the workflow to keep
# nightly.yml under its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The comments go out only once the live feed offers this build (its pubDate is the "at" they show); a build
# the feed never offered within the wait gets none. With no published commit recorded (decide found none), the
# span starts at the commit of the feed's newest item below this build.
# Outputs (to $GITHUB_OUTPUT, which published-in-comment-prs.sh points at a file): moved=true|false, since=<sha>,
# at=<"YYYY-MM-DD HH:MM UTC">.
set -euo pipefail
feed="$NIGHTLY_NEXT_FEED_BASE/appcast-arm64.xml"
tries="${PUBLISHED_IN_FEED_TRIES:-10}" pause="${PUBLISHED_IN_FEED_PAUSE:-30}"
at=""
for try in $(seq 1 "$tries"); do
  at="$(python3 scripts/ci/nightly_version.py published-at --feed "$feed" --build "$NIGHTLY_BUILD" || true)"
  [ -n "$at" ] && break
  [ "$try" = "$tries" ] || sleep "$pause"
done
if [ -z "$at" ]; then
  echo "::notice::$feed does not offer build $NIGHTLY_BUILD; no PR comments for it"
  echo "moved=false" >> "$GITHUB_OUTPUT"
  exit 0
fi
since="${PUBLISHED_SHA:-}"
if [ -z "$since" ]; then
  since="$(python3 scripts/ci/nightly_version.py published-source --feed "$feed" --before "$NIGHTLY_BUILD" || true)"
  echo "No published commit recorded; the span starts at the feed's previous build: ${since:-none}"
fi
if [ -z "$since" ] || [ "$since" = "$HEAD_SHA" ]; then
  echo "Empty span."
  echo "moved=false" >> "$GITHUB_OUTPUT"
  exit 0
fi
./scripts/cmux-next/fetch-release-notes-span.sh origin "$HEAD_SHA" nightly-next "$since"
{ echo "moved=true"; echo "since=$since"; echo "at=$at"; } >> "$GITHUB_OUTPUT"
