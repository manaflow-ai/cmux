# 2026-11-28-clear-stale-git-locks-self-hosted-reused-workspace

Where: `.github/workflows/nightly.yml`, Clear stale git locks (self-hosted reused workspace).

Self-hosted macOS runners reuse the workspace. A job cancelled or killed mid-checkout can leave a stale .git/modules/*/index.lock that fails every later submodule checkout (e.g. ghostty). Clear them first.
