# nightly.yml `retry-nightly-next`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `- name: Read scripts/ci from the host's git mirror`

The retry runs after a failure that is often GitHub refusing this host's git traffic (run 45744507889:
actions/checkout got 403 here too). On an owned Mac, scripts/ci comes from the host's git mirror (fetched
every minute by its one fetcher), with no github.com git fetch; actions/checkout only when it lacks SHA.
