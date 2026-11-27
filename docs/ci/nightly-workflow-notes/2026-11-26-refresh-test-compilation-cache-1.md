# 2026-11-26-refresh-test-compilation-cache-1

Above `resolve-nightly-ghostty-cli-helper:` (job `refresh-test-compilation-cache`) in `.github/workflows/nightly.yml`.

Reuses an earlier nightly's helper when its inputs (Ghostty gitlink, which
pins Zig, plus the build and Zig version scripts) match this build commit,
so the helper job runs on Linux and no nightly waits on a macOS 15 runner.
Any lookup failure is a miss. scripts/ci/nightly_ghostty_helper_reuse.py.
