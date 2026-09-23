# CI runners

Every CI/CD job picks its runner from a repository variable instead of a
hardcoded label. Changing a runner type is a single repository-variable update
that takes effect on the next workflow run.

Linux uses Blacksmith. macOS uses Blacksmith cloud runners, with the
self-hosted Tart fleet described below carrying specific lanes as they are
qualified. WarpBuild is paid overflow and is not a steady state for any lane.
Non-urgent macOS work runs on free GitHub-hosted runners through the
background lane described below.

**The table below is the intended steady state, not a live readout.** Repository
variables drift, and a stale table is worse than no table. For what is actually
set right now:

```sh
gh variable list --repo manaflow-ai/cmux
```

| Variable | Used by | Intended steady state | Fallback baked into the workflow |
| --- | --- | --- | --- |
| `LINUX_RUNNER` | every Linux job (`ci.yml` web/typecheck/db, presence, cloud-vm, nightly/ios decide jobs, claude, homebrew, tmux fuzz) | `blacksmith-4vcpu-ubuntu-2404` | `blacksmith-4vcpu-ubuntu-2404` |
| `LINUX_ARM64_RUNNER` | native ARM64 package entrypoint verification | `ubuntu-24.04-arm` | `ubuntu-24.04-arm` |
| `MACOS_RUNNER_15` | the macOS 15 default: `macos-compile-admission`, `app-host-unit-tests`, nightly helper and test-cache jobs | `blacksmith-6vcpu-macos-15` | `blacksmith-6vcpu-macos-15` |
| `MACOS_RUNNER_PR` | **pull-request** macOS jobs only, in `ci-macos.yml`, `cli-pipe-regressions.yml` and `terminal-hang-diagnostics.yml` | unset (see "Lanes" below) | `blacksmith-6vcpu-macos-15` |
| `MACOS_RUNNER_TESTS` | the manual test-debugging lanes: `test-e2e.yml` and `test-depot.yml` | unset (see "Lanes" below) | `blacksmith-6vcpu-macos-26` for `test-e2e.yml`, `blacksmith-6vcpu-macos-15` for `test-depot.yml` |
| `MACOS_RUNNER_DUAL_XCODE` | `swift-package-tests` (SDK 15 release helper, then SDK 26 package tests) on non-pull-request events; pull requests take `MACOS_RUNNER_PR` | `blacksmith-6vcpu-macos-15` | `blacksmith-6vcpu-macos-15` |
| `MACOS_RUNNER_26` | macOS 26 compatibility jobs and nightly sign/notarize | `blacksmith-6vcpu-macos-26` | `blacksmith-6vcpu-macos-26` |
| `MACOS_RUNNER_26_NIGHTLY_BUILD` | changed-revision universal Nightly app builds | `blacksmith-12vcpu-macos-26` | `blacksmith-6vcpu-macos-26` |
| `MACOS_RUNNER_26_RELEASE` | disk-heavy `release-build` universal app | `blacksmith-6vcpu-macos-26` | `blacksmith-6vcpu-macos-26` |
| `MACOS_RUNNER_DISPLAY` | macOS GUI, XCUITest, and virtual-display tests (`tests-build-and-lag`) | `blacksmith-6vcpu-macos-15` | `blacksmith-6vcpu-macos-15` |
| `MACOS_RUNNER_IOS` | iOS simulator tests + TestFlight upload (`test-ios.yml`, `ios-testflight.yml`) | `blacksmith-6vcpu-macos-26` | `blacksmith-6vcpu-macos-26` |
| `MACOS_RUNNER_STREAMED_VALIDATION` | `ios-streamed-validate.yml`, `iroh-release-gate.yml` streamed validation | `blacksmith-6vcpu-macos-15` | `blacksmith-6vcpu-macos-26` and `blacksmith-6vcpu-macos-15` respectively |
| `MACOS_RUNNER_BACKGROUND` | non-urgent macOS work only: `build-ghosttykit`, the macOS legs of `cmux-tui-artifacts` (post-merge) and `cmux-tui-nightly` (on demand). See "Background lane" below | unset | `macos-15` (GitHub-hosted, free) |

## Lanes

Not every macOS job follows the same variable, because not every macOS job has
the same cost profile or the same urgency.

- **Required CI on `main`, the merge queue, releases and nightly** follow the
  `MACOS_RUNNER_*` variables above. This is the lane where a slow or queued
  runner blocks a merge or a ship, so it is the lane worth paying for if paid
  capacity is ever warranted.
- **Pull requests** resolve through `MACOS_RUNNER_PR` first. Unset means
  Blacksmith. PR runs are cancelled on supersession by design, so they are the
  wrong place to spend elastic paid capacity.
