# recover-nightly-next-notarization: timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && 270 || 150 }}

Where: the `recover-nightly-next-notarization` job in `.github/workflows/nightly.yml`, above `timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && 270 || 150 }}`.

An accepted continuation builds, signs and notarizes the DMG around the
stapled app (notarize-nightly-dmg.sh, CMUX_STAPLE_APP_IN_DMG): a 20m wait
and packaging per candidate; a failed one moves on to the next of 3.
