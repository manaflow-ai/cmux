# nightly.yml: job `build-sign-notarize-nightly`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

nightly-next is arm64 only, so its one matrix leg sets this; publish
waits for a later run when Apple had not accepted the build in time.
