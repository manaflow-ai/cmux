# nightly.yml: job `pick-nightly-next-signer`, step "Mint a spare read token for the pick"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The glaeda-route App's read-only token, as decide mints it on the same runner: its own hourly budget. With
github.token alone the shared budget ran dry and the pick fell back to cmux15 (run 45575194160: HTTP 403), so
a second build waited 10.5 min behind the first. Optional: the pick falls back to github.token without it.
