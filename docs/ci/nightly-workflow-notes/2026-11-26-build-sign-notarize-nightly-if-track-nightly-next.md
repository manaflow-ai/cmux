# build-sign-notarize-nightly: if [ "$TRACK" = nightly-next ] && [ -f scripts/ci/nightly-steps/appcast-with-nea

Where: the `build-sign-notarize-nightly` job in `.github/workflows/nightly.yml`, above `if [ "$TRACK" = nightly-next ] && [ -f scripts/ci/nightly-steps/appcast-with-nearest-deltas.sh ]; th…`.

nightly-next ships the deltas from its nearest earlier builds with the build itself (hq#13299).
A build tree from before it has no script: that build publishes full-only, as before.
