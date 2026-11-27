# 2026-11-27-build-nightly-ghostty-cli-helper-5

Above `overwrite: true` (job `build-nightly-ghostty-cli-helper`) in `.github/workflows/nightly.yml`.

A re-run of pick-nightly-build-runner re-runs this job after a success
(owned_pool_rescue.repick_job()); its second upload replaces the first.
