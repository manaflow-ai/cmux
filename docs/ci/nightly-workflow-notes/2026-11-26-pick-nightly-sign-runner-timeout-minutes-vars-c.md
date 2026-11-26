# pick-nightly-sign-runner: timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && 137 || 17 }}

Where: the `pick-nightly-sign-runner` job in `.github/workflows/nightly.yml`, above `timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && 137 || 17 }}`.

Room for every step budget in turn (the read token mint 1, the owned pick's token mints 1 + 1, the verify picker 2,
the signing picker 2 and the overtaken check 1) plus checkout, so the job is never cut off before its outputs.
