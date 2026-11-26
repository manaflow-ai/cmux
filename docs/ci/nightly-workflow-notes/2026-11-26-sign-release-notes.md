# nightly.yml `sign-release-notes`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `PUBLISHED_SHA: ${{ needs.published-build.outputs.published_sha }}`

The commit published before this run (decide reads it from the release
body before publish-nightly moves the nightly-next tag to HEAD_SHA).

## 2

Above: `- *wait-through-github-api-rate-l`

Only the published span: a full fetch of every branch and tag did not
finish inside this job's timeout (run 37526646874).
The span starts at the newest build whose signed notes were published (its "head"), not at
the last published app: a build whose notes failed to publish then loses no highlight to
the next one (2026-10-12: 3821558930001 had no notes and its highlights were never shown).

## 3

Above: `env:`

With the job token, for this step only, as "Fetch the published span" does: an anonymous
fetch shares the runner egress IP's anonymous limit and got 403s on 2026-11-26.
