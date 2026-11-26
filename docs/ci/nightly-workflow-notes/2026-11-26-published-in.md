# nightly.yml `published-in`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `published-in:`

Where the tail runs (run_tail): a dispatched tail run, or main's, RC's or a manual run's own. The comments
wait for the whole-Mac publish jobs, so they never hold the mini while those wait.

## 2

Above: `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-gcp-nightly-jit-x64' }}`

A paced job of up to five hours of GitHub API calls: it needs no Mac. On the nightly mini it held a Mac for
hours (Leo, 2026-11-25: "freeing up the Mac's from doing things that don't need Mac's asap"). Its token writes
pull requests, so never the shared persistent cmux-linux pool: the owned one-job JIT VM on every attempt, like
the other tail jobs (test_nightly_owned_minis_only.HOSTED_TAIL_JOBS). Tail only (run_tail), so a VM start never
holds the push group. Never Blacksmith.

## 3

Above: `timeout-minutes: 420`

Each write is paced at 7.5 s under GitHub's hourly content limit.
A shared edit plus a legacy deletion for all 1,000 allowed PRs takes
250 min; leave room for reads. This runs after publication.
