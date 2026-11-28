# 2026-11-26-attest-nightly-remote-daemon-2

Above `- name: Wait for API budget before the daemon attestation` (job `attest-nightly-remote-daemon`) in `.github/workflows/nightly.yml`.

Provenance is for `gh attestation verify`; no nightly step reads it. Persisting it spends the shared
installation API budget (spent Oct 25-26: six runs threw a finished build away), so wait (bounded)
for 200 calls, try, wait once more, retry, and on a second refusal ship with a warning.

## nightly.yml: job `attest-nightly-remote-daemon`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Provenance is advisory, as it was inside the app job. No publishing job
needs this job: a quota wait must not delay the feed.
