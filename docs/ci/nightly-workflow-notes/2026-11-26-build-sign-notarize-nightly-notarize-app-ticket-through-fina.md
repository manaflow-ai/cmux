# nightly.yml: job `build-sign-notarize-nightly`, step "Notarize app ticket through final DMG"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Only a build that may publish hands a pending submission to a
later run; a notary test waits here and is never continued.
