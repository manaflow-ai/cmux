# 2026-11-27-publish-nightly-4

Above `OWN_VERIFIED: ${{ needs.verify-signed-nightly.result }}` (job `publish-nightly`) in `.github/workflows/nightly.yml`.

verify-signed-nightly verified the macOS signer's app and verify-final-dmg-nightly the final DMG
(and its fresh-home launch smoke, which fails that job).
