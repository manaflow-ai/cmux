#!/usr/bin/env bash
# nightly.yml publish-nightly-next-github: "Check this build is still the feed's newest". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
# Enter the mutable writer only while this build is still the newest on the live feed,
# so a run the feed already passed never queues behind (and replaces) a newer writer.
set -euo pipefail
live="$(mktemp)"
curl -fsSL --retry 5 --retry-all-errors -A "cmux-nightly-next-github/1" -H "Cache-Control: no-cache" \
  -o "$live" "${NIGHTLY_NEXT_FEED_BASE}/appcast-arm64.xml?github=${GITHUB_RUN_ID}"
newest="$(python3 -I -c 'import re,sys; print(max([int(v) for v in re.findall(r"<sparkle:version>\s*(\d+)\s*</sparkle:version>", open(sys.argv[1]).read())] or [0]))' "$live")"
if (( newest != NIGHTLY_BUILD )); then
  echo "The feed serves build $newest, not this run's build $NIGHTLY_BUILD: the release's names stay as that run writes them."
  echo "newest=false" >> "$GITHUB_OUTPUT"
else
  echo "newest=true" >> "$GITHUB_OUTPUT"
fi
