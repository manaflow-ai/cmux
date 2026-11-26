# 2026-11-26-verify-signed-nightly-1

Above `needs: [decide, build-nightly-app, resolve-nightly-cmux-tui-client, build-sign-notarize-nightly, pick-nightly-sign-runner]` (job `verify-signed-nightly`) in `.github/workflows/nightly.yml`.

No environment and no secrets: this job verifies the signed app's static
artifacts and sidecar (#21024). Runtime behavior is covered by the
path-routed daemon/app integration lane. publish-nightly publishes this
run's build only when both verification jobs passed.
