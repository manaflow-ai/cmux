# 2026-11-27-publish-release-notes-1

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-gcp-nightly-jit-x64' }}` (job `publish-release-notes`) in `.github/workflows/nightly.yml`.

A one-job JIT VM on purpose, in the tail only (after sign-release-notes): up to 130 min of lease and rate-limit
waits would hold the whole signing Mac (test_nightly_owned_minis_only.HOSTED_TAIL_JOBS).
