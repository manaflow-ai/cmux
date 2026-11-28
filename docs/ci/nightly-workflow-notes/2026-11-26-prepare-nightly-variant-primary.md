# nightly.yml: job `prepare-nightly-variant-primary`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

No environment and no secrets. It runs no code from the bundle; the
theme picker regression and the sidecar handshake run on the signed app
in verify-signed-nightly. build-sign-notarize-nightly signs exactly the
app it uploads and runs no bundle code itself (#21024).
