# nightly.yml: job `retry-nightly-next`, step "Read scripts/ci from the host's git mirror"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The retry runs after a failure that is often GitHub refusing this host's git traffic (run 45744507889:
actions/checkout got 403 here too). On an owned Mac, scripts/ci comes from the host's git mirror (fetched
every minute by its one fetcher), with no github.com git fetch; actions/checkout only when it lacks SHA.
