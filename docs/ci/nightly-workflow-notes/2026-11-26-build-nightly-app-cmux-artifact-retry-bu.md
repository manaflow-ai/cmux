# build-nightly-app: CMUX_ARTIFACT_RETRY_BUDGET_SECONDS: "1800"

Where: the `build-nightly-app` job in `.github/workflows/nightly.yml`, above `CMUX_ARTIFACT_RETRY_BUDGET_SECONDS: "1800"`.

This restore is the only way a finished build reaches the feed: a refused artifact call waits
up to 30 minutes for the token's quota to come back instead of failing in seconds. Runs
43129190893 and 43139032769 (2026-11-12) threw away finished builds on one 403 each.
