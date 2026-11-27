#!/usr/bin/env bash
# nightly.yml publish-nightly: "Guard nightly-next publication". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# Before anything is published: every cmux-next appcast names only
# nightly-next downloads and the cmux-next Sparkle channel.
set -euo pipefail
for appcast in $NIGHTLY_FEEDS; do
  python3 "$PUBLISH_TOOLING/ci/nightly-next-guard.py" appcast "nightly-out/$appcast"
done
