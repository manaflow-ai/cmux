# 2026-11-27-publish-nightly-reel-2

Above `environment: pr-media` (job `publish-nightly-reel`) in `.github/workflows/nightly.yml`.

The private-terms secret lives only in this environment, which admits only
the protected branches (main, feat-cmux-next, nightly-next).
