# nightly.yml: job `build-sign-notarize-nightly`, step "Download the cmux-next source archive for recovery"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

A later run publishes this build from the recovery artifact alone, so
it also carries the SSH daemon assets and, when published, the source
archive (their own artifacts expire after 3 days).
