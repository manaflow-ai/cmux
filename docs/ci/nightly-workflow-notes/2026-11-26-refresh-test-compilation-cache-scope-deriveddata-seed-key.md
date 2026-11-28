# nightly.yml: job `refresh-test-compilation-cache`, step "Scope DerivedData seed key"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Seeds serve only the Swift job width they were built at; see
scripts/ci/seed_derived_data.py.
