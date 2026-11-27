# nightly.yml: job `sign-release-notes`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Only the published span: a full fetch of every branch and tag did not
finish inside this job's timeout (run 37526646874).
The span starts at the newest build whose signed notes were published (its "head"), not at
the last published app: a build whose notes failed to publish then loses no highlight to
the next one (2026-10-12: 3821558930001 had no notes and its highlights were never shown).
