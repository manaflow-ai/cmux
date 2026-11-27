# 2026-11-27-build-nightly-app-3

Above `timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && 270 || 150 }}` (job `build-nightly-app`) in `.github/workflows/nightly.yml`.

The cloud cache is scoped per branch and also drops main's own
entry (runs 35179030871 and 35182663752 restored nothing and were
cancelled at 45 minutes mid-compile), so the budget must fit a cold
build, not only a warm one.
