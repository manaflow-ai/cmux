#!/usr/bin/env bash
# nightly.yml publish-nightly-identity-legacy: "Read the old feed back". The old feed is what
# cmux NIGHTLY (com.cmuxterm.app.nightly) reads; checked as publish-next-feed-readback.sh checks
# the cmux NEXT feed. Moved out of the workflow to keep nightly.yml under its size limit.
#
# The step's notes, moved from nightly.yml:
# Last: the attempt accounting above reads steps.publish, not this.
set -euo pipefail
python3 scripts/ci/nightly_next_live_feed_check.py --feed-url "${NIGHTLY_NEXT_LEGACY_FEED_BASE}/${LEGACY_APPCAST}" \
  --build "$NIGHTLY_BUILD" --dev-ring "$DEV_RING" --before "$RUNNER_TEMP/old-feed.xml"
