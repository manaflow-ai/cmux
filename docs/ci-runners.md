# CI runners

Most CI/CD jobs pick their runner from a repository variable. Linux uses
Blacksmith. macOS uses ephemeral Tart VMs on the cmux Mac fleet. The manual
E2E security lane is a deliberate exception and uses the fixed GitHub-hosted
`macos-15` label. Changing a variable-backed runner takes effect on the next
workflow run.

| Variable            | Used by                                                    | Active value                | Fallback baked into the workflow |
| ------------------- | ---------------------------------------------------------- | --------------------------- | -------------------------------- |
| `LINUX_RUNNER`      | every Linux job (`ci.yml` web/typecheck/db, presence, cloud-vm, nightly/ios decide jobs, claude, homebrew, tmux fuzz) | `blacksmith-4vcpu-ubuntu-2404` | `warp-ubuntu-latest-x64-4x`   |
| `LINUX_ARM64_RUNNER` | native ARM64 package entrypoint verification              | `ubuntu-24.04-arm`          | `ubuntu-24.04-arm`               |
| `MACOS_RUNNER_15`   | universal Release app builds: nightly, stable release, `release-ghostty-cli-helper`, most macOS defaults | `tart-macos-15` | `warp-macos-15-arm64-6x`         |
| `MACOS_RUNNER_DUAL_XCODE` | `swift-package-tests` (SDK 15 release helper, then SDK 26 package tests) | `blacksmith-6vcpu-macos-15` | `blacksmith-6vcpu-macos-15` |
| `MACOS_RUNNER_26`   | macOS 26 compatibility jobs                                | `blacksmith-6vcpu-macos-26` | `blacksmith-6vcpu-macos-26`      |
| `MACOS_RUNNER_26_NIGHTLY_BUILD` | changed-revision universal Nightly app builds       | `blacksmith-12vcpu-macos-26` | `blacksmith-12vcpu-macos-26`     |
| `MACOS_RUNNER_26_RELEASE` | disk-heavy `release-build` universal app             | `blacksmith-6vcpu-macos-26` | `blacksmith-6vcpu-macos-26`      |
| `MACOS_RUNNER_DISPLAY` | macOS GUI, XCUITest, and virtual-display tests           | `tart-gui`                  | `warp-macos-15-arm64-6x`         |
| `MACOS_RUNNER_IOS`  | iOS simulator tests + TestFlight upload (`test-ios.yml`, `ios-testflight.yml`) | `tart-ios` | `blacksmith-6vcpu-macos-26`  |

Workflows reference them as `runs-on: ${{ vars.LINUX_RUNNER || 'warp-ubuntu-latest-x64-4x' }}`.
If a variable is unset the job uses the fallback, so CI is never broken by a
missing variable.

## Tart isolation and capacity

Each GitHub runner identity is sealed into a Tart template. A job runs in a
fresh clone with an Aqua login session, then the host deletes the clone. This
provides the GUI session required by macOS XCTest and prevents DerivedData,
simulators, credentials, and workspaces from leaking into later jobs.

The fleet has 18 Sequoia slots: two each on the seven 48 GB or larger hosts and
one each on the two 16 GB hosts. The 16 large-host slots accept GUI and iOS
jobs; all 18 accept ordinary macOS 15 jobs. macOS 26 and release builds stay on
Blacksmith until a Tahoe VM image passes the same runner and GUI canaries. Hosts
reject new jobs below their free-space threshold, delete every job VM after
use, and reap stale clones.

Do not route jobs to the physical mini runner records. The supported
self-hosted labels are the `tart-*` labels, and each Tart-aware canary checks
that the resolved runner name starts with `tart-cmux-` and that the guest has
the immutable `/etc/cmux-tart-ci` marker.

## Break-glass: switch a runner type to a paid provider

There is no automatic overflow. If the Tart pool is unavailable or its queue is
too long, set the affected variable to a paid provider. Restore Tart after the
fleet recovers.

