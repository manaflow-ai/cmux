# nightly.yml: job `build-sign-notarize-nightly`, step "Restore pinned Node 22.23.4 from the CI cache bucket"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The signing keychain exists only while this job signs. It is deleted
before any step runs code from the bundle, and created again for the
DMG signature. scripts/ci/signing-keychain.sh owns its lifetime.