- **Manual test debugging** (`test-e2e.yml`, `test-depot.yml`) resolves through
  `MACOS_RUNNER_TESTS`, and deliberately does **not** follow `MACOS_RUNNER_15`.
  Re-running one test to chase a flake should never reach for paid capacity.
  Both fallbacks stay on Blacksmith for that reason; `test-e2e.yml` falls back
  to macOS 26 because the macOS 15 pool's queue-to-start p90 was 83 min against
  1.0 min on 26, measured over 60 dispatches on 2026-09-22/23.

`MACOS_RUNNER_PR` and `MACOS_RUNNER_TESTS` are escape hatches: leaving them
unset is the intended state, and setting one overrides just that lane without
touching required CI. That makes a rollback a variable edit rather than a
revert.

A job that also reports its own pool in an env value must read that value from
the same expression its `runs-on` uses, not from the lane variable alone.
`macos-compile-admission` puts `CMUX_PRODUCT_RUNNER` in the compiled product
contract and `tests-build-and-lag` validates `REQUESTED_RUNNER`; on a pull
request both resolve through `MACOS_RUNNER_PR`, so a job reading only
`MACOS_RUNNER_15` or `MACOS_RUNNER_DISPLAY` would stamp and check a pool it is
not on. `check_macos_runner_identity_env_tracks_routing` in
`tests/test_ci_self_hosted_guard.sh` enforces that.

Workflows reference them as `runs-on: ${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}`.
If a variable is unset the job uses the fallback, so CI is never broken by a
missing variable. Pull requests from forks never see repository variables, so
the fallback is where they always run: it must be a Blacksmith label, never the
paid Warp overflow. `tests/test_ci_self_hosted_guard.sh` enforces that, and
also asserts that no workflow names a Warp label as a literal anywhere.

Because forks cannot see repository variables, a fork pull request resolves
`MACOS_RUNNER_PR` and `MACOS_RUNNER_TESTS` to empty and lands on the Blacksmith
fallback, never on paid capacity. `test-e2e.yml` is `workflow_dispatch`-only,
so a fork never reaches its fallback at all; for the lanes a fork does reach,
the fallback is still the runner they used before these variables existed.

## Background lane

`MACOS_RUNNER_BACKGROUND` moves macOS work that nobody is waiting on off the
shared macOS pool. Every other macOS job shares one Blacksmith pool (with paid
Warp as overflow), and pull request CI queues on it for 30-60+ minutes at peak.
The repository is public, so standard GitHub-hosted macOS runners are free with
unlimited minutes (about five concurrent jobs, 3-core M1, 7 GB RAM). They are
slower per job, which is fine for work that is not on a merge path.

A job belongs in the lane only if all of these hold:

- it is dispatch-only, scheduled, or runs after merge; never `pull_request`,
  `pull_request_target`, `merge_group`, or `workflow_call` (the guard enforces
  this per workflow);
- it fits 3 cores and 7 GB: scripts, a single package, a Rust or Zig build,
  uploads; not a full app or app-host XCTest build;
- it is not a timing benchmark or incremental-build probe, whose numbers only
  compare on the same hardware;
- it does not need a GUI console session.

Members today: `build-ghosttykit.yml` (Xcode from the image default, Zig
xcframework build), and the two macOS Rust legs of `cmux-tui-artifacts.yml`
and `cmux-tui-nightly.yml` (passed as `macos_runner` to
`cmux-tui-build-package.yml`; release and merge-gate callers keep their own
runner).

The fallback is `macos-15`, never `macos-26`: the self-hosted fleet carries a
`macos-26` label and GitHub prefers a matching self-hosted runner. The
`macos-15` image ships Xcode 26.3 (macOS 26.2 SDK) next to its 16.4 default, so
jobs that pin `CMUX_CI_XCODE_APP_MACOS_15` resolve there too.

An admin can repoint the whole lane with one variable edit, for example back
to Blacksmith if GitHub's macOS queue is ever the slower one:

```bash
gh variable set MACOS_RUNNER_BACKGROUND --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-15
```

Leaving it unset is the intended state.

## Persistent compile-admission pilot

`macos-compile-admission` has one narrow owned-Mac producer path for trusted,
same-repository maintainer pull requests. The required
`macOS compile admission` job remains on the ordinary paid macOS runner and
remains the check, log, validation, and artifact-publication owner. It may
consume a compile product from `.github/workflows/persistent-macos-compile.yml`
after revalidating the Git revision/tree, Xcode, SDK, architecture,
`Package.resolved`, submodules, Glaeda lineage evidence, warning budget, and
early CLI probes. Any dispatch, queue, execution, download, or validation miss
falls through to the existing hosted compile in that same required job.
The required hosted macOS job is allocated without waiting for the persistent
producer. It restores any exact reusable product first, then observes the
producer with read-only Actions permission before deciding whether to consume
the persistent artifact or compile hosted. That observation is nonblocking:
the producer is consumed only when its compile is already complete at the
decision point; an absent, queued, or running producer falls through to hosted
compilation immediately. The PR workflow never receives
Actions write authority: `changes` publishes a small exact-source request
artifact, and the default-branch `persistent-macos-router.yml` workflow
validates it against the live PR and owns producer dispatch/cancellation.

