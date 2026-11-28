# 2026-11-28-build-nightly-deltas-ci-routing-agent

Where: `.github/workflows/nightly.yml`, job `build-nightly-deltas`, step "ci-routing-agent": above `- *wait-through-github-api-rate-l-2`.

2026-11-28 06:30Z (Finish run 46116773791): "Download published variant" died on the installation's spent hour, in the parallel downloader (no spare pool) and then in the action (no wait): the same pair publish-nightly already has.
