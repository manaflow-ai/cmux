# nightly.yml: job `promote-nightly-next-acked`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Holds only the release App credentials (CMUX_RELEASE_APP_*). The approval
was given to release-surface-ack on this run; guard.approvedBy() reads it.
