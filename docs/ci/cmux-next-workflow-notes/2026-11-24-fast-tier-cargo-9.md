# 2026-11-24-fast-tier-cargo-9

Above the step `Strip the workspace's own output before the R2 save` (job `fast-tier-cargo`) in `.github/workflows/cmux-next.yml`.

A feat-cmux-next push off Blacksmith whose inputs R2 lacks saves them: dependencies only, as
rust-cache keeps (scripts/ci/cargo_target_strip.py). Why: docs/ci/cmux-next-workflow-notes.md#note-210b
