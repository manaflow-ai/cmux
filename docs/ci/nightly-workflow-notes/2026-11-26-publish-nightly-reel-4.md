# nightly.yml: job `publish-nightly-reel`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The private-terms secret lives only in this environment, which admits only
the protected branches (main, feat-cmux-next, nightly-next).
