# nightly.yml: job `build-nightly-app`, step "Sanitize Swift package cache"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Only after the restore above. The warm builder's kept checkouts carry this workspace's own
paths; dropping their state re-fetched every package (32-222 s, runs 41444184160, 41439348303).
