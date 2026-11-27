# 2026-11-27-pick-nightly-sign-runner-3

Above `sign_owned: ${{ (github.event_name == 'push' && github.run_attempt == 1 || steps.upload-marker.outcome == 'success') && steps.sign-owned.outputs.owned || '' }}` (job `pick-nightly-sign-runner`) in `.github/workflows/nightly.yml`.

A drained (or draining) owned Mac for the release signing jobs, as the JSON runs-on
array scripts/ci/signing_runner.py prints, or empty, under the same marker and `attempt` rules as `owned`.