The producer is `workflow_dispatch`-only and requires the
`cmux-persistent-compile` runner group plus the dedicated
`cmux-persistent-macos-compile` label. Before rollout, the organization-owned
runner group must allow this public repository and restrict workflow access to
`manaflow-ai/cmux/.github/workflows/persistent-macos-compile.yml@refs/heads/main`.
That group policy is the external scheduling boundary: branch-modified workflow
copies cannot acquire the owned Mac. The compile job has empty GitHub-token
permissions, performs public Git fetches instead of `actions/checkout`, and
receives no repository secrets. Glaeda owns DerivedData, SwiftPM,
module-cache, and Xcode compilation-cache persistence; every run still resolves
packages and performs exact source/toolchain admission.

Glaeda performs no automatic cache eviction, and each generation under
`.glaeda/apple-build/cache/<key>/` holds a full cmux DerivedData tree, so a
toolchain change would otherwise strand a multi-GB directory on the owned Mac
indefinitely. After a verified compile, `run-persistent-mac-compile.py` stamps
the generation it used and deletes all but the three most recently used ones,
logging each removal and recording it in the admission metrics. The generation
in use is never a candidate; an evicted generation costs only a cold rebuild.

Capacity sizing for that pilot -- how many owned Macs the queue actually
needs, which lane moves first, and the enrollment/drain/rollback runbook --
lives in [ci/mac-fleet.md](ci/mac-fleet.md).

Rollout is reversible through two repository variables:

- `CI_PERSISTENT_MAC_COMPILE=off` (or unset): hosted path only;
- `CI_PERSISTENT_MAC_COMPILE=pilot` with
  `CI_PERSISTENT_MAC_COMPILE_COHORT=13198,feature/name`: only matching trusted
  PR numbers or head branches;
- `CI_PERSISTENT_MAC_COMPILE=all`: every trusted same-repository
  organization PR (`OWNER` or `MEMBER`).

`OWNER`/`MEMBER` is the single admitted author-association set. The producer's
`authorize` job enforces it, and every routing gate ahead of the producer
(`ci.yml`, `ci-macos.yml`, `scripts/ci/persistent_mac_route.py`) must match it
exactly. A routing gate wider than the producer still fails safe, but it
dispatches a producer that is certain to refuse, which costs an owned-Mac
allocation and reports `producer_failure` instead of falling through to the
hosted path at once. `tests/test_ci_persistent_mac_compile.py` derives all four
sets from their source files and asserts they agree, so they cannot drift.

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
gh variable set MACOS_RUNNER_DISPLAY    --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-15
gh variable set MACOS_RUNNER_IOS        --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-26
```

Leave `MACOS_RUNNER_PR` and `MACOS_RUNNER_TESTS` unset in either recipe.
They exist to hold the pull-request and manual test lanes on Blacksmith
independently of whatever the pool above is set to.

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
a single variable flip. A GitHub-hosted macOS label may appear only as the
`MACOS_RUNNER_BACKGROUND` fallback (`vars.MACOS_RUNNER_BACKGROUND || 'macos-15'`)
in a workflow with no pull request, merge-queue or `workflow_call` trigger,
apart from the pinned macOS 14 / Intel compatibility legs in
`ci-macos-compat.yml` and `relay-publish-npm.yml`. It also asserts every paid macOS job references
`vars.MACOS_RUNNER_*` or a Blacksmith/Warp/Depot label so it can never silently
fall back to a free runner. Bare paid-provider labels (`blacksmith-*`, `warp-*`,
`depot-*`) stay allowed for deliberate single-runner pins. Keep new labels in
`.github/actionlint.yaml`.

The fleet-label guard allows Tart labels only as exact manual canary choices.
Required jobs continue to reference repository variables, so cutover and
break-glass remain configuration changes instead of workflow edits.

## CMUX-owned machine enrollment

Persistent CMUX hardware can be enrolled for repository-owned semantic workloads without becoming a direct required-CI runner. See [fleet-enrollment.md](fleet-enrollment.md).

The first reviewed role bindings are:

- `cmux_macos_native_build -> cmux.macos.dev-check@1`
- `cmux_linux_ci -> cmux.ci.guard@1`

CMUX owns those workload profiles and their pass/fail semantics through `scripts/ci/cmux_workload_profile.py`. Glaeda owns the machine enrollment record, candidate eligibility, local admission, and acceptance receipt that binds the exact canonical `cmux-workload-result/v1` bytes.

Enrollment does not register a GitHub runner or change repository runner variables. Required CI continues to use the policy above until a separately reviewed CI routing change promotes a fleet role.

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
