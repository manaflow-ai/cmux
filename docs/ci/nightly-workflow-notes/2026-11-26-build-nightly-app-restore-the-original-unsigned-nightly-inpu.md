# nightly.yml: job `build-nightly-app`, step "Restore the original unsigned nightly inputs"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

This restore is the only way a finished build reaches the feed: a refused artifact call waits
up to 30 minutes for the token's quota to come back instead of failing in seconds. Runs
43129190893 and 43139032769 (2026-11-12) threw away finished builds on one 403 each.
