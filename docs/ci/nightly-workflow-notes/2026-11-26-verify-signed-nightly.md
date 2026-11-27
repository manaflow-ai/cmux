# nightly.yml: job `verify-signed-nightly`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

No environment and no secrets: this job verifies the signed app's static
artifacts and sidecar (#21024). Runtime behavior is covered by the
path-routed daemon/app integration lane. publish-nightly publishes this
run's build only when both verification jobs passed.
