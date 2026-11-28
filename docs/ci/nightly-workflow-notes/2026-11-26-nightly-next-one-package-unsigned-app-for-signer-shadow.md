# nightly.yml: job `nightly-next-one`, step "Package unsigned app for signer shadow"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Signer-service experiment (docs/design/signer-service.md, migration step 1).
It is shadow-only: the current in-job signing path remains authoritative, and
the upload is skipped unless the repository variable is explicitly `on`.
