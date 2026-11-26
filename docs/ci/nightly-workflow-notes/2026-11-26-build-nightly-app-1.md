# 2026-11-26-build-nightly-app-1

Above `CMUX_ARTIFACT_RETRY_BUDGET_SECONDS: "1800"` (job `build-nightly-app`) in `.github/workflows/nightly.yml`.

This restore is the only way a finished build reaches the feed: a refused artifact call waits
up to 30 minutes for the token's quota to come back instead of failing in seconds. Runs
43129190893 and 43139032769 (2026-11-12) threw away finished builds on one 403 each.
