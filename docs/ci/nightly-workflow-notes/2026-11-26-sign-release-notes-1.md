# 2026-11-26-sign-release-notes-1

Above `- *wait-through-github-api-rate-l` (job `sign-release-notes`) in `.github/workflows/nightly.yml`.

Only the published span: a full fetch of every branch and tag did not
finish inside this job's timeout (run 37526646874).
The span starts at the newest build whose signed notes were published (its "head"), not at
the last published app: a build whose notes failed to publish then loses no highlight to
the next one (2026-10-12: 3821558930001 had no notes and its highlights were never shown).
