# nightly.yml: job `build-nightly-app`, step "Mint the glaeda read token for the unsigned restore"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The routing App's own budget, github.token as the fallback: every workflow's github.token shares
one hourly limit, and its 403s failed this restore in sign runs 43129190893 and 43139032769.
