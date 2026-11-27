#!/usr/bin/env bash
# cmux-next.yml dev-landing-place: "Place the compile".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -uo pipefail
# Why: 2026-11-24-dev-landing-place-1.md
git init -q --bare "$GAP_REPO"
timeout 60 git -C "$GAP_REPO" fetch -q --no-tags --filter=tree:0 --depth=300 \
  "$GAP_REMOTE" "$SHA" || echo "::warning::no history for the cache distances"
python3 -I scripts/ci/dev_landing_place.py >> "$GITHUB_OUTPUT"
