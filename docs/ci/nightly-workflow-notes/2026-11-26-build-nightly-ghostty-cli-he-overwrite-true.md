# build-nightly-ghostty-cli-helper: overwrite: true

Where: the `build-nightly-ghostty-cli-helper` job in `.github/workflows/nightly.yml`, above `overwrite: true`.

A re-run of pick-nightly-build-runner re-runs this job after a success
(owned_pool_rescue.repick_job()); its second upload replaces the first.
