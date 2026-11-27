# nightly.yml: job `nightly-next-one`, step "Refuse stray processes before secrets"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Nothing a build script, a dependency or the app started may still run once a secret is present
(refuse_stray_processes.py). Again before the publication secrets, after the steps that run the app.
