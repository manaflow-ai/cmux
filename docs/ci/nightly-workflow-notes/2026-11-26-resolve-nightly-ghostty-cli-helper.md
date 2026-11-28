# nightly.yml: job `resolve-nightly-ghostty-cli-helper`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Reuses an earlier nightly's helper when its inputs (Ghostty gitlink, which
pins Zig, plus the build and Zig version scripts) match this build commit,
so the helper job runs on Linux and no nightly waits on a macOS 15 runner.
Any lookup failure is a miss. scripts/ci/nightly_ghostty_helper_reuse.py.
