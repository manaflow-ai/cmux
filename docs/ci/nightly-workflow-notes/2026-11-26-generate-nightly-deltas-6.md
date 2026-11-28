# nightly.yml: job `generate-nightly-deltas`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Every item starts on the new build's ring; republish-nightly-deltas
moves the ones whose canary passed back to Nightly.
