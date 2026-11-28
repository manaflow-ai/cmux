# nightly.yml: job `build-sign-notarize-nightly`, step "Restore pinned Node 22.23.4 from the CI cache bucket"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Each channel has its own Developer ID profile:
APPLE_NIGHTLY_PROVISIONING_PROFILE_BASE64 / APPLE_RC_PROVISIONING_PROFILE_BASE64.
