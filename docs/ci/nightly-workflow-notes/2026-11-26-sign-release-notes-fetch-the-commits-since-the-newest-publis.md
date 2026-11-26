# nightly.yml: job `sign-release-notes`, step "Fetch the commits since the newest published notes"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

With the job token, for this step only, as "Fetch the published span" does: an anonymous
fetch shares the runner egress IP's anonymous limit and got 403s on 2026-11-26.
