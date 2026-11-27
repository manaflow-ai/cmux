# 2026-11-27-build-nightly-app-5

Above `timeout-minutes: 15` (job `build-nightly-app`) in `.github/workflows/nightly.yml`.

Usually 10-40 s. Run 45782377330 (2026-11-26) sat in this step 40+ min holding the signing Mac,
under only the job's 300 min; failing at 15 lets retry-nightly-next and the tick move on.
