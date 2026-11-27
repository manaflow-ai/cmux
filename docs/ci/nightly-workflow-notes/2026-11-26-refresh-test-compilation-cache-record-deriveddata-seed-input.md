# nightly.yml: job `refresh-test-compilation-cache`, step "Record DerivedData seed inputs"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

ci-macos.yml compile admission adopts this build's DerivedData for pull
requests. The recorded content and times are how it tells which inputs
a later revision changed. See scripts/ci/seed_derived_data.py.
