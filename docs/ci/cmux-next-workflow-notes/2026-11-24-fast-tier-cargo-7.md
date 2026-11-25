# 2026-11-24-fast-tier-cargo-7

Above the step `Key the cargo build in R2` (job `fast-tier-cargo`) in `.github/workflows/cmux-next.yml`.

Off Blacksmith the GitHub store above always misses (it is full and churns in minutes), so the
compiled dependencies come from R2 instead. Why: docs/ci/cmux-next-workflow-notes.md#note-210b
Skipped, with its restores and saves, when the warm target above is linked: cargo then builds in
that tree (CARGO_TARGET_DIR), which keeps the dependencies, and cmux-tui/target stays empty.
