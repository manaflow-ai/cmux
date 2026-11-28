# nightly.yml: job `refresh-compilation-cache`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

This job rebuilds the cache after the store drops it, so it runs cold
by design; scheduled run 35134963192 was cancelled at 45 minutes.
