# 2026-11-26-build-nightly-app-9

Above `- &x48` (job `build-nightly-app`) in `.github/workflows/nightly.yml`.

Every nightly-next build's dSYMs: sentry-dsyms-nightly uploads them, and keep-published-dsyms
keeps a published build's on R2 (Sentry reads 403'd, nightly 38005665577). 21 days: an
unsigned resume (7) plus notarization recovery (14). resume-unsigned-nightly.py reads
this artifact's name as the build's source commit.
