# macOS CI runners

All paid macOS CI/CD jobs pick their runner from two repository variables instead of a hardcoded label:

- `MACOS_RUNNER_15` for jobs that build the real universal Release app, including nightly, stable release, `release-build`, and the e2e/perf defaults.
- `MACOS_RUNNER_26` for macOS 26 compatibility coverage and jobs that do not need Zig to build the real universal Ghostty CLI helper.

Workflows reference them as `runs-on: ${{ vars.MACOS_RUNNER_15 || 'warp-macos-15-arm64-6x' }}`. If a variable is unset, the job falls back to WarpBuild, so CI is never broken by a missing variable.

Nightly and stable release stay on macOS 15 until Zig can link the real universal Ghostty CLI helper on macOS 26. `ci-macos-compat.yml` still covers macOS 26 by setting `CMUX_SKIP_ZIG_BUILD=1`, but publishing workflows cannot use that stub because the signed artifacts must include the real helper.

## Switch Blacksmith <-> WarpBuild

The switch is a repo-variable change. It takes effect on the next workflow run, with no PR or commit.

Use Blacksmith (default):

```bash
gh variable set MACOS_RUNNER_15 --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-15
gh variable set MACOS_RUNNER_26 --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-26
```

Fall back to WarpBuild (e.g. Blacksmith macOS capacity is queuing, as happened in https://github.com/manaflow-ai/cmux/pull/4926):

```bash
gh variable delete MACOS_RUNNER_15 --repo manaflow-ai/cmux
gh variable delete MACOS_RUNNER_26 --repo manaflow-ai/cmux
```

Deleting the variables reverts to the WarpBuild fallback baked into the workflows. You can also set them explicitly to `warp-macos-15-arm64-6x` / `warp-macos-26-arm64-6x`.

Check current values:

```bash
gh variable list --repo manaflow-ai/cmux
```

## Manual runs

`perf-activation.yml` and `test-e2e.yml` keep a `runner` choice input that defaults to `auto`. `auto` (and the empty `pull_request` case for perf) follows `MACOS_RUNNER_15` then the Warp fallback, so flipping the repo variable also redirects these workflows. An explicit choice wins over the variable; both dropdowns expose `warp-macos-15-arm64-6x` / `warp-macos-26-arm64-6x` so an operator can pick Warp directly during a Blacksmith outage. `test-e2e.yml` also keeps `depot-macos-*` choices and a Depot identity guard for GUI-activation runs.

## Guard

`tests/test_ci_self_hosted_guard.sh` (run by the `workflow-guard-tests` job) asserts every paid macOS job references `vars.MACOS_RUNNER_*` or a Blacksmith/Warp label, so a job can never silently fall back to a free GitHub-hosted runner. Keep new labels in `.github/actionlint.yaml`.
