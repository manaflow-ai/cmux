# CI runners

Every CI/CD job picks its runner from a repository variable instead of a
hardcoded label. We run **Blacksmith only** for every runner type and accept
the occasional sub-minute Blacksmith queue rather than overflowing elsewhere.
There is no automatic Warp overflow. WarpBuild stays wired in only as a manual
break-glass fallback (and as the home of the macOS XCTest/GUI jobs Blacksmith
can't run; see exceptions below). Switching a runner type to the break-glass
fallback is a single repo-variable change that takes effect on the next
workflow run, with no PR or commit.

| Variable            | Used by                                                    | Blacksmith (primary)        | Fallback baked into the workflow |
| ------------------- | ---------------------------------------------------------- | --------------------------- | -------------------------------- |
| `LINUX_RUNNER`      | every Linux job (`ci.yml` web/typecheck/db, presence, cloud-vm, nightly/ios decide jobs, claude, homebrew, tmux fuzz) | `blacksmith-4vcpu-ubuntu-2404` | `warp-ubuntu-latest-x64-4x`   |
| `MACOS_RUNNER_15`   | universal Release app builds: nightly, stable release, `release-ghostty-cli-helper`, most macOS defaults | `blacksmith-6vcpu-macos-15` | `warp-macos-15-arm64-6x`         |
| `MACOS_RUNNER_26`   | macOS 26 compat + jobs that do not need Zig                 | `blacksmith-6vcpu-macos-26` | `warp-macos-26-arm64-6x`         |
| `MACOS_RUNNER_26_RELEASE` | disk-heavy `release-build` universal app             | `blacksmith-6vcpu-macos-26` | `warp-macos-26-arm64-6x`         |
| `MACOS_RUNNER_IOS`  | iOS simulator tests + TestFlight upload (`test-ios.yml`, `ios-testflight.yml`) | `blacksmith-6vcpu-macos-26` | `macos-26` (free GitHub-hosted)  |

Workflows reference them as `runs-on: ${{ vars.LINUX_RUNNER || 'warp-ubuntu-latest-x64-4x' }}`.
If a variable is unset the job uses the fallback, so CI is never broken by a
missing variable.

## Deliberate exceptions (not on Blacksmith)

Blacksmith macOS runners cannot initiate a testmanagerd control session (no GUI
login session / automation mode), so XCTest-driven and virtual-display jobs
hang at "Timed out 120s initiating control session with daemon" and never go
green there. These stay on Warp or Depot on purpose:

- `ci.yml` `tests` is hard-pinned to `warp-macos-15-arm64-6x` (see the comment at
  the job). Revert to `vars.MACOS_RUNNER_15` once Blacksmith macOS testmanagerd
  is repaired.
- `ci.yml` `tests-build-and-lag` and `ui-regressions`, `perf-activation.yml`
  PR runs, and the `virtual_display` compat row use `MACOS_RUNNER_DISPLAY`
  (Depot/Warp) because Cmd-Tab timing, virtual displays, and XCTest automation
  need a GUI-capable runner. A Depot identity guard validates these.

`MACOS_RUNNER_IOS` defaults to Blacksmith but keeps a free GitHub-hosted
`macos-26` fallback because iOS simulator XCUITests may hit the same
testmanagerd limitation. If an iOS job wedges on Blacksmith, flip
`MACOS_RUNNER_IOS` back to `macos-26`.

## Break-glass: switch a runner type off Blacksmith

We do not auto-overflow. If Blacksmith is genuinely down or queuing for minutes
(not the sub-minute queue we accept by default), manually flip the affected
variable to its fallback; revert it once Blacksmith recovers. Use Blacksmith
(default):

```bash
gh variable set LINUX_RUNNER          --repo manaflow-ai/cmux -b blacksmith-4vcpu-ubuntu-2404
gh variable set MACOS_RUNNER_15       --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-15
gh variable set MACOS_RUNNER_26       --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-26
gh variable set MACOS_RUNNER_26_RELEASE --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-26
gh variable set MACOS_RUNNER_IOS      --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-26
```

Break-glass a type to WarpBuild only when Blacksmith is down or queuing for
minutes (as happened for macOS in https://github.com/manaflow-ai/cmux/pull/4926).
Either delete the variable to use the baked-in fallback, or set it explicitly:

```bash
gh variable set LINUX_RUNNER    --repo manaflow-ai/cmux -b warp-ubuntu-latest-x64-4x
gh variable set MACOS_RUNNER_15 --repo manaflow-ai/cmux -b warp-macos-15-arm64-6x
gh variable delete MACOS_RUNNER_26 --repo manaflow-ai/cmux   # reverts to the Warp fallback
```

Check current values:

```bash
gh variable list --repo manaflow-ai/cmux
```

## Manual runs

`perf-activation.yml` and `test-e2e.yml` keep a `runner` choice input that
defaults to `auto`. Manual `auto` runs follow `MACOS_RUNNER_15` then the Warp
fallback, so flipping the repo variable redirects those workflows. An explicit
manual choice wins over the variable; both dropdowns expose Blacksmith, Warp,
and `depot-macos-*` choices, with a Depot identity guard for GUI-activation
runs.

## Guard

`tests/test_ci_self_hosted_guard.sh` (run by the `workflow-guard-tests` job)
asserts that no job pins a bare GitHub-hosted runner (`ubuntu-*` / `macos-NN`):
every job must route through a runner repo variable so the overflow switch stays
a single variable flip. It also asserts every paid macOS job references
`vars.MACOS_RUNNER_*` or a Blacksmith/Warp/Depot label so it can never silently
fall back to a free runner. Bare paid-provider labels (`blacksmith-*`, `warp-*`,
`depot-*`) stay allowed for deliberate single-runner pins. Keep new labels in
`.github/actionlint.yaml`.
