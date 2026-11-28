# nightly.yml: job `build-nightly-app`, step "Retain unsigned resume provenance (retry)"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

A persistent owned mini keeps the workspace between jobs. Checkout's
clean drops untracked output; remove the daemon handoff here too.
