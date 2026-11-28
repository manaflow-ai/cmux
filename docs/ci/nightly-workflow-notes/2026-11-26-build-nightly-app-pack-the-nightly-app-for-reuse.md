# nightly.yml: job `build-nightly-app`, step "Pack the nightly app for reuse"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

A failed or cancelled job leaves no background helper build running.
The record a later build looks up; record=true only on a fresh VM that started clean.
