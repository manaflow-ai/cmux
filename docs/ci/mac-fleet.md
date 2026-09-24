# Self-hosted macOS fleet: capacity, safety, operations

How many CMUX-owned Mac minis the macOS CI queue needs, which lane they take
first, what a compromised job on one could reach, and how one is enrolled,
drained and rolled back.

This document is the capacity and operations layer. It does not restate the
routing contract, which already exists:

- [`ci-runners.md`](../ci-runners.md) owns the runner-variable table, the
  persistent compile-admission pilot contract, the Tart pool, and the
  direct-physical-host boundary.
- [`fleet-enrollment.md`](../fleet-enrollment.md) owns machine onboarding.
- [`workload-profiles.md`](../workload-profiles.md) owns workload identity.

Read those first. This document answers "how many, which lane, and what
happens at 3 a.m.", and it is the one that carries measurements.

## TL;DR

- The Blacksmith macOS-15 pull-request pool is running at **11.2 busy servers
  of offered load against a 9-13 slot cap**. That is why macOS queue waits
  reach **p90 64 min, p99 124 min, worst observed 168 min**.
- **`macOS compile admission` is the lane to move.** It executes on 41% of all
  CI runs (98% of runs that touch macOS) and is 23% of the pool's minutes. It
  is also the only macOS lane every macOS-touching PR pays.
- The mechanism to move it is **already built and has never run**: the
  producer/consumer pilot behind `vars.CI_PERSISTENT_MAC_COMPILE`, which is
  unset.
- **Four minis** hold the compile lane's peak. **One** (issue #13491) is the
  canary and is worth roughly 1.0-1.3 servers of relief on its own.
- The minis never become required-CI runners. They produce a compile artifact
  that a hosted job revalidates. That is what keeps a public repo safe.

## 1. Measured demand

All numbers below come from one 12-hour window and are reproducible. Nothing
here is an estimate unless it says so.

**Window**: 2026-09-22T10:59:35Z to 2026-09-22T22:58:29Z (12.0 h).
**Sample**: the 300 most recent `ci.yml` runs (299 `pull_request`, 1
`workflow_dispatch`); 295 completed; 287 returned jobs; 8,270 jobs total, of
which 458 are macOS jobs that actually occupied a runner.

```sh
# 1. the run list
gh run list --repo manaflow-ai/cmux --workflow ci.yml --limit 300 \
  --json databaseId,createdAt,updatedAt,status,conclusion,event,headBranch

# 2. per-job timing for each completed run id
gh api "repos/manaflow-ai/cmux/actions/runs/$ID/jobs?per_page=100" \
  --jq '[.jobs[]|{name,status,conclusion,created_at,started_at,completed_at,labels,runner_name}]'
```

Queue wait is `started_at - created_at`; service time is
`completed_at - started_at`. A job whose service time is under 20 s is a
skipped or instantly-cancelled job: it never held a runner, and it is excluded
from every service and concurrency figure below. Including them is what makes
naive medians read 0.0.

### 1.1 Where the macOS minutes go

Per-day figures extrapolate the 12-hour window by 2x. Minutes are job
execution minutes, not billed minutes.

| Lane | Executed in | Service p50 | Service p90 | min/day | Share |
| --- | ---: | ---: | ---: | ---: | ---: |
| `app-host unit tests` (6 shards) | 9% of runs | 21.5 | 92.1 | 11,223 | 55% |
| `macOS compile admission` | **41% of runs** | **20.8** | **28.3** | 4,972 | 24% |
| `tests-build-and-lag` | 9% of runs | 11.2 | 104.2 | 1,484 | 7% |
| `cli-pipe-regressions` | - | 4.5 | 7.7 | 1,044 | 5% |
| `release-build` | 6% of runs | 26.1 | 36.3 | 886 | 4% |
| `swift-package-tests` | 13% of runs | 4.3 | 19.7 | 699 | 3% |
| **Total macOS** | | | | **20,313** | |

20,313 min/day is **339 macOS job-hours per day**.

The "executed in" column is the load-bearing one. `CI_PULL_REQUEST_SUITE` is
set to `compile-only`, so a pull-request run normally carries exactly one
macOS job (`scripts/ci/choose_ci_suite.py`); the full suite runs on
`merge_group`, on `main`, and on PRs carrying the `full-ci` label. The policy
works: the full suite executed on 9% of runs. But those 9% still cost 55% of
the macOS minutes, while compile admission runs on 41% of runs for 24%.

