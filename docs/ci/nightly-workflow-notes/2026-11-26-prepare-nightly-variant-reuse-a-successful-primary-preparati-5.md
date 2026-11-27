# nightly.yml: job `prepare-nightly-variant`, step "Reuse a successful primary preparation"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

nightly-sign.yml (run from main) reads this annotation of this job
through the checks API and refuses a tarball with another sha256.
