# nightly.yml: job `publish-nightly-next-github`, step "Checkout publish ref"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Only the source archive reads the build's tree; every other step runs .publish-tooling. The full
checkout took 2 min of the whole Mac on run 42018687632, whose archive step was off.