That asymmetry decides lane order. Compile admission is not the biggest
consumer; it is the **universal** one. It is what every contributor waits on,
on every push, and it is the only macOS job on the critical path of a normal
PR.

### 1.2 Why the queue is 1-3 hours

Split by pool (`labels[0]` on each job):

| Pool | Executed jobs | min/day | Mean concurrency | Peak concurrency |
| --- | ---: | ---: | ---: | ---: |
| `blacksmith-6vcpu-macos-15` | 323 | 16,157 | **13.61** | 64 |
| `warp-macos-15-arm64-6x` | 115 | 3,264 | 4.20 | 36 |
| `warp-macos-26-arm64-12x` | 9 | 448 | 0.67 | 4 |
| `blacksmith-6vcpu-macos-26` | 11 | 443 | 0.58 | 5 |

`blacksmith-6vcpu-macos-15` is the pull-request lane, because `MACOS_RUNNER_PR`
is unset and every PR macOS job falls back to it
(`ci-macos.yml:57,878,2404,2773`). The required/`main` lanes currently point at
Warp (`MACOS_RUNNER_15=warp-macos-15-arm64-6x`), so PR pain and release pain
are separate problems and only the first one is in scope here.

Offered load on that pool, by Little's law over the window:

```
16,157 min/day / 1,440 min/day = 11.22 busy servers
```

Against a cap of 9-13, utilization is **rho = 0.86 to 1.25**. A multi-server
queue does not degrade gracefully near rho = 1; it degrades vertically. The
observed waits are exactly that shape:

| Blacksmith macOS-15 queue wait | minutes |
| --- | ---: |
| p50 | 4.9 |
| p90 | 64.0 |
| p99 | 123.6 |
| max | 167.7 |

And the backlog, swept over `created_at -> started_at` for every macOS job:

- peak macOS jobs waiting simultaneously: **43**
- mean queue depth: **8.60**
- fraction of wall-clock with >= 10 waiting: **36.6%**
- fraction of wall-clock with >= 20 waiting: **15.9%**

Arrivals are bursty: median **49** macOS jobs queued per hour, peak **220** in
the 13:00Z hour. A pool sized for the mean is underwater for a third of the
day.

For compile admission specifically on that pool (n=85): service p50 21.7 /
p90 31.6 min, queue p50 7.5 / p90 60.7 / max 167.7 min. The RFC's "20-35 min
long pole" is confirmed at p50-p90.

### 1.3 How many minis

The mini does not take the required job. It runs
`.github/workflows/persistent-macos-compile.yml`, produces a compiled Debug
product, and the required hosted `macOS compile admission` job downloads and
revalidates it. So the fleet does not add hosted slots. It **shortens the
hosted job**, which reduces offered load, which is the same lever.

Per-job saving, from #13198's measurements plus the service times above: the
compile step is 14.5 min of the ~21.7 min job; the remainder is checkout,
cache restore, warning validation and product publication, which the hosted
job still does. A validated producer artifact turns a ~21.7 min job into a
~7 min job.

```
236 compile admissions/day x 14.7 min saved = 3,469 min/day
3,469 / 1,440                               = 2.41 servers removed
offered load 11.22 - 2.41                   = 8.81 servers
```

At a 13-slot cap that is rho = 0.68, which queues negligibly. At a 9-slot cap
it is rho = 0.98, which does not. **The compile lane alone fixes the queue only
if the Blacksmith cap is at the top of its range** - confirming the cap is the
first thing to measure during rollout (section 5).

Fleet size follows from the producer's own arrival rate, not from the hosted
pool. Producer compiles are warm: #13091 measured 35.7 s exact-warm, 620 s
near-warm, 953 s cold on comparable hardware. Assume a **5 min mean** across a
realistic mix of `hot` / `partially-warm` / `cold-reset`.

