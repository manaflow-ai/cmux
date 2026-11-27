# nightly.yml: job `visual-gate-nightly-verdict`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

This Linux job records the visual verdict independently of publication. Visual coverage is
advisory so a queued or slow display runner can never hold the nightly feed.
