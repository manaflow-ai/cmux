# sign-release-notes: *wait-through-github-api-rate-l

Where: the `sign-release-notes` job in `.github/workflows/nightly.yml`, above `- *wait-through-github-api-rate-l`.

Only the published span: a full fetch of every branch and tag did not
finish inside this job's timeout (run 37526646874).
The span starts at the newest build whose signed notes were published (its "head"), not at
the last published app: a build whose notes failed to publish then loses no highlight to
the next one (2026-10-12: 3821558930001 had no notes and its highlights were never shown).
