# 2026-11-28-published-build-ci-routing-agent

Where: `.github/workflows/nightly.yml`, job `published-build`, step "ci-routing-agent": above `timeout-minutes: 70`.

Room for gh_budget_wait.sh's wait through a rate limit: tail run 45925996466 failed its one gh read on "API rate limit exceeded for installation" (HTTP 403), so build 4592220755201 shipped with no release notes.
