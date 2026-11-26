# nightly.yml `publish-release-notes`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `needs: [published-build, sign-release-notes, pick-nightly-sign-runner]`

Still publish-nightly's lock: the notes writes (notes/index.json and the
rest) have no compare-and-swap, so only that lock keeps an older build's
checked notes from landing after a newer publish. It is publish-nightly's
R2 lease, not a concurrency group: a group cancelled the older pending job
(run 41436891188). nightly-next only (if:), so no group at all.

## 2

Above: `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-gcp-nightly-jit-x64' }}`

A one-job JIT VM on purpose, in the tail only (after sign-release-notes): up to 130 min of lease and rate-limit
waits would hold the whole signing Mac (test_nightly_owned_minis_only.HOSTED_TAIL_JOBS).

## 3

Above: `- *checkout-the-gh-token-wrapper`

The wrapper comes from the workflow commit: the build checkout may predate it.
The publication-tooling shape test_nightly_cmux_tui_resolve.py exempts: scripts only.
