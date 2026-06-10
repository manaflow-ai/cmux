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

## Linux runners

GitHub-hosted `ubuntu-latest` minutes are billed against the org's included Actions allowance; Blacksmith Linux runners are not. Every Linux job routes through the `LINUX_RUNNER` repo variable with a Blacksmith fallback:

```yaml
runs-on: ${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2204' }}
```

With the variable unset (the default), Linux jobs run on Blacksmith. Fall back to GitHub-hosted runners during a Blacksmith Linux outage:

```bash
gh variable set LINUX_RUNNER --repo manaflow-ai/cmux -b ubuntu-latest
# revert to Blacksmith:
gh variable delete LINUX_RUNNER --repo manaflow-ai/cmux
```

The `cloud-vm-migrate.yml` and `cloud-vm-smoke.yml` jobs intentionally stay on `ubuntu-latest` because they connect to IP-allowlisted cloud infra (Aurora, provider APIs) and need GitHub-hosted egress ranges. They are the only allowlisted exceptions in the guard below.

## iOS runners

The iOS jobs that need an iOS Simulator runtime (`ios-simulator` in `test-ios.yml`) or TestFlight signing (`upload` in `ios-testflight.yml`) default to GitHub-hosted `macos-26`, which bills at 10x. They route through the `IOS_RUNNER` repo variable so they can move to a paid macOS runner once one is confirmed to ship iOS Simulator runtimes and signing support:

```yaml
runs-on: ${{ vars.IOS_RUNNER || 'macos-26' }}
```

`mobile-core-package` (`swift test`, no simulator) already runs on `MACOS_RUNNER_26`. Verify a candidate runner has iOS runtimes with `xcrun simctl list devices available` before setting `IOS_RUNNER`.

## Guard

`tests/test_ci_self_hosted_guard.sh` (run by the `workflow-guard-tests` job) asserts every paid macOS job references `vars.MACOS_RUNNER_*` or a Blacksmith/Warp label, and that no Linux job uses GitHub-hosted `ubuntu-latest` outside the `cloud-vm-*` allowlist, so a job can never silently fall back to a billed GitHub-hosted runner. Keep new labels in `.github/actionlint.yaml`.
