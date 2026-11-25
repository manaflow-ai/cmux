# 2026-11-24-fast-tier-cargo-5

Above the step `Link this runner's warm cargo target` (job `fast-tier-cargo`) in `.github/workflows/cmux-next.yml`.

A run that never writes the disk links it only when a feat-cmux-next run recorded a tree there;
an empty disk would be a cold build where rust-cache holds the third-party crates.
