# nightly.yml: job `publish-nightly`, step "Checkout publish ref"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Release App first, github.token as the fallback (scripts/ci/gh_app_token.sh): the App is
its own actor, so a limit that every workflow's github.token shares does not refuse it.
