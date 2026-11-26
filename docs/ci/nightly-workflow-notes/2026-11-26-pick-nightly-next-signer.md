# nightly.yml `pick-nightly-next-signer`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `- name: Mint a spare read token for the pick`

The glaeda-route App's read-only token, as decide mints it on the same runner: its own hourly budget. With
github.token alone the shared budget ran dry and the pick fell back to cmux15 (run 45575194160: HTTP 403), so
a second build waited 10.5 min behind the first. Optional: the pick falls back to github.token without it.
