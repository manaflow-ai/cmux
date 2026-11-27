# nightly.yml: job `refresh-test-compilation-cache`, step "Bound DerivedData seed size"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

R2 only: a multi-gigabyte entry in the GitHub store evicts the seeds
above (#13160). A failure here never fails the seed.
