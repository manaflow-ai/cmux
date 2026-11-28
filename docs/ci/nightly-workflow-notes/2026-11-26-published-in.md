# nightly.yml: job `published-in`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

A paced job of up to five hours of GitHub API calls: it needs no Mac. On the nightly mini it held a Mac for
hours (Leo, 2026-11-25: "freeing up the Mac's from doing things that don't need Mac's asap"). Its token writes
pull requests, so never the shared persistent cmux-linux pool: the owned one-job JIT VM on every attempt, like
the other tail jobs (test_nightly_owned_minis_only.HOSTED_TAIL_JOBS). Tail only (run_tail), so a VM start never
holds the push group. Never Blacksmith.
