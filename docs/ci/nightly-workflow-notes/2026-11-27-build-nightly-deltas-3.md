# 2026-11-27-build-nightly-deltas-3

Above `path: ${{ runner.temp }}/nightly-delta/input` (job `build-nightly-deltas`) in `.github/workflows/nightly.yml`.

Under the runner's temp directory: the checkout above cleans only .publish-tooling, and this
mini keeps its workspace between jobs.
