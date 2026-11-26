# prepare-nightly-variant-primary: needs: [decide, build-nightly-ghostty-cli-helper, build-nightly-app, build-night

Where: the `prepare-nightly-variant-primary` job in `.github/workflows/nightly.yml`, above `needs: [decide, build-nightly-ghostty-cli-helper, build-nightly-app, build-nightly-remote-daemon, re…`.

No environment and no secrets. It runs no code from the bundle; the
theme picker regression and the sidecar handshake run on the signed app
in verify-signed-nightly. build-sign-notarize-nightly signs exactly the
app it uploads and runs no bundle code itself (#21024).
