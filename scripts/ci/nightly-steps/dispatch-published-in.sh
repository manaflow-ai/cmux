#!/usr/bin/env bash
# nightly.yml dispatch-published-in: "Ask for this build's post-publication run". Moved out of the workflow to keep
# nightly.yml under its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# At most three tries, 20 s and then 50 s apart: a lost dispatch left a published build with no release notes, PR
# list or PR comments. A dispatch GitHub accepted but answered with an error would start a second tail on a retry,
# so before each retry the step looks for a tail run created since its first try and stops when one exists.
# A refusal for the rate limit waits inside gh (gh_budget_wait.sh) and is one try.
set -euo pipefail
title="Finish a published nightly-next build (release, deltas, notes, PR comments)"
t0="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for try in 1 2 3; do
  if [ "$try" != 1 ]; then
    sleep $(( try == 2 ? 20 : 50 ))
    started="$(gh run list --repo "$GITHUB_REPOSITORY" --workflow nightly.yml --event workflow_dispatch \
      --created ">=$t0" --limit 20 --json displayTitle --jq "[.[] | select(.displayTitle == \"$title\")] | length" || echo 0)"
    if [ "${started:-0}" != 0 ]; then
      echo "A post-publication run started after try $((try - 1)); not dispatching another."
      exit 0
    fi
  fi
  if gh workflow run nightly.yml --repo "$GITHUB_REPOSITORY" --ref "$GITHUB_REF_NAME" \
      -f nightly_next_post_publish="$(cat "$RUNNER_TEMP/dispatch-input.json")"; then
    exit 0
  fi
  echo "::warning::dispatch try $try of 3 failed"
done
echo "::error::the post-publication run was not dispatched after three tries"
exit 1
