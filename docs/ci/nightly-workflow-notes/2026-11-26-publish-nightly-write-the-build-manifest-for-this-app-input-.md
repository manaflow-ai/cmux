# nightly.yml: job `publish-nightly`, step "Write the build manifest for this app-input digest"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Clean-sheet CI RFD hq#26225: a write-once manifest per app-input digest beside the build. Nothing reads it yet;
it cannot fail or change the publish (the script exits 0 on any error, each call is time-bounded).
