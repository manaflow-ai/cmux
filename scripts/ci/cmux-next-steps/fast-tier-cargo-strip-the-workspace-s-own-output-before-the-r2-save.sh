#!/usr/bin/env bash
# cmux-next.yml fast-tier-cargo: "Strip the workspace's own output before the R2 save".
# Moved out of the workflow to keep cmux-next.yml under its size budget (tests/test_ci_workflow_file_size.py);
# the step's env: still sets every input, and the step runs it with `bash -e` as GitHub's default `bash -e {0}`
# ran the inline block.
set -euo pipefail
# Why: 2026-11-26-fast-tier-cargo-reuse.md
python3 -I scripts/blacksmith-testbox-source-mtimes.py record . cmux-tui/target/.cmux-testbox-source-mtimes.tsv
cargo metadata --no-deps --format-version 1 --manifest-path cmux-tui/Cargo.toml > "$RUNNER_TEMP/cargo-metadata.json"
python3 -I scripts/ci/cargo_target_strip.py cmux-tui/target --cargo-metadata "$RUNNER_TEMP/cargo-metadata.json" --keep ghostty-vt-sys
# Why: 2026-11-24-fast-tier-cargo-10.md
rm -rf "$REGISTRY/src"
du -sh cmux-tui/target "$REGISTRY" | tee -a "$GITHUB_STEP_SUMMARY"
