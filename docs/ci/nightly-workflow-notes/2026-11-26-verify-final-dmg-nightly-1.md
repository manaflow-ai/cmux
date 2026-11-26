# 2026-11-26-verify-final-dmg-nightly-1

Above `needs: [decide, build-nightly-app, resolve-nightly-cmux-tui-client, build-sign-notarize-nightly, pick-nightly-sign-runner]` (job `verify-final-dmg-nightly`) in `.github/workflows/nightly.yml`.

The final-DMG half of verify-signed-nightly, on its own runner so the two
halves run at the same time (each statically verifies an artifact with the same bundle
id, so they cannot share one runner). No environment and no secrets:
this job statically verifies the final DMG (#21024). publish-nightly
publishes this run's build only when both jobs passed, and only the DMG
bytes this job verified.
