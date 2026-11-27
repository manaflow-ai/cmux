# 2026-11-27-build-sign-notarize-nightly-12

Above `NIGHTLY_SPARKLE_KEY: ${{ vars.NIGHTLY_SPARKLE_KEY }}` (job `build-sign-notarize-nightly`) in `.github/workflows/nightly.yml`.

scripts/ci/nightly-sparkle-key.sh picks the key per channel and
NIGHTLY_SPARKLE_KEY; unset keeps the shared key.
