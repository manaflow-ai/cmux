# 2026-11-27-build-sign-notarize-nightly-15

Above `CMUX_NOTARY_PENDING_ON_TIMEOUT: ${{ needs.decide.outputs.track == 'nightly-next' && needs.decide.outputs.should_publish == 'true' && needs.decide.outputs.no_publish != 'true' && 'true' || 'false' }}` (job `build-sign-notarize-nightly`) in `.github/workflows/nightly.yml`.

Only a build that may publish hands a pending submission to a
later run; a notary test waits here and is never continued.
