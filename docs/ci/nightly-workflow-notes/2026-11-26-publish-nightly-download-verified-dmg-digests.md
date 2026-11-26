# nightly.yml: job `publish-nightly`, step "Download verified DMG digests"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Publish only the bytes that a job without secrets verified:
verify-final-dmg-nightly for this run's build, verify-recovered-nightly-next
for a continued one.
