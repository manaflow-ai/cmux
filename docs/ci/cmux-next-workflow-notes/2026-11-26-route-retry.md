# 2026-11-26-route-retry

Above path_route's `timeout-minutes`, its first `actions/checkout` and the step `Jobs red on the base right now`
in `.github/workflows/cmux-next.yml`.

2026-11-25 from 12Z, path routing's checkout failed 702 times on a slow GitHub ("Operation too slow", "could not
fetch ... from promisor remote"; 8 failures on 11-24). A failed path_route leaves `base_red_jobs` empty, so the
base-red breaker failed open: cargo ran in full on PRs whose base was red, 2,211 min that day (fleet-data-raw
gh-jobs). The checkout now gets three tries of 3 min each, each from a fresh .git, with 20 s and 60 s waits
between them. The job bound grows from 8 to 15 min for those tries; a healthy run takes the same time as before.

Cargo still runs when all three tries fail. With path routing failed on 11-25, cargo found 107 reds of 303
finished runs on PRs whose base was green, so skipping it would let reds into the base.

The breaker step runs on `!cancelled()`, so a route step that fails after the checkout still decides.
`--runs 60`: 462 of 548 base push cargo rows were skipped on 11-25, so 12 runs often held no verdict and the PR ran.
