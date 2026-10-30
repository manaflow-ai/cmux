#!/usr/bin/env bash
# nightly.yml visual-gate-nightly: "Bound the tour DerivedData on this Mac". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
set -e  # the inline step ran under bash -e
python3 scripts/ci/prune_media_derived_data.py \
  --keep-tag "${TOUR_TAG}-base" --keep-tag "${TOUR_TAG}-head" \
  --slots "${CMUX_MEDIA_TOUR_SLOTS:-2}" --keep-others 0
