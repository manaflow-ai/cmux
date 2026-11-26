# 2026-11-26-prepare-nightly-variant-primary-1

Above `needs: [decide, build-nightly-ghostty-cli-helper, build-nightly-app, build-nightly-remote-daemon, resolve-nightly-cmux-tui-client]` (job `prepare-nightly-variant-primary`) in `.github/workflows/nightly.yml`.

No environment and no secrets. It runs no code from the bundle; the
theme picker regression and the sidecar handshake run on the signed app
in verify-signed-nightly. build-sign-notarize-nightly signs exactly the
app it uploads and runs no bundle code itself (#21024).
