# nightly.yml: job `build-sign-notarize-nightly`, step "Stop before notarization (NIGHTLY_NEXT_NOTARY_PAUSED)"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The DMG needs the identity again. It runs no bundle code; notarize-nightly-dmg.sh deletes the keychain right after
the DMG signature, before static artifact verification.
