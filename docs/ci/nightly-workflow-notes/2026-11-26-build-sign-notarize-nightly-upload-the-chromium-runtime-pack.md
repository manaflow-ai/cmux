# nightly.yml: job `build-sign-notarize-nightly`, step "Upload the Chromium runtime pack"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The runtime pack the app's pin names; publish-nightly uploads it
before the appcast.
