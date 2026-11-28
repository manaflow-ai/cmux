# nightly.yml: job `sign-release-notes`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The commit published before this run (decide reads it from the release
body before publish-nightly moves the nightly-next tag to HEAD_SHA).
