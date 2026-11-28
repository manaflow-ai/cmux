# 2026-11-28-build-sign-notarize-nightly-generate-sparkle-appcasts-nightly

Where: `.github/workflows/nightly.yml`, job `build-sign-notarize-nightly`, step "Generate Sparkle appcasts (nightly)": above `if [ "$TRACK" = nightly-next ] && [ -f scripts/ci/nightly-steps/appcast-with-nearest-deltas.sh ]; th`.

nightly-next ships the deltas from its nearest earlier builds with the build itself (hq#13299). A build tree from before it has no script: that build publishes full-only, as before.
