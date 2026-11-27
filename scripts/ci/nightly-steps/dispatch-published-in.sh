#!/usr/bin/env bash
# nightly.yml dispatch-published-in: "Ask for this build's post-publication run". Moved out of the workflow (size budget).
# Why: docs/ci/nightly-workflow-notes/2026-11-26-dispatch-published-in-1.md
set -uo pipefail
started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ask() { gh workflow run nightly.yml --repo "$GITHUB_REPOSITORY" --ref "$GITHUB_REF_NAME" \
  -f nightly_next_post_publish="$(cat "$RUNNER_TEMP/dispatch-input.json")" 2>"$RUNNER_TEMP/dispatch.err"; }
ask && exit 0
cat "$RUNNER_TEMP/dispatch.err" >&2
grep -qE 'HTTP 5[0-9][0-9]|twirp error resource_exhausted' "$RUNNER_TEMP/dispatch.err" || exit 1
sleep 30
n="$(gh run list --repo "$GITHUB_REPOSITORY" --workflow nightly.yml --event workflow_dispatch --branch "$GITHUB_REF_NAME" \
  --created ">=$started" --json displayTitle \
  --jq '[.[] | select(.displayTitle | startswith("Finish a published nightly-next build"))] | length')" || n=0
[ "${n:-0}" -gt 0 ] 2>/dev/null && { echo "A tail run started despite the error."; exit 0; }
ask || { cat "$RUNNER_TEMP/dispatch.err" >&2; exit 1; }
