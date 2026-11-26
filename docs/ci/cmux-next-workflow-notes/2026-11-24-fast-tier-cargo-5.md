# 2026-11-24-fast-tier-cargo-5

Above the step `Link this runner's warm cargo target` (job `fast-tier-cargo`) in `.github/workflows/cmux-next.yml`.

A run that never writes the disk links it only when a feat-cmux-next run recorded a tree there;
an empty disk would be a cold build where rust-cache holds the third-party crates.

On the pool it claims this VM's kept tree into cmux-tui/target (a rename) and says linked only on
a hit; a miss leaves cmux-tui/target to the R2 restore below, and keep=true has the record step keep
that tree. Keyed by RUNNER_NAME it hit 35 of 539 jobs (w76-w83), and each miss compiled all 576
units from nothing with R2 skipped (job 139441164430: 14 min 44 s of cargo).
