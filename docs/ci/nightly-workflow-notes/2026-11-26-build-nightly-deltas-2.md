# nightly.yml: job `build-nightly-deltas`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Publication tooling at the workflow commit: it has the keyless mode even when the build commit predates
it, and it ships no source (only scripts/, into .publish-tooling).
