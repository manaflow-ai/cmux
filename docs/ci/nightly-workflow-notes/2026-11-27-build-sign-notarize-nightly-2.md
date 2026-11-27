# 2026-11-27-build-sign-notarize-nightly-2

Above `notary_pending: ${{ steps.notarize-nightly.outputs.submission_pending }}` (job `build-sign-notarize-nightly`) in `.github/workflows/nightly.yml`.

nightly-next is arm64 only, so its one matrix leg sets this; publish
waits for a later run when Apple had not accepted the build in time.
