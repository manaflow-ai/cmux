# CI runners

Every CI/CD job picks its runner from a repository variable instead of a
hardcoded label. Linux uses Blacksmith. macOS uses ephemeral Tart VMs on the
cmux Mac fleet. Changing a runner type is a single repository-variable update
that takes effect on the next workflow run.

| Variable            | Used by                                                    | Active value                | Fallback baked into the workflow |
| ------------------- | ---------------------------------------------------------- | --------------------------- | -------------------------------- |
| `LINUX_RUNNER`      | every Linux job (`ci.yml` web/typecheck/db, presence, cloud-vm, nightly/ios decide jobs, claude, homebrew, tmux fuzz) | `blacksmith-4vcpu-ubuntu-2404` | `blacksmith-4vcpu-ubuntu-2404` |
| `LINUX_ARM64_RUNNER` | native ARM64 package entrypoint verification              | `ubuntu-24.04-arm`          | `ubuntu-24.04-arm`               |
| `MACOS_RUNNER_15`   | universal Release app builds: nightly, stable release, `release-ghostty-cli-helper`, most macOS defaults | `tart-macos-15` | `blacksmith-6vcpu-macos-15`      |
| `MACOS_RUNNER_DUAL_XCODE` | `swift-package-tests` (SDK 15 release helper, then SDK 26 package tests) | `blacksmith-6vcpu-macos-15` | `blacksmith-6vcpu-macos-15` |
| `MACOS_RUNNER_26`   | macOS 26 compatibility jobs                                | `blacksmith-6vcpu-macos-26` | `blacksmith-6vcpu-macos-26`      |
| `MACOS_RUNNER_26_NIGHTLY_BUILD` | changed-revision universal Nightly app builds       | `blacksmith-12vcpu-macos-26` | `blacksmith-12vcpu-macos-26`     |
| `MACOS_RUNNER_26_RELEASE` | disk-heavy `release-build` universal app             | `blacksmith-6vcpu-macos-26` | `blacksmith-6vcpu-macos-26`      |
| `MACOS_RUNNER_DISPLAY` | macOS GUI, XCUITest, and virtual-display tests           | `tart-gui`                  | `blacksmith-6vcpu-macos-15`      |
| `MACOS_RUNNER_IOS`  | iOS simulator tests + TestFlight upload (`test-ios.yml`, `ios-testflight.yml`) | `tart-ios` | `blacksmith-6vcpu-macos-26`  |

Workflows reference them as `runs-on: ${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}`.
If a variable is unset the job uses the fallback, so CI is never broken by a
missing variable. Pull requests from forks never see repository variables, so
the fallback is where they always run: it must be a Blacksmith label, never the
paid Warp overflow. `tests/test_ci_self_hosted_guard.sh` enforces that.

## Persistent compile-admission pilot

`macos-compile-admission` has one narrow owned-Mac producer path for trusted,
same-repository organization-member pull requests. The required
`macOS compile admission` job remains on the ordinary paid macOS runner and
remains the check, log, validation, and artifact-publication owner. It may
consume a compile product from `.github/workflows/persistent-macos-compile.yml`
after revalidating the Git revision/tree, Xcode, SDK, architecture,
`Package.resolved`, submodules, Glaeda lineage evidence, warning budget, and
early CLI probes. Any dispatch, queue, execution, download, or validation miss
falls through to the existing hosted compile in that same required job.
The PR workflow never receives Actions write authority: `changes` publishes a
small exact-source request artifact, the default-branch
`persistent-macos-router.yml` workflow validates it against the live PR and
owns producer dispatch/cancellation, and the PR-side route job observes producer
state with read-only Actions permission.

The producer is `workflow_dispatch`-only and requires the
`cmux-persistent-compile` runner group plus the dedicated
`cmux-persistent-macos-compile` label. Before rollout, the organization-owned
runner group must allow this public repository and restrict workflow access to
`manaflow-ai/cmux/.github/workflows/persistent-macos-compile.yml@refs/heads/main`.
That group policy is the external scheduling boundary: branch-modified workflow
copies cannot acquire the owned Mac. The compile job has empty GitHub-token
permissions, performs public Git fetches instead of `actions/checkout`, and
receives no repository secrets. Glaeda owns native cache placement, admission,
recovery, and exact-source locking. CMUX owns compile semantics through
`cmux.macos.compile-admission@1` and its `cmux-workload-result/v1` receipt.
The persistent wrapper refuses execution when that canonical profile/generation
is absent, so rollout begins only after #13411 is present in the candidate
source. DerivedData, SwiftPM, module-cache, and Xcode compilation-cache state
then remain resident under Glaeda while the canonical CMUX entrypoint still
resolves dependencies, compiles, validates the warning budget, records named
stage timings, and proves artifact/process cleanup.

