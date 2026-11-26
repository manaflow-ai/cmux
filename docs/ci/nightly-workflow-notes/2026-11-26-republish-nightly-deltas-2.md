# nightly.yml: job `republish-nightly-deltas`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Optional, as generate-nightly-deltas: the full DMG is already on the feed, so a missing or failed delta
never fails the run.
