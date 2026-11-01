#!/usr/bin/env bash
# nightly.yml visual-gate-nightly: "Build the DEV app". Moved out of the workflow to keep nightly.yml under
# GitHub's workflow file size limit; the step's env: still sets every input.
# The same cmux-tui tree the signed build bundles, so the DEV app runs
# the daemon this nightly ships.
set -euo pipefail
export CMUX_NEXT_OPTCHAT_CHIEF_TARGET_DIR="$HOME/Library/Caches/cmux-ci-media/optchat-chief-target/${RUNNER_NAME:?}"
scripts/ci/media_build_app.sh "$GITHUB_WORKSPACE" "${TOUR_TAG}-head" "$RUNNER_TEMP/reload.out" app
