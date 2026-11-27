# nightly.yml: job `pick-nightly-sign-runner`, step "Pick an owned Mac for the verify jobs"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

As the build pick: unread runners (run 41335987427's 403 rate limit on the routing App) queue the
verify jobs on the watched owned pool, not blind on Blacksmith macOS.
