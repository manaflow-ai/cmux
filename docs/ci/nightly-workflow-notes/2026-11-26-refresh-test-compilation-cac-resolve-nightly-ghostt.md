# refresh-test-compilation-cache: resolve-nightly-ghostty-cli-helper:

Where: the `refresh-test-compilation-cache` job in `.github/workflows/nightly.yml`, above `resolve-nightly-ghostty-cli-helper:`.

Reuses an earlier nightly's helper when its inputs (Ghostty gitlink, which
pins Zig, plus the build and Zig version scripts) match this build commit,
so the helper job runs on Linux and no nightly waits on a macOS 15 runner.
Any lookup failure is a miss. scripts/ci/nightly_ghostty_helper_reuse.py.
