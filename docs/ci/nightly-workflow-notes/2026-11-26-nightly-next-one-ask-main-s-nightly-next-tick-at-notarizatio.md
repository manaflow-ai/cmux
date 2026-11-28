# nightly.yml: job `nightly-next-one`, step "Ask main's nightly-next tick at notarization"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The next run sets up while this one notarizes. Why: docs/ci/nightly-workflow-notes.md#note-26
.publish-tooling is this commit's scripts: an older build tree may predate scripts/ci/timeout.sh.