The current hosted admission path remains the comparison baseline and the
fallback authority. Persistent results additionally carry the canonical semantic
comparison key and context key; compare those keys only across runs produced by
the same profile/generation and toolchain context.

Rollout is reversible through two repository variables:

- `CI_PERSISTENT_MAC_COMPILE=off` (or unset): hosted path only;
- `CI_PERSISTENT_MAC_COMPILE=pilot` with
  `CI_PERSISTENT_MAC_COMPILE_COHORT=13198,feature/name`: only matching trusted
  PR numbers or head branches;
- `CI_PERSISTENT_MAC_COMPILE=all`: every trusted same-repository
  organization-member PR.

Queue and execution ceilings may be set with
`CI_PERSISTENT_MAC_QUEUE_SECONDS` and
`CI_PERSISTENT_MAC_EXECUTION_SECONDS`; defaults are 90 and 480 seconds.
Admission publishes timing evidence for source preparation, package readiness,
compile, warning validation, product publication, total wall time, runner time,
and the `hot` / `partially-warm` / `cold-reset` / `hosted fallback`
classification.

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

## Shared physical-host interoperability

The current required-CI policy continues to use isolated Tart guests or hosted
providers. Any future path that executes directly on shared CMUX-owned hardware
must preserve a separate caller identity, semantic workload request, and
machine-local physical lease.

Examples of callers that may share a host include GitHub Actions, `cmux-ci`,
developer/build tooling, direct agents, operator commands, and reviewed fleet
schedulers. They keep their own workflow state. The host-side execution adapter
owns fresh admission, resource ownership, bounded execution, and settlement.

A scheduler may select a candidate node. That selection stays advisory until
the node rechecks current drain/pressure/resource state and acquires its local
lease. When the CMUX controller already holds a machine or resource reservation,
the host adapter validates that reservation's owner, scope, generation, and
expiry, then binds local execution to it. It never creates an unrelated
competing reservation for the same resource.

Scarce local claims include native build lanes, heavy Linux slots,
project-native locks, artifact-publisher slots, and resident workspaces.
Participating adapters use one collision boundary for those claims. Runner
liveness, process names, and apparent idleness are observation only.

Execution receipts correlate the caller class and external request reference
with the semantic workload, opaque node identity/class, local lease generation,
result, and cleanup/settlement. Caller-private workflow state remains in the
caller.

Hosted/isolated fallback remains available when the shared host refuses local
admission or is draining, pressured, or unavailable.

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

`perf-activation.yml` and `test-e2e.yml` keep a `runner` choice input that
defaults to `auto`. Manual `auto` runs follow `MACOS_RUNNER_15` then the Blacksmith
fallback, so flipping the repo variable redirects those workflows. An explicit
manual choice wins over the variable; both dropdowns expose Blacksmith, Warp,
and `depot-macos-*` choices, with a Depot identity guard for GUI-activation
runs. `test-e2e.yml` also exposes `tart-canary`, `tart-dual`, and `tart-small`
for targeted fleet validation. These choices are available only through
`workflow_dispatch`.

## Guard

`tests/test_ci_self_hosted_guard.sh` (run by the `workflow-guard-tests` job)
asserts that no job pins a bare GitHub-hosted runner (`ubuntu-*` / `macos-NN`):
every job must route through a runner repo variable so the overflow switch stays
a single variable flip. It also asserts every paid macOS job references
`vars.MACOS_RUNNER_*` or a Blacksmith/Warp/Depot label so it can never silently
fall back to a free runner. Bare paid-provider labels (`blacksmith-*`, `warp-*`,
`depot-*`) stay allowed for deliberate single-runner pins. Keep new labels in
`.github/actionlint.yaml`.

The fleet-label guard allows Tart labels only as exact manual canary choices.
Required jobs continue to reference repository variables, so cutover and
break-glass remain configuration changes instead of workflow edits.

## Direct physical-host runner boundary

Required GUI, test, Release, signing, and ordinary macOS jobs never route to
the persistent self-hosted mac-mini fleet (`cmux-mac-mini`, `studio1`,
`mac4-cmuxvnc*`, `cmux-austin-mini-*`). Those records can collide with cloud
labels and lack the isolated foreground GUI guarantees expected by runtime
tests.

The sole direct-host exception is the dispatch-only
`Persistent Apple compile` producer described above, selected by its dedicated
workflow-restricted `cmux-persistent-compile` runner group and
`cmux-persistent-macos-compile` label. It performs compile-only Debug work,
carries no repository secrets, and grants its hot state zero result authority.
Every required macOS fallback still routes to the paid hosted path.
`check_no_self_hosted_fleet_runners` in
`tests/test_ci_self_hosted_guard.sh` enforces that exact exception and rejects
any second required-job or generic fleet route. Repository variables may keep
pointing at the isolated `tart-*` pool for their existing jobs.
