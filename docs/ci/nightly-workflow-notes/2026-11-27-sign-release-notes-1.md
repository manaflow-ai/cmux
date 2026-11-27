# 2026-11-27-sign-release-notes-1

Above `PUBLISHED_SHA: ${{ needs.published-build.outputs.published_sha }}` (job `sign-release-notes`) in `.github/workflows/nightly.yml`.

The commit published before this run (decide reads it from the release
body before publish-nightly moves the nightly-next tag to HEAD_SHA).
