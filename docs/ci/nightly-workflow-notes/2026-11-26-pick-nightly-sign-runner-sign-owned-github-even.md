# pick-nightly-sign-runner: sign_owned: ${{ (github.event_name == 'push' && github.run_attempt == 1 || steps

Where: the `pick-nightly-sign-runner` job in `.github/workflows/nightly.yml`, above `sign_owned: ${{ (github.event_name == 'push' && github.run_attempt == 1 || steps.upload-marker.outco…`.

A drained (or draining) owned Mac for the release signing jobs, as the JSON runs-on
array scripts/ci/signing_runner.py prints, or empty, under the same marker and `attempt` rules as `owned`.
