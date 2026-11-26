# nightly.yml: job `attest-nightly-remote-daemon`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Provenance is advisory, as it was inside the app job. No publishing job
needs this job: a quota wait must not delay the feed.
