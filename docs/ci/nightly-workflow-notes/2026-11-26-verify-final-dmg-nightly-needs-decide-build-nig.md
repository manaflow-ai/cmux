# verify-final-dmg-nightly: needs: [decide, build-nightly-app, resolve-nightly-cmux-tui-client, build-sign-n

Where: the `verify-final-dmg-nightly` job in `.github/workflows/nightly.yml`, above `needs: [decide, build-nightly-app, resolve-nightly-cmux-tui-client, build-sign-notarize-nightly, pic…`.

The final-DMG half of verify-signed-nightly, on its own runner so the two
halves run at the same time (each statically verifies an artifact with the same bundle
id, so they cannot share one runner). No environment and no secrets:
this job statically verifies the final DMG (#21024). publish-nightly
publishes this run's build only when both jobs passed, and only the DMG
bytes this job verified.
