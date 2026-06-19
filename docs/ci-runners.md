# CI runners

macOS CI runs on **paid managed runners only**. Every macOS job names a paid
label directly (WarpBuild for the always-on lanes, Depot for GUI-activation
runs); the old `vars.MACOS_RUNNER_*` indirection and the self-hosted Mac minis
(labels `cmux-aws-macos-15` / `cmux-macos-26`) were retired. Linux jobs still
pick their runner from the `LINUX_RUNNER` repo variable so the
Blacksmith<->Warp overflow switch for Linux stays a single repo-variable flip
with no PR.

| Runner | Used by | Notes |
| ------ | ------- | ----- |
| `vars.LINUX_RUNNER` (fallback `warp-ubuntu-latest-x64-4x`) | every Linux job (`ci.yml` web/typecheck/db, presence, cloud-vm, nightly/ios decide jobs, claude, homebrew, tmux fuzz) | Blacksmith<->Warp flip via the repo variable |
| `warp-macos-15-arm64-6x` | universal Release app builds: nightly, stable release, `release-ghostty-cli-helper`, `tests`, `tests-build-and-lag`, `ui-regressions`, `build-ghosttykit`, tmux corpus, e2e/perf `auto` default | paid macOS 15 |
| `warp-macos-26-arm64-6x` | macOS 26 app build/sign jobs: `release-build`, release `build-sign-notarize`, macOS 26 compat | paid macOS 26 (disk-heavy universal builds) |
| `depot-macos-*` | `perf-activation.yml` PR runs (`depot-macos-latest`) and explicit `depot-macos-*` choices in `perf-activation.yml` / `test-e2e.yml` | paid Depot, GUI activation; identity-guarded |
| `macos-26` (free GitHub-hosted) | iOS simulator tests + TestFlight upload (`test-ios.yml`, `ios-testflight.yml`) | only sanctioned bare hosted runner; iOS sim path does not need a paid GUI runner |

Linux jobs reference the variable as
`runs-on: ${{ vars.LINUX_RUNNER || 'warp-ubuntu-latest-x64-4x' }}`; if the
variable is unset the job uses the baked-in Warp fallback, so CI is never broken
by a missing variable.

## GUI-activation runners (Depot)

Blacksmith macOS runners cannot initiate a testmanagerd control session (no GUI
login session / automation mode), so XCTest-driven and virtual-display jobs hang
at "Timed out 120s initiating control session with daemon" there. macOS jobs
therefore run on Warp or Depot:

- `ci.yml` `tests`, `tests-build-and-lag`, and `ui-regressions` pin
  `warp-macos-15-arm64-6x`. `tests-build-and-lag` and `ui-regressions` keep a
  "Validate display runner identity" step: if the pinned label is ever changed
  to a `depot-macos-*` value, the step asserts the resolved `runner.name` is
  actually Depot and fails otherwise.
- `perf-activation.yml` PR runs use `depot-macos-latest`; manual runs default to
  `warp-macos-15-arm64-6x` (`auto`) and expose `depot-macos-*` choices.
- `test-e2e.yml` defaults to `warp-macos-15-arm64-6x` (`auto`) and exposes
  `depot-macos-*` choices. Any Depot choice is identity-guarded.
- `macOS 26` compat (`ci-macos-compat.yml`) runs on `warp-macos-26-arm64-6x`.

The iOS jobs run on free GitHub-hosted `macos-26` because iOS simulator
XCUITests and the TestFlight upload do not need a paid GUI-activation runner.

## Manual runs

`perf-activation.yml` and `test-e2e.yml` keep a `runner` choice input that
defaults to `auto`. `auto` resolves to `warp-macos-15-arm64-6x`; an explicit
manual choice (Blacksmith, Warp, or `depot-macos-*`) wins over the default. A
Depot identity guard validates GUI-activation runs.

## Guard

`tests/test_ci_self_hosted_guard.sh` (run by the `workflow-guard-tests` job)
asserts that every guarded macOS job runs on a paid managed label
(`warp-*`/`depot-*`/`blacksmith-*`) and never on a free GitHub-hosted runner,
that Linux jobs still route through `vars.LINUX_RUNNER`, and that the retired
self-hosted Mac labels (`cmux-aws-macos-15` / `cmux-macos-26`, or any
`self-hosted` label) never reappear in a `runs-on`. The only sanctioned bare
GitHub-hosted runner is `macos-26` for the iOS jobs in `test-ios.yml` and
`ios-testflight.yml`; the guard fails if any other workflow pins a bare hosted
runner or if an iOS workflow pins a hosted macOS label other than `macos-26`.
`tests/test_ci_release_sdk_lane.sh` additionally asserts the macOS 15 helper /
macOS 26 app SDK split for the release lane. Keep new labels in
`.github/actionlint.yaml`.
