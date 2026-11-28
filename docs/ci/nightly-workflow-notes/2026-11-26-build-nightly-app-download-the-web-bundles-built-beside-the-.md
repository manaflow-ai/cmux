# nightly.yml: job `build-nightly-app`, step "Download the web bundles built beside the app (cmux-next)"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

A pattern, not a name: an artifact that is not there yet downloads
nothing instead of failing.
