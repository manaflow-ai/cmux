# 2026-11-28-nightly-next-one-wait-through-github-api-rate-limits-in-t

Where: `.github/workflows/nightly.yml`, job `nightly-next-one`, step "Wait through GitHub API rate limits in this job's gh calls": above `run: bash .publish-tooling/scripts/ci/gh_budget_wait.sh --install`.

This job has checked out the workflow's trusted publication tooling above. The split build job keeps its source-tree fallback because it has no .publish-tooling checkout.
