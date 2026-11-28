# nightly.yml: job `build-sign-notarize-nightly`, step "Notarize app ticket through final DMG"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Runtime checks for the stapled app and final DMG run in
verify-signed-nightly, a job without secrets.
