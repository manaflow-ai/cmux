# nightly.yml: job `decide`, step "Mint a spare read token for decide"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

A second budget for decide's reads: GITHUB_TOKEN draws on the repository's Actions installation, which
every cmux workflow shares and which ran dry at 01:22Z on 2026-11-21 (run 44849687076). The glaeda-route
App is a separate installation with its own hourly budget. Optional: decide waits for the reset without it.
