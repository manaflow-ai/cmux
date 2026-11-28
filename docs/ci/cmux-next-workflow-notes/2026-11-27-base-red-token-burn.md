# 2026-11-27-base-red-token-burn

Above the step `Jobs red on the base right now` (job `path_route`) in `.github/workflows/cmux-next.yml`, and the
`Mint a read token with its own quota` step before it.

Both run only when the cargo fast tier is routed (`steps.route.outputs.fast_tier_cargo != 'false'`): the cargo job
is the one reader of `base_red_jobs`, and it already needs `fast_tier_cargo != 'false'`, so a PR that does not
route cargo gains nothing from the walk. The PR fast tier (`vars.CI_PR_FAST_ONLY`) defers cargo to the push run on
nearly every PR, and base push runs skip cargo too, so no decided verdict ended the walk early: each PR run read
the runs list plus up to 60 jobs pages (`--runs 60`) on `github.token`, about 61 REST calls, at about 8 PR runs a
minute. 2026-11-27 01:54-02:02Z the repository's 5000 calls an hour were gone about 8 min after the reset (step
34-36 s per run, then `HTTP 403 (rate limit left: 0)` on both tokens), and every floor-guarded job
(`scripts/ci/job_token_floor.py`) was held for the rest of the hour. Detector:
`tests/test_ci_base_red_skip.py` (`test_cmux_next_reads_the_base_only_when_cargo_is_routed`).
