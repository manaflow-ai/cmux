# nightly.yml: job `await-release-surface-ack`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

A release-surface acknowledgement may wait, but it must never cancel
an older promotion that has already started. The starvation guard
coalesces newer tips after the running promotion finishes.
