# The fast tier (cargo) off a warm target: the per-commit R2 workspace delta

Above `Restore the workspace delta from R2`, `Pack the workspace delta` and `Strip the workspace's own output before the R2 save`
(job `fast-tier-cargo`) in `.github/workflows/cmux-next.yml`.

The fast tier's runner label is served by persistent pool runners (a kept target, scripts/ci/pool-warm-target.sh) and by
Freestyle runners (`fsr-*`), which have neither a kept target nor a sticky disk. On those, the R2 entry held dependencies only
(note-210b), so every job compiled the whole workspace: job 140177341071 (2026-11-26, fsr-1795728132-78ced5-j3) spent 9 min on
setup, restored the dependency entry by prefix in 75 s, recompiled 26 dependencies and 118 workspace crates and hit the
30-minute timeout. 15Z to 21Z that day the job ran 130 times on `fsr-*`: 97 cancelled at the timeout (3,147 min), 3 passed; on
the pool, 2 of 99 were cancelled. That is the largest share of cancelled-after-start runner time in the NOW census.

Two fixes. First, the job now restores and applies the newest workspace delta, as the cmux-tui package legs do
(docs/ci/cmux-next-workflow-notes/2026-11-26-cargo-target-delta.md), with TRIPLE `host`: the fast tier builds for the machine
it runs on, so the delta keeps the real CPU fingerprint and apply drops native-CPU build output made on another CPU. Second,
the feat-cmux-next push saves the dependency entry and the delta once the build has run, whether its tests passed or not: a red
test leaves a correct build behind, and with the base red for hours (0 of 5 pushes green 15Z to 21Z) the success-only gate meant
no save, so every Freestyle job started from an older lockfile's entry. A cancelled or timed-out job still saves nothing.
Correctness never rests on either entry: a changed source keeps a fresh mtime and Cargo rebuilds it.
Test: scripts/ci/tests/cargo-target-delta.test.sh.
