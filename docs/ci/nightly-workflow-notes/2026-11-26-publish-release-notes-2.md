# nightly.yml: job `publish-release-notes`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

A one-job JIT VM on purpose, in the tail only (after sign-release-notes): up to 130 min of lease and rate-limit
waits would hold the whole signing Mac (test_nightly_owned_minis_only.HOSTED_TAIL_JOBS).
