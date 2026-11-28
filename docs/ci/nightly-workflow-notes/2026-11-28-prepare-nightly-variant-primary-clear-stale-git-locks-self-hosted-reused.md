# 2026-11-28-prepare-nightly-variant-primary-clear-stale-git-locks-self-hosted-reused

Where: `.github/workflows/nightly.yml`, job `prepare-nightly-variant-primary`, step "Clear stale git locks (self-hosted reused workspace)": above `ws="${GITHUB_WORKSPACE:-$PWD}"`.

Self-hosted macOS runners reuse the workspace. A job cancelled or killed mid-checkout can leave a stale .git/modules/*/index.lock that fails every later submodule checkout (e.g. ghostty). Clear them first.
