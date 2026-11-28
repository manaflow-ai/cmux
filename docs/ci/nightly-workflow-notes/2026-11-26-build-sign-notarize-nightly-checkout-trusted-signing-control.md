# nightly.yml: job `build-sign-notarize-nightly`, step "Checkout trusted signing controls"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

This run's own signing controls: the claim below and, for an unsigned resume, the keychain controls.
Only scripts/ and the workflow are read from it, so it is sparse: a fresh full clone into this path took
about 3 min of the one signer on every sign (run 41948676510, 04:42:55-04:46:05Z).
