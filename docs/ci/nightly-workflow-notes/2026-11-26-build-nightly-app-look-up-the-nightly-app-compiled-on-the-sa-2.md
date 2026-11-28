# nightly.yml: job `build-nightly-app`, step "Look up the nightly app compiled on the same inputs"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

A cold measurement run skips the restore; every gate below treats the
missing output like a cache miss, so the cold build still saves.
