# 2026-11-28-published-build-ci-routing-agent-2

Where: `.github/workflows/nightly.yml`, job `published-build`, step "ci-routing-agent": above `GH_TOKEN_SPARES: ${{ secrets.CI_POOL_TOKEN_1 }} ${{ secrets.CI_POOL_TOKEN_2 }}`.

A second path for every gh call (c-bedbdb1917): a refused github.token hour moves to a CI pool's own hour at once (gh_budget_wait.sh); a write the read-only pool cannot do goes back and waits as before.
