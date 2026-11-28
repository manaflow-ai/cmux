# nightly.yml: job `build-nightly-deltas`, step "Download published variant"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Under the runner's temp directory: the checkout above cleans only .publish-tooling, and this
mini keeps its workspace between jobs.