| Minis | Peak capacity | Expected producer hit rate | Hosted servers removed | rho at cap 13 |
| ---: | ---: | ---: | ---: | ---: |
| 1 (the #13491 canary) | ~12 compiles/h | 40-55% | 1.0-1.3 | 0.77 |
| 2 | ~24/h | 60-70% | 1.4-1.7 | 0.74 |
| 3 | ~36/h | ~80% | 1.9-2.2 | 0.70 |
| **4** | **~48/h** | **>90%** | **2.2-2.4** | **0.68** |

Peak demand sets the number. Compile-admission arrivals average ~10/h but the
observed 4.5x burst factor (220 vs 49 macOS jobs/h) puts the peak near
**45 compile requests/h**, which at 5 min each is **3.75 mini-equivalents**.
Four minis cover the peak with headroom; three cover it with none.

The hit rates are the one estimate in this document. They are bounded above by
the fraction of PRs from `MEMBER`/`OWNER` authors on same-repository branches
(everything else never routes) and reduced further by the producer's
nonblocking observation: `--ready-only` adopts a producer only if its compile
is *already complete* when the hosted job checks. Measure them, do not trust
them (section 5).

### 1.4 Lane order

1. **`macOS compile admission`** - move first. Built, universal, 24% of pool
   minutes, no GUI, no secrets, and the artifact is revalidated. Four minis.
2. **`swift-package-tests`** - move second, and only after lane 1 has receipts.
   13% of runs, 699 min/day, 4.3 min p50, no GUI session needed. Small, but it
   is the same producer shape and the marginal cost of a second lane is one
   more producer workflow. Note that the guard's exemption is **two byte-exact
   strings** (`tests/test_ci_self_hosted_guard.sh:1215-1219`), so a second
   owned-Mac lane is a deliberate guard edit, not an accident.
3. **`app-host unit tests`** - do **not** move to minis, despite being 55% of
   the minutes. It needs a foreground GUI session, it is six shards of
   XCTest, and it is a required check. Its home is the isolated Tart pool
   (18 slots, `ci-runners.md`), where each job gets a fresh VM clone and an
   Aqua login session. A shared mini cannot give it either.
4. **`release-build`, signing, notarization, nightly, TestFlight** - never.
   Unchanged from `ci-runners.md`.

## 2. Security

cmux is a public repository. A fork pull request can propose arbitrary
workflow YAML, including `runs-on:`. Every control below exists because of
that single fact.

### 2.1 What is already enforced

| Control | Where |
| --- | --- |
| Producer is `workflow_dispatch`-only | `check_persistent_compile_lane` |
| Producer has `permissions: {}` at workflow and job level | same |
| Producer references no `secrets.` and no `actions/checkout@` | same |
| Glaeda pinned to an exact 40-hex commit | same |
| Only the default-branch router holds `actions: write` | `check_persistent_compile_router` |
| Router checkout pins `ref: main`, `persist-credentials: false` | same |
| PR-side observation is `--observe-only --ready-only`, no wait budgets | same |
| No required job may name a fleet label or a bare self-hosted runner | `check_no_self_hosted_fleet_runners` |
| All four author-association gates are derived from source and compared | `test_every_author_association_gate_matches_the_producer` |
| Live re-verification of PR state, head, base, merge and tree | `test_live_reverification_accepts_only_the_exact_requested_source` (added here) |
| Producer discovery requires the exact run-name on `main` | `test_producer_discovery_requires_the_exact_dispatch_title_on_main` (added here) |
| One timed compile per PR on the hosted toolchain | `check_persistent_compile_owned_mac_occupancy` (added here) |

### 2.2 The three gates a fork PR must pass, and cannot

1. **The runner group.** The owned Mac joins the organization-owned
   `cmux-persistent-compile` group, whose workflow access is restricted to
   `manaflow-ai/cmux/.github/workflows/persistent-macos-compile.yml@refs/heads/main`.
   A fork's modified copy of that workflow is a different ref and cannot
   acquire the runner. **This is the external scheduling boundary and it is the
   only one a repository-side guard cannot enforce** - it is GitHub
   organization configuration, and it must exist before the variable is set.
2. **The trust gate.** `head.repo.full_name == github.repository` and
   `author_association in {MEMBER, OWNER}`, asserted identically in `ci.yml`,
   `ci-macos.yml`, `scripts/ci/persistent_mac_route.py` and the producer's own
   `authorize` job. A fork PR fails the first clause before anything is
   dispatched.
3. **The dispatch path.** PR CI has read-only Actions permission. It publishes
   a request artifact; the default-branch `persistent-macos-router.yml`
   validates that artifact against a live read of the PR and owns dispatch.
   A PR cannot dispatch the producer even if it could pass gates 1 and 2.

### 2.3 Ephemeral runner, clean workspace, no persistent credentials

**Ephemeral registration is not yet satisfied on macOS and this document does
not claim otherwise.** Glaeda's JIT-runner work (glaeda #1008-#1010, merged as
#1017/#1053) gives a per-job clean workspace and a zeroizing JIT config, but it
is **Linux-only**: it is built on bubblewrap and `systemd-run`, pins
`actions-runner 2.336.0 linux-x64`, and was proven on Big Red. There is no
macOS equivalent primitive. See section 4 for what that means for the design.

What the macOS producer does instead, today:

- **Clean workspace per job by reconstruction, not by destruction.** The
  producer's `Prepare exact cmux source` step re-inits the checkout if the
  remote is wrong, hard-resets, resets and cleans every submodule, and then
  asserts `HEAD == source_sha`, `HEAD^{tree} == source_tree`,
  `parent1 == source_parent1`, `parent2 == head_sha` and a clean
  `status --porcelain --untracked-files=all`. Hot state is *retained
  deliberately* - that is the whole point - and `.glaeda/` and
  `GhosttyKit.xcframework` are excluded from the clean. State is acceleration,
  never authority.
- **No persistent credentials.** `permissions: {}`, no `secrets.`, public
  `git fetch` instead of `actions/checkout`. The runner registration token is
  the runner's own and belongs to the group, not to the job.
- **Bounded state growth.** `run-persistent-mac-compile.py` retains 3 cache
  generations and 1 quarantine store, never evicting the generation in use.

### 2.4 What a compromised producer job could reach

A job on the mini runs as the operator account on a machine that also holds
the canonical checkout, warm DerivedData, developer caches and, if the machine
is also enrolled as an artifact peer (glaeda #1068), a runner-local peer read
token. It has network egress.

Reachable: the mini's filesystem under that account; other callers' warm state
on the same machine; the LAN; any artifact-peer token file present.

Not reachable: repository secrets (none are passed); Actions write (the job
has `permissions: {}`); the required check's verdict (the hosted job revalidates
revision, tree, `Package.resolved`, submodules, Xcode, SDK, architecture,
Glaeda lineage, warning budget and CLI probes before adopting anything, and
compiles hosted on any mismatch).

The residual risk is therefore **not** "a fork PR poisons a build". It is "an
org member with push access, who already has push access, can persist something
on a shared machine". That is the same trust boundary the repository already
extends, stated plainly in #13198. It is bounded by per-runner account
isolation and by the fact that the mini holds nothing a member could not
already obtain.

**This is why the fleet must never carry a required job directly.** The moment
a mini's result is the verdict rather than an input to a revalidating job, the
blast radius changes from "wasted minutes" to "false green".

## 3. Operations

### 3.1 Enrollment and re-enrollment

Owned entirely by Glaeda; follow [`fleet-enrollment.md`](../fleet-enrollment.md)
verbatim. The repository side adds nothing. The lifecycle actually implemented
(glaeda #1067) is:

```
discovered -> enrolling -> eligible -> draining | quarantined -> retired
             ^                            |            |
             |                            v            |
             +------ (generation bump) ---+------------+
```

Leaving `quarantined` advances the enrollment generation, which stales every
pre-quarantine acceptance receipt. Re-enrollment is therefore not a shortcut:
it re-runs `accept-local` and mints a fresh
`glaeda-cmux-fleet-acceptance/v2` receipt. `automaticDispatchAuthorized`
remains `false` throughout; enrollment makes a node a routing *candidate*, not
a dispatch target.

Registering the GitHub Actions runner is a **separate** step that
`fleet-enrollment.md` explicitly does not perform. A mini that is `eligible`
in Glaeda is not yet a runner.

### 3.2 Labels and runner group

Exactly one group and one label set, byte-for-byte, because the guard compares
them literally:

```yaml
runs-on:
  group: cmux-persistent-compile
  labels: [self-hosted, macOS, ARM64, cmux-persistent-macos-compile]
```

Group policy (organization settings, maintainer-only): allow the public
`manaflow-ai/cmux` repository; restrict workflow access to
`manaflow-ai/cmux/.github/workflows/persistent-macos-compile.yml@refs/heads/main`.

Do **not** add these labels to the physical fleet records named in
`ci-runners.md` (`cmux-mac-mini`, `studio1`, `mac4-cmuxvnc*`,
`cmux-austin-mini-*`). A runner in the restricted group is a new registration,
not a relabelled dev-build machine.

### 3.3 Xcode versions

The mini must carry the exact app at `vars.CMUX_CI_XCODE_APP_PR ||
vars.CMUX_CI_XCODE_APP_MACOS_15` with a macOS SDK major of 26, and
`scripts/select-ci-xcode.sh` must resolve it. `scripts/persistent-compile`
reads those variables rather than a copy of the path, so `up` and the doctor
check each mini against the value CI uses today and print it.
The build number matters too: revalidation compares the full `xcodebuild
-version`, so the mini's Xcode must be the same build as the hosted image's.

Drift is now a guard failure rather than a silent waste:
`check_persistent_compile_owned_mac_occupancy` compares the producer's
`CMUX_CI_XCODE_APP` / `CMUX_CI_REQUIRED_MACOS_SDK_MAJOR` against
`macos-compile-admission`'s. A mismatch does not produce a wrong build - the
hosted job refuses the artifact with `Xcode identity mismatch` - but every
producer run would burn an owned-Mac allocation to make something certain to be
rejected.

Upgrade order, when the repository variable moves:

1. Drain every mini (3.5).
2. Install the new Xcode alongside the old one; do not remove the old one yet.
3. Re-run `accept-local`; a toolchain-generation change stales the role canary.
4. Set the repository variable.
5. Undrain one mini, watch one PR's `classification` in the admission metrics
   (expect `cold-reset` on the first compile after a toolchain change), then
   undrain the rest.

Rolling the variable before the fleet has the Xcode is safe but useless: every
producer run is rejected and every PR falls back to hosted.

### 3.4 Disk and DerivedData hygiene

Owned by `scripts/ci/run-persistent-mac-compile.py`, which is the only
janitor. It retains `CACHE_RETAINED_GENERATIONS = 3` generations under
`.glaeda/apple-build/cache/<64-hex>/` and `QUARANTINE_RETAINED_STORES = 1`
quarantine store, stamping the generation in use with `os.utime` immediately
before pruning so LRU cannot evict it. Evictions are logged and recorded in
the admission metrics as `pruned_cache_generations`.

Each generation is a full cmux DerivedData tree. Budget conservatively:
**3 generations x ~40 GB plus the checkout plus the toolchains**, and keep the
free-space floor above one full cold build.

Do not add a second cache janitor. glaeda #1095 says the same thing from the
other side: hygiene feeds the existing `reusable_state_lifecycle` path rather
than growing a parallel cleaner.

### 3.5 Detecting and draining a sick runner

**Automatic drain, repair and quarantine do not exist.** glaeda #1058 specifies
them and glaeda #1095 specifies the autopilot, but only the state machine and
the read-only `glaeda-cmux-fleet-operator-summary/v1` projection (#1096) have
landed. Everything below is a manual operator command today. Do not write a
second drain mechanism in this repository; the primitive belongs in Glaeda.

Symptoms, in the order they show up:

| Symptom | Where it appears | Meaning |
| --- | --- | --- |
| `fallback_reason=producer_not_ready` on most PRs | admission metrics artifact | mini is offline, saturated, or slower than the hosted job's check |
| `classification=cold-reset` every run | admission metrics | warm state is being discarded; check the clean/reset path and disk |
| `fallback_reason=producer_failure` | admission metrics | producer ran and failed; read its run |
| `Xcode identity mismatch` in revalidation | hosted job log | toolchain drift; see 3.3 |
| Producer queued > `CI_PERSISTENT_MAC_QUEUE_SECONDS` | router summary | fleet is undersized or wedged |

Sweep for the last 50 PR runs:

```sh
gh run list --repo manaflow-ai/cmux --workflow ci.yml --limit 50 \
  --json databaseId --jq '.[].databaseId' | while read -r id; do
  gh run view "$id" --repo manaflow-ai/cmux --log 2>/dev/null |
    grep -o 'fallback_reason=[a-z_]*' || true
done | sort | uniq -c | sort -rn
```

Drain one mini, on the mini:

```sh
scripts/persistent-compile drain          # waits for a running job; --now does not
scripts/persistent-compile resume         # back to eligible, service started
```

**Draining in Glaeda does not stop GitHub from assigning jobs** - they are
separate control planes, and this is the sharpest operational trap in the
whole design. `drain` does both: it moves the enrollment to `draining` and,
once the runner is idle, stops and disables its launchd agent so it stays
stopped across logins and reboots. A job GitHub assigns in the seconds between
the last one ending and the stop is cancelled and falls back to the hosted
compile. Until glaeda #1058's drain
primitive lands, do not drain with `cmux_fleet.py transition-apply` alone; that
leaves the machine taking work.

Quarantine, on the mini, with one of the eight reviewed reasons
(`toolchain_mismatch`, `disk_pressure`, `failed_acceptance`,
`dirty_canonical_checkout`, `service_mismatch`, `hardware_failure`,
`stale_glaeda_generation`, `unexplained_process_settlement`):

```sh
scripts/persistent-compile quarantine disk_pressure   # --now does not wait for a running job
scripts/persistent-compile up                         # once fixed: re-runs acceptance, then starts the runner
```

Like `drain`, it moves Glaeda and stops the runner. Quarantining with
`cmux_fleet.py transition-apply` alone has the same trap as draining with it.

### 3.6 When a mini is offline

PRs still pass, but each routed one wastes a little. The PR publishes its
route request, the router dispatches a producer, and the producer's job waits
for a runner that never comes. After `CI_PERSISTENT_MAC_QUEUE_SECONDS` (90 by
default) the router cancels it and records `queue_timeout`. Meanwhile the hosted
job's `--observe-only --ready-only` probe has already reported
`producer_not_ready` and compiled hosted without waiting. `route.fallback()`
always returns 0: a hosted fallback is not an error.

So an offline fleet costs one Linux router job of about 90 seconds per routed
PR, not a slower check. `scripts/persistent-compile` reports routing that is on
with no healthy runner, and `all` asks before it turns routing on in that state.

The other failure mode is "the fleet is up, slow, and every PR pays the
observation without getting the artifact". That costs seconds, not minutes, but
shows up as a hit rate near zero in the metrics.

Full stop, one command, no deploy:

```sh
scripts/persistent-compile off
```

## 4. Who owns what

Glaeda owns the machine. This repository owns the routing and the guards. The
split matters because the two have different threat models: Glaeda's sandbox
work was proven on a private Linux host, and cmux is a public repository.

| Concern | Owner | State |
| --- | --- | --- |
| Machine enrollment, acceptance receipts, role eligibility | Glaeda (#1056, PRs #1067/#1088/#1091 merged) | landed; no physical Mac receipt yet |
| Enrollment lifecycle and transition commands | Glaeda (#1067) | landed |
| Physical execution lease, multi-orchestrator interop | Glaeda (#1057) | admission half landed (#1072/#1084); lease acquisition and the two-caller proof are not |
| Drain / quarantine / repair / retire | Glaeda (#1058, #1095) | state machine only; drain primitive, auto-repair and autopilot not implemented |
| JIT / ephemeral runner inside a task sandbox | Glaeda (#1008-#1010, merged #1017/#1053) | **Linux only**; no macOS equivalent |
| Same-site immutable artifact distribution | Glaeda (#1068, #1103) + cmux #13540 | contract landed; physical two-node benchmark pending |
| Warm-slot generation handoff | cmux #13091 (#13398) | landed |
| Producer workflow, router, route script | **cmux repo** | landed, never run |
| Fork-PR exclusion, author association, same-repo gates | **cmux repo** | landed and guarded |
| Runner labels and group naming | **cmux repo** (names) + org settings (policy) | names landed; group does not exist |
| Xcode pinning and drift detection | **cmux repo** | pin landed; drift guard added in this PR |
| Hosted fallback to Blacksmith | **cmux repo** | landed and guarded |
| Capacity sizing and lane order | **cmux repo** (this document) | new |

### 4.1 Where Glaeda's plan does not satisfy a public repository

Four gaps, stated so nobody assumes the Linux work transfers:

1. **The JIT-runner sandbox is explicitly owner-trusted-only.** glaeda #1008
   and #1010 both state the non-goal in their own words: owner-trusted internal
   repository jobs, no fork or untrusted PRs. The hostile-execution boundary is
   a different issue (#365 M4) and is not in that set. Do not cite #1010 as
   evidence that a mini could safely run fork PRs.
2. **The trust gate there is a runner label, and `runs-on:` is fork-editable
   text on a public repo.** The Linux design admits jobs by label
   (`glaeda-big-red-trusted`) with no fork/untrusted-ref discriminator at
   admission. cmux compensates with something Glaeda does not have: a
   workflow-restricted runner group pinned to one workflow file on
   `refs/heads/main`, plus four independently guarded author-association gates.
   **That group policy is load-bearing.** Without it the label is the only gate,
   and the label is not a gate on a public repo.
3. **Network containment is deferred.** The JIT adapter introduces
   `github_actions_trusted_egress` and records shared-host networking as
   trusted-only; exact hostile-LAN isolation is acknowledged as downstream. A
   mini on the office LAN with egress is fine for member-authored compiles and
   is not a containment story for anything else.
4. **Artifact-peer tokens assume fork jobs never land on enrolled nodes.**
   glaeda #1068 correctly keeps the peer read token in a runner-local file so
   hosted and fork runners take the ordinary path. That invariant is *assumed*,
   not enforced. If a mini is ever both an artifact peer and a runner, the
   "fork PRs never reach this machine" property is what protects the token -
   which is gate 1 and gate 2 above, again.

There is no macOS ephemeral-runner primitive anywhere in either repository.
The honest statement of this design is: **the macOS fleet is a persistent,
credential-minimized, artifact-producing machine whose output carries no
authority, not an ephemeral runner.** If per-job macOS isolation is ever
required, the existing Tart pool provides it (fresh VM clone per job, deleted
after) and is where that requirement belongs.

## 5. Rollout

`scripts/persistent-compile` runs every step below that can be scripted. Run
it with no arguments from anywhere to see what is set up and the one command
to run next. Commands that change something show their plan and ask first
(`-y` skips the question).

| Who | Where | Command |
| --- | --- | --- |
| Org admin | anywhere with `gh` | `scripts/persistent-compile group` |
| Operator | the mini, in a cmux checkout | `scripts/persistent-compile up --node-id cmux-mac-NNN` |
| Maintainer | anywhere | `scripts/persistent-compile pilot <PR>`, later `all` |

Before `up`, reserve the mini through its existing owner (#13491 step 1); `up`
does not take machines from other schedulers. `up` clones Glaeda if needed and
runs `glaeda-mini-setup`. It then downloads the reviewed Glaeda candidate
pinned in `scripts/ci/persistent_compile_fleet.py` (`CANDIDATE_*`) and has
`glaeda-mini-enroll` verify and stage those exact bytes, then enroll and
accept the mini with them; no Rust is built on the node. Last, it registers
the runner and starts it. It stops at the first
step that needs sudo or a human, prints that step, and resumes from there when
run again. It refuses to register a mini whose Glaeda enrollment is not
`eligible`. The runner is the pinned `actions-runner` (sha256 checked) in
`~/actions-runner-cmux-persistent-compile`, registered with the exact labels in
3.2 and run as a launchd agent. The registration token comes from the
operator's `gh` login. An operator who is not an org admin gets one from an
admin instead: the admin runs `scripts/persistent-compile token`, and the
operator runs `CMUX_RUNNER_TOKEN=<token> scripts/persistent-compile up`. The
token is valid for one hour.

### Stage 0 - preconditions (maintainer only)

- [ ] Organization runner group `cmux-persistent-compile` exists, allows this
      public repository, and restricts workflow access to
      `.../persistent-macos-compile.yml@refs/heads/main`.
- [ ] One M4 Pro mini enrolled through `fleet-enrollment.md` with a green
      `glaeda-cmux-fleet-acceptance/v2` receipt and state `eligible` (#13491).
- [ ] That mini registered as an Actions runner in that group with exactly the
      labels in 3.2.
- [ ] The Xcode that `scripts/persistent-compile` names from the CI
      variables present and selected by `scripts/select-ci-xcode.sh`.
- [ ] Free space above one full cold build plus three cache generations.

### Stage 1 - canary, one mini, one lane, one PR

```sh
scripts/persistent-compile pilot 13198
```

That sets `CI_PERSISTENT_MAC_COMPILE=pilot` and
`CI_PERSISTENT_MAC_COMPILE_COHORT=13198`.

`pilot` + a cohort restricts routing to matching PR numbers or head branch
names. Every other PR is untouched. Leave it here for at least 20 routed runs.

Record `gh variable list --repo manaflow-ai/cmux` before and after; the queue
numbers in section 1 are only comparable against a known pool configuration.

### Stage 2 - widen to all trusted PRs

Only after Stage 1 meets every one of these, read from the
`macos-compile-admission-metrics-*` artifact:

| Signal | Threshold |
| --- | ---: |
| Producer adoption rate (`use_persistent=true`) | >= 60% of routed runs |
| `total_macos_compile_admission_seconds` p50 | <= 9 min (from 20.8) |
| Revalidation refusals | 0 |
| `classification=cold-reset` share | <= 20% |
| Wrong-verdict incidents | 0, non-negotiable |
| Added latency on fallback runs | <= 30 s |

```sh
gh variable set CI_PERSISTENT_MAC_COMPILE --repo manaflow-ai/cmux -b all
gh variable delete CI_PERSISTENT_MAC_COMPILE_COHORT --repo manaflow-ai/cmux
```

Then re-run the section 1.2 measurement and compare offered load and queue
p90/p99 directly. **The decision to buy more minis is the Stage 2 measurement,
not this document's table.** If offered load does not fall by the predicted
~2.4 servers, the model in 1.3 is wrong and the fleet should not grow.

### Stage 3 - widen the fleet

Enroll minis 2 through 4 one at a time, re-measuring adoption rate after each.
Stop when adoption rate stops rising: that is the point where the fleet covers
the burst and a further mini buys nothing.

### Rollback

Any stage, one command, effective on the next run, no deploy and no revert:

```sh
gh variable set CI_PERSISTENT_MAC_COMPILE --repo manaflow-ai/cmux -b off
```

The hosted path is never removed and is always the fallback. A revert of the
workflow files is never the rollback; the variable is.

## 6. Maintainer versus contributor

| Action | Who |
| --- | --- |
| Create/configure the `cmux-persistent-compile` runner group; set its workflow restriction | **Maintainer / org admin only.** Not expressible in the repository. |
| Register or remove a self-hosted runner | **Maintainer.** `repos/.../actions/runners` returns 403 without the runners permission. |
| Set `CI_PERSISTENT_MAC_COMPILE`, `..._COHORT`, `..._QUEUE_SECONDS`, `..._EXECUTION_SECONDS` | **Maintainer.** Repository variables require admin. |
| Move `CMUX_CI_XCODE_APP_MACOS_*` or any `MACOS_RUNNER_*` | **Maintainer.** |
| Physically enroll a mini, run `accept-local`, drain, quarantine | **Operator with machine access.** Not a repository action. |
| Edit the producer/router workflows, the route script, the guards | Write access. Effect is gated by the variable being unset. |
| Add a lane, change labels, change the concurrency key or timeout | Write access, but `check_persistent_compile_owned_mac_occupancy` and `check_no_self_hosted_fleet_runners` must be updated deliberately. |
| Change the author-association set | Write access, but all four gates must move together or `test_every_author_association_gate_matches_the_producer` fails. |
| Read metrics, measure the queue, propose sizing | Anyone. Every command in section 1 is read-only. |

A contributor with write access can build and test the entire routing path
with the variable unset, which is exactly the state the repository is in
today. Nothing they merge takes effect until a maintainer sets one variable.

## 7. Open gaps

- The organization runner group does not exist, so the producer has never run
  (`docs/ci/workflow-inventory.md` line 21). The router has 6,887 skipped runs
  out of 6,927 and zero successes: it creates one run per CI run and exits on
  the unset variable.
- No physical `cmux_macos_native_build` acceptance receipt exists yet
  (#13491, glaeda #1056 checklist).
- No drain primitive: Glaeda's state flag does not stop GitHub assignment
  (3.5). glaeda #1058.
- No automatic quarantine, repair or hygiene. glaeda #1095.
- No macOS ephemeral-runner primitive anywhere (4.1).
- The router's own shell logic - artifact polling, the duplicate-artifact
  failure, the 30 s status poll, the envelope validator - is string-matched by
  tests but never executed.
- The producer's queue and execution observation loops (`queue_timeout`,
  `execution_budget_exceeded`, `producer_timing_unavailable`) are untested.
