# 2026-11-24-fast-tier-cargo-7

Above the step `Key the cargo build in R2` (job `fast-tier-cargo`) in `.github/workflows/cmux-next.yml`.

Off Blacksmith the GitHub store above always misses (it is full and churns in minutes), so the
compiled dependencies come from R2 instead. Why: docs/ci/cmux-next-workflow-notes.md#note-210b
Skipped, with its restores and saves, when the warm target above is linked: cargo then builds in
the kept tree (cmux-tui/target on the pool, CARGO_TARGET_DIR on a sticky disk), which keeps the
dependencies. A pool miss runs it: R2's third-party crates instead of a cold build.
