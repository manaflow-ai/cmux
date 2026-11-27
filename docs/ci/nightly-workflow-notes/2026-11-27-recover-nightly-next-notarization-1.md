# 2026-11-27-recover-nightly-next-notarization-1

Above `timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && 270 || 150 }}` (job `recover-nightly-next-notarization`) in `.github/workflows/nightly.yml`.

An accepted continuation builds, signs and notarizes the DMG around the
stapled app (notarize-nightly-dmg.sh, CMUX_STAPLE_APP_IN_DMG): a 20m wait
and packaging per candidate; a failed one moves on to the next of 3.
