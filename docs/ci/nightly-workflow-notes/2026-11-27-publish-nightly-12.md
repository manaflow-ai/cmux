# 2026-11-27-publish-nightly-12

Above `app-id: ${{ secrets.CMUX_RELEASE_APP_ID }}` (job `publish-nightly`) in `.github/workflows/nightly.yml`.

The release App (Contents + Workflows write only); its id and key
live only in the release and release-next environments.
