# 2026-11-27-fast-tier-pool-miss-r2

Above `CMUX_POOL_WARM_TARGET_MISS_R2` in the step `Link this runner's warm cargo target` (job `fast-tier-cargo`) in
`.github/workflows/cmux-next.yml`.

Job 140356082768 (PR run 45953923217) took 21 min: the pool runner's kept target was empty (`pool warm target: miss
(no recorded build ...) (8.0K)`), `pool-warm-target.sh restore` still wrote `linked=true`, and every R2 cargo restore
step is gated on `linked != 'true'`, so 594 crates compiled cold. An empty pool tree now is not linked, so the R2
build (third-party crates plus the workspace delta) restores. Repo var `CI_FAST_TIER_POOL_MISS_R2=0` restores the
old behaviour.