```bash
gh variable set LINUX_RUNNER          --repo manaflow-ai/cmux -b blacksmith-4vcpu-ubuntu-2404
gh variable set LINUX_ARM64_RUNNER    --repo manaflow-ai/cmux -b ubuntu-24.04-arm
gh variable set MACOS_RUNNER_15         --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-15
gh variable set MACOS_RUNNER_DUAL_XCODE --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-15
gh variable set MACOS_RUNNER_26         --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-26
gh variable set MACOS_RUNNER_26_NIGHTLY_BUILD --repo manaflow-ai/cmux -b blacksmith-12vcpu-macos-26
gh variable set MACOS_RUNNER_26_RELEASE --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-26
gh variable set MACOS_RUNNER_DISPLAY    --repo manaflow-ai/cmux -b depot-macos-latest
gh variable set MACOS_RUNNER_IOS        --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-26
```

Restore the self-hosted pool with explicit labels:

```bash
gh variable set MACOS_RUNNER_15         --repo manaflow-ai/cmux -b tart-macos-15
gh variable set MACOS_RUNNER_DUAL_XCODE --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-15
gh variable set MACOS_RUNNER_26         --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-26
gh variable set MACOS_RUNNER_26_NIGHTLY_BUILD --repo manaflow-ai/cmux -b blacksmith-12vcpu-macos-26
gh variable set MACOS_RUNNER_26_RELEASE --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-26
gh variable set MACOS_RUNNER_DISPLAY    --repo manaflow-ai/cmux -b tart-gui
gh variable set MACOS_RUNNER_IOS        --repo manaflow-ai/cmux -b tart-ios
```

`MACOS_RUNNER_DUAL_XCODE` remains on Blacksmith because the Tart macOS 15
image currently carries Xcode 26 only and cannot build the SDK 15 helper.

Check current values:

```bash
gh variable list --repo manaflow-ai/cmux
```

## Manual runs

`perf-activation.yml` keeps its `runner` choice for performance experiments.
`test-e2e.yml` is a read-only manual check on the fixed GitHub-hosted
`macos-15` runner. Its optional `ref` input must be a full commit SHA that is
equal to, or an ancestor of, protected `main`; `scripts/run-e2e.sh` resolves a
branch name to a SHA before dispatching. The E2E workflow has no custom secrets,
write token, or self-hosted runner input.

`build-ghosttykit.yml` runs automatically when the protected `main` branch
changes the `ghostty` gitlink. It has no manual dispatch. The build job uses the
review-protected `sdk-release` environment, and its source gate verifies that
the gitlink names the in-organization Ghostty fork, points to an immutable
commit reachable from that fork's `main`, and still matches the checked-out
submodule. A maintainer must approve the environment before the release token
is available.

`nightly.yml` runs only from protected `main` pushes and schedules. `release.yml`
runs only for protected semantic-version tag pushes. Both workflows resolve the
event revision before any signing or publishing step and do not accept a
caller-selected branch.

## Guard

`tests/test_ci_self_hosted_guard.sh` (run by the `workflow-guard-tests` job)
asserts that product jobs route through a runner repo variable, with the
fixed-hosted CLA and read-only E2E control-plane jobs as explicit exceptions.
The guard also asserts every paid macOS job references
`vars.MACOS_RUNNER_*` or a Blacksmith/Warp/Depot label so it can never silently
fall back to a free runner. Bare paid-provider labels (`blacksmith-*`, `warp-*`,
`depot-*`) stay allowed for deliberate single-runner pins. Keep new labels in
`.github/actionlint.yaml`.

The fleet-label guard allows Tart labels only as exact manual canary choices.
Required jobs continue to reference repository variables, so cutover and
break-glass remain configuration changes instead of workflow edits.

## No direct physical-host runners

We do not route required CI directly to the persistent self-hosted mac-mini
fleet (`cmux-mac-mini`, `studio1`, `mac4-cmuxvnc*`,
`cmux-austin-mini-*`). Those minis carry labels that collide with cloud labels
(notably `macos-26` and `warp-macos-26-arm64-6x`), and GitHub prefers a matching
self-hosted runner, so a required job could silently land on a mini that cannot
foreground a GUI app. It stays `Running Background`, breaking key-window,
pasteboard, IME, and XCUITest behavior. Every macOS fallback therefore routes
to Blacksmith cloud, and
`check_no_self_hosted_fleet_runners` in `tests/test_ci_self_hosted_guard.sh`
fails CI if a required workflow hardcodes a fleet label. Repository variables
may point to the isolated `tart-*` pool. Legacy physical runner services remain
disabled and their GitHub records remain offline for rollback.
