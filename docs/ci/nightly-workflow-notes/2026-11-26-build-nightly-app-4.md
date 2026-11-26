# nightly.yml: job `build-nightly-app`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Jobs publish-nightly needs that run beside this one; derived from the
needs graph by tests/test_nightly_stop_if_publish_doomed.py.
