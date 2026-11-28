# nightly.yml: job `build-sign-notarize-nightly`, step "Upload the language packs"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The language packs the app's pin names (language-packs.py); publish-nightly uploads
them before the appcast.
