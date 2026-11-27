# 2026-11-27-prepare-nightly-variant-5

Above `- *record-prepared-app-digest` (job `prepare-nightly-variant`) in `.github/workflows/nightly.yml`.

nightly-sign.yml (run from main) reads this annotation of this job
through the checks API and refuses a tarball with another sha256.
