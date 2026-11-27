# 2026-11-27-publish-nightly-reel-1

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-gcp-nightly-jit-x64' }}` (job `publish-nightly-reel`) in `.github/workflows/nightly.yml`.

A one-job JIT VM on purpose, in the tail only (after publish-release-notes): an ffmpeg render of up to 90 min
would hold the whole signing Mac (test_nightly_owned_minis_only.HOSTED_TAIL_JOBS).
