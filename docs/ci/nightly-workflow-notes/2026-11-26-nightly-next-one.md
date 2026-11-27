# nightly.yml: job `nightly-next-one`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The signer label, a literal (one-mini mode too): no variable picks where signing secrets go. The pick only
narrows it to one signer runner; its pin always starts with the label. Why: docs/ci/nightly-workflow-notes.md#note-33
