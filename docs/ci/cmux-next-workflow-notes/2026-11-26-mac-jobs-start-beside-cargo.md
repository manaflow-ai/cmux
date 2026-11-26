# 2026-11-26-mac-jobs-start-beside-cargo

Above `needs:` of `macos-placement` and `app-compile-placement` in `.github/workflows/cmux-next.yml`.

The two placements no longer `need` `fast-tier-cargo`, so every Mac job and the build fleet's app compile start
beside the cargo fast tier, not after it. #54731 (2026-11-25) added that edge so a pull request head red on cargo
never reached the Mac fleet; it was worth 8-12k Mac minutes a day while every head ran both.

Since then the PR fast tier (`vars.CI_PR_FAST_ONLY`, #55022, and the one-hop verdict note) defers the cargo tier
and every Mac job to the feat-cmux-next push run on a head into feat-cmux-next without full-ci, and push runs never
read the edge. The edge's only remaining effect was on full-ci heads, which run every tier and whose fail-fast
is off on purpose. There it put cargo's queue and run time in front of the head's compile verdict:

- cmux#57323 head de439752, run 45740955339 (full-ci, Swift-only diff, cargo forced only by the label): path
  routing finished at 02:15:08Z. `fast tier (cargo)` queued 27.5 min on the Freestyle Linux pool
  (`RUNNER_POOLS.linux_8`, cmux-freestyle-linux-x64) to 02:42:35Z, then ran into its 30-minute timeout and was
  cancelled at 03:12:55Z. Both placements skipped, and `cmux-next Release compile (Xcode 26)` started at 03:12:57Z.
  Its 1.8 min compile gave the verdict 61.4 min after the run was created.
- Without the edge, the Release compile starts once path routing and the placement have run (about +3 min), so
  that verdict lands at about +5 to +6 min. The cargo check still runs and still reports.

A cargo red on a head without full-ci still cancels the run through `fast-tier-cargo-fail-fast`
(`vars.CI_HEAD_FAIL_FAST`), which stops the Mac jobs it started. That case only arises when
`vars.CI_PR_FAST_ONLY=0` or the base is not feat-cmux-next. Cargo's queue is a capacity problem of the Linux pool
variable, outside this file. Cargo's run time is #58091 (warm target reuse) and #58042 (zig cache).
