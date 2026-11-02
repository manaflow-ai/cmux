#!/usr/bin/env bash
# nightly.yml publish-nightly: "Hand the published feed to the GitHub release job". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# What publish-nightly-next-github publishes to the release: the feed as it went
# live and the release body's PR list.
set -euo pipefail
mkdir -p next-github
for feed in $NIGHTLY_FEEDS; do cp "nightly-out/$feed" next-github/; done
if [ -s "$RUNNER_TEMP/nightly-prs.md" ]; then cp "$RUNNER_TEMP/nightly-prs.md" next-github/; fi
