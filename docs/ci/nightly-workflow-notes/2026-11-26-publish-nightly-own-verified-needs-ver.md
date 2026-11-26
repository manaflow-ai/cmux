# publish-nightly: OWN_VERIFIED: ${{ needs.verify-signed-nightly.result }}

Where: the `publish-nightly` job in `.github/workflows/nightly.yml`, above `OWN_VERIFIED: ${{ needs.verify-signed-nightly.result }}`.

verify-signed-nightly verified the macOS signer's app and verify-final-dmg-nightly the final DMG
(and its fresh-home launch smoke, which fails that job).
