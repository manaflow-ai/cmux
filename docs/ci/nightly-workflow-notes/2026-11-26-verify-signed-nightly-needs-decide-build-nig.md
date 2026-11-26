# verify-signed-nightly: needs: [decide, build-nightly-app, resolve-nightly-cmux-tui-client, build-sign-n

Where: the `verify-signed-nightly` job in `.github/workflows/nightly.yml`, above `needs: [decide, build-nightly-app, resolve-nightly-cmux-tui-client, build-sign-notarize-nightly, pic…`.

No environment and no secrets: this job verifies the signed app's static
artifacts and sidecar (#21024). Runtime behavior is covered by the
path-routed daemon/app integration lane. publish-nightly publishes this
run's build only when both verification jobs passed.
