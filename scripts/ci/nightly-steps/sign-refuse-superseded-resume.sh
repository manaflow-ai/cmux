#!/usr/bin/env bash
# nightly.yml build-sign-notarize-nightly: "Refuse a resumed build superseded by a published feed". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input. An unsigned resume
# checks out an older build commit, so the step runs this script from .nightly-signing-control when that tree lacks it.
set -euo pipefail
feeds=()
for appcast in appcast.xml appcast-arm64.xml appcast-x86_64.xml; do
  feeds+=(--feed-if-present "${NIGHTLY_NEXT_FEED_BASE}/${appcast}" --feed "${NIGHTLY_NEXT_LEGACY_FEED_BASE}/${appcast}" --feed "https://files.cmux.com/nightly/${appcast}")
done
python3 scripts/ci/nightly_version.py check-build --build "$NIGHTLY_BUILD" "${feeds[@]}"
