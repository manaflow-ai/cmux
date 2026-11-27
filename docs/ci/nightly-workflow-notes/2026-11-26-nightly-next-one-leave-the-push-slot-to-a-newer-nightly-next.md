# nightly.yml: job `nightly-next-one`, step "Leave the push slot to a newer nightly-next push"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Latest wins at the slot too, with no wait on this Mac: it asks main's tick and leaves; bounded gh calls,
never a rate-limit wait. Why: docs/ci/nightly-workflow-notes.md#note-16
