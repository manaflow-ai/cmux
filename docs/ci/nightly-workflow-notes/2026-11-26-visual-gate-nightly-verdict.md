# nightly.yml `visual-gate-nightly-verdict`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `visual-gate-nightly-verdict:`

This Linux job records the visual verdict independently of publication. Visual coverage is
advisory so a queued or slow display runner can never hold the nightly feed.

## 2

Above: `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_NIGHTLY_MINI != '' && vars.CI_NIGHTLY`

The declared nightly-only mini is enabled after live admission is verified.
Keep the existing fallback; never reuse the stale builder-only placement.
