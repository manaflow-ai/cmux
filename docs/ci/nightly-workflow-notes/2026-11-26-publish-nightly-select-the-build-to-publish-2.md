# nightly.yml: job `publish-nightly`, step "Select the build to publish"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

verify-signed-nightly verified the macOS signer's app and verify-final-dmg-nightly the final DMG
(and its fresh-home launch smoke, which fails that job).
