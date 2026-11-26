# nightly.yml `resolve-nightly-ghostty-cli-helper`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `resolve-nightly-ghostty-cli-helper:`

Reuses an earlier nightly's helper when its inputs (Ghostty gitlink, which
pins Zig, plus the build and Zig version scripts) match this build commit,
so the helper job runs on Linux and no nightly waits on a macOS 15 runner.
Any lookup failure is a miss. scripts/ci/nightly_ghostty_helper_reuse.py.
