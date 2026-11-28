# nightly.yml: job `build-nightly-ghostty-cli-helper`, step "Upload Ghostty CLI helper (retry)"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

A re-run of pick-nightly-build-runner re-runs this job after a success
(owned_pool_rescue.repick_job()); its second upload replaces the first.
