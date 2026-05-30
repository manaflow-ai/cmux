# macOS CI runners

All paid macOS CI/CD jobs pick their runner from two repository variables instead of a hardcoded label:

- `MACOS_RUNNER_15` for macOS 15 jobs (most jobs, plus the e2e/perf defaults)
- `MACOS_RUNNER_26` for macOS 26 jobs (release, nightly, compat)

Workflows reference them as `runs-on: ${{ vars.MACOS_RUNNER_15 || 'blacksmith-6vcpu-macos-15' }}`. If a variable is unset, the job still uses Blacksmith.

## Blacksmith defaults

The defaults are checked into the workflows. The repo variables are an override layer and take effect on the next workflow run, with no PR or commit.

Use Blacksmith (default):

```bash
gh variable set MACOS_RUNNER_15 --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-15
gh variable set MACOS_RUNNER_26 --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-26
```

Remove the override and use the checked-in Blacksmith defaults:

```bash
gh variable delete MACOS_RUNNER_15 --repo manaflow-ai/cmux
gh variable delete MACOS_RUNNER_26 --repo manaflow-ai/cmux
```

Check current values:

```bash
gh variable list --repo manaflow-ai/cmux
```

## Manual runs

`perf-activation.yml` and `test-e2e.yml` keep a `runner` choice input that defaults to `auto`. `auto` (and the empty `pull_request` case for perf) follows `MACOS_RUNNER_15` then the checked-in Blacksmith default, so flipping the repo variable also redirects these workflows. An explicit choice wins over the variable. `test-e2e.yml` also keeps `depot-macos-*` choices and a Depot identity guard for GUI-activation runs.

## Guard

`tests/test_ci_self_hosted_guard.sh` (run by the `workflow-guard-tests` job) asserts every paid macOS job references `vars.MACOS_RUNNER_*` or a Blacksmith label, so a job can never silently fall back to a free GitHub-hosted runner. Keep new labels in `.github/actionlint.yaml`.
