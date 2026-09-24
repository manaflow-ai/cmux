# CI runners

Every CI/CD job picks its runner from a repository variable instead of a
hardcoded label. Changing a runner type is a single repository-variable update
that takes effect on the next workflow run.

Linux uses Blacksmith. macOS uses Blacksmith cloud runners. The self-hosted
Tart fleet described below carries specific lanes as they are qualified. WarpBuild is paid overflow and is
not a steady state for any lane. Non-urgent macOS work also uses free
GitHub-hosted runners through the background lane described below.

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
| `MACOS_RUNNER_15` | the macOS 15 default: `macos-compile-admission`, non-PR `app-host-unit-tests`, nightly helper and test-cache jobs, `iroh-release-gate.yml` streamed validation | `blacksmith-6vcpu-macos-15` | `blacksmith-6vcpu-macos-15` |
| `MACOS_RUNNER_PR` | **pull-request** macOS jobs in `ci-macos.yml` (the app-host shards and `tests-build-and-lag` follow `macos-compile-admission`), `cli-pipe-regressions.yml`, `terminal-hang-diagnostics.yml`, `ci.yml` (`claude-wrapper`) and `nightly.yml` (`refresh-test-compilation-cache`) | unset (see "Lanes" below) | `blacksmith-6vcpu-macos-15` |
| `MACOS_RUNNER_TESTS` | test-only lanes that pick their Xcode by SDK and sign nothing: `test-e2e.yml`, `test-macos-suite.yml`, `test-ios.yml` (`auto`) and the `iroh-v2.yml` client | unset (see "Lanes" below) | each lane's own variable or Blacksmith label: `blacksmith-6vcpu-macos-26` for `test-e2e.yml`, `blacksmith-6vcpu-macos-15` for `test-macos-suite.yml`, `MACOS_RUNNER_IOS` for `test-ios.yml` and `iroh-v2.yml` |
| `MACOS_RUNNER_DUAL_XCODE` | `swift-package-tests` (SDK 15 release helper, then SDK 26 package tests) on **every** event, pull requests included | `blacksmith-6vcpu-macos-15` | `blacksmith-6vcpu-macos-15` |
| `MACOS_RUNNER_26` | the macOS 26 image: compatibility jobs, `release.yml` and nightly sign/notarize, the disk-heavy `release-build` universal app, and the nightly compilation-cache warmer | `blacksmith-6vcpu-macos-26` | `blacksmith-6vcpu-macos-26` |
| `MACOS_RUNNER_26_LARGE` | the larger macOS 26 machine: changed-revision universal Nightly app builds | `blacksmith-12vcpu-macos-26` | `blacksmith-12vcpu-macos-26` |
| `MACOS_RUNNER_DISPLAY` | macOS GUI, XCUITest, and virtual-display tests (`tests-build-and-lag`) | `blacksmith-6vcpu-macos-15` | `blacksmith-6vcpu-macos-15` |
| `MACOS_RUNNER_IOS` | the iOS image: simulator tests, TestFlight upload, and `ios-streamed-validate.yml` (`test-ios.yml`, `ios-testflight.yml`) | `blacksmith-6vcpu-macos-26` | `blacksmith-6vcpu-macos-26` |
| `CI_PAID_MACOS_OVERFLOW` | the repository-side switch for metered capacity; gates the four paid-overflow variables above (see "Break-glass" below) | unset (free capacity) | unset means the Blacksmith fallback wins |
| `MACOS_RUNNER_BACKGROUND` | non-urgent macOS work only: `build-ghosttykit`, the macOS legs of `cmux-tui-artifacts` (post-merge) and `cmux-tui-nightly` (on demand). See "Background lane" below | unset | `macos-15` (GitHub-hosted, free) |

A runner variable names a **machine capability** — an OS version, a GUI, a
simulator, both SDKs, or a larger instance — and every job needing that
capability reads the same one. It does not name the lane asking, which the
workflow already knows. `MACOS_RUNNER_PR` and `MACOS_RUNNER_TESTS` are the
deliberate lane exceptions documented below.

Two capability variables may hold the same label today and still mean different
things. `MACOS_RUNNER_26` and `MACOS_RUNNER_26_LARGE` both name macOS 26,
while the latter requires the larger instance.

The paid-overflow gate and the runner-value policy answer different questions.
`CI_PAID_MACOS_OVERFLOW` covers only variables whose purpose is paid overflow.
Other variables, including `MACOS_RUNNER_26`, are checked by
`scripts/ci/runner_label_policy.py` through the CI health report. Gating a free
pool would make repointing it at owned hardware require enabling a flag whose
meaning is permission to spend.

The pull-request lane also has a toolchain variable, set together with
`MACOS_RUNNER_PR`:

| Variable | Used by | Intended steady state | Falls back to |
| --- | --- | --- | --- |
| `CMUX_CI_XCODE_APP_PR` | the Xcode pin of the pull-request jobs that *select a pinned Xcode*: `macos-compile-admission`, `app-host-unit-tests`, `tests-build-and-lag`, `cli-pipe-regressions`, the `nightly.yml` cache seed, and `ci.yml`'s pull-request build-input fingerprint | unset (see "Lanes" below) | `CMUX_CI_XCODE_APP_MACOS_15` |

Not every job on the pool reads it. `ci.yml`'s `claude-wrapper` never selects an
Xcode, and the two `terminal-hang-diagnostics.yml` jobs run
`scripts/select-ci-xcode.sh` with no pin of their own, so they take the pool
pin described next.

### Which Xcode a job gets

Every macOS job that uses Xcode runs `scripts/select-ci-xcode.sh`, and
`tests/test_ci_macos_xcode_selection.py` fails when one does not. The script
chooses, in order:

1. the job's own `CMUX_CI_XCODE_APP` (the lane variables above), if set;
2. otherwise the version `scripts/ci/xcode-pins.txt` names for the runner's
   macOS major: Xcode 26.3 on macOS 15 and Xcode 26.6 on macOS 26 today.

Either way it stops with one `::error::` when the Xcode is below the major in
`.xcode-version` (26), or when the pinned Xcode is not installed, instead of
building with the image's default. On GitHub's `macos-15` image that default is
Xcode 16.4. When a job's own pin differs from the pool pin, the job still runs
and warns, because jobs on one pool with different Xcodes cannot share
compilation caches or products. To move a pool to a new Xcode, edit its line in
`scripts/ci/xcode-pins.txt` and the matching `CMUX_CI_XCODE_APP_MACOS_*`
variable together.

The deliberate exceptions are listed with reasons in the guard's `EXEMPT`
table: the Zig-only Ghostty builds, the macOS 14 compatibility lane, and
`relay-tls.yml`'s Xcode 16.2 job.

## Lanes

Not every macOS job follows the same variable, because not every macOS job has
the same cost profile or the same urgency.

- **Required CI on `main`, the merge queue, releases and nightly** follow the
  `MACOS_RUNNER_*` variables above. This is the lane where a slow or queued
  runner blocks a merge or a ship, so it is the lane worth paying for if paid
  capacity is ever warranted.
- **Pull requests on `manaflow-ai/cmux`** resolve through `MACOS_RUNNER_PR`
  first, except the app-host unit-test matrix. Same-repository app-host
  shards are assigned per shard across `blacksmith-6vcpu-macos-15`,
  `blacksmith-6vcpu-macos-26`, GitHub-hosted `macos-15`, and GitHub-hosted
  `macos-26`; fork pull requests keep those shards on the Blacksmith 15
  fallback. Other PR jobs still use `MACOS_RUNNER_PR`; unset means the
  Blacksmith fallback. PR runs are cancelled on supersession by design, so
  they are the wrong place to spend elastic paid capacity. A fork uses the
  GitHub-hosted branch described below instead.
- **Test-only lanes** (`test-e2e.yml`, `test-macos-suite.yml`, `test-ios.yml`
  on `auto`, the `iroh-v2.yml` client) resolve through
  `MACOS_RUNNER_TESTS` first, and deliberately do **not** follow `MACOS_RUNNER_15`.
  Setting it moves every test lane off a backed-up pool in one edit without
  touching `MACOS_RUNNER_IOS` or `MACOS_RUNNER_26`, which also route release,
  nightly, TestFlight and App Store signing. A GitHub-hosted value (`macos-15`,
  `macos-26`) is checked by each job's first step: the self-hosted fleet also
  carries a `macos-26` label, so a job that lands anywhere but GitHub-hosted
  capacity fails before checkout. `app-host-test-rerun.yml` does not follow it:
  a rerun must build with the exact Xcode the products were compiled with, so it
  stays on the Blacksmith macOS 15 pool it has always resolved to.
  Re-running one test to chase a flake should never reach for paid capacity.
  Both fallbacks stay on Blacksmith for that reason; `test-e2e.yml` falls back
  to macOS 26 because the macOS 15 pool's queue-to-start p90 was 83 min against
  1.0 min on 26, measured over 60 dispatches on 2026-09-22/23.
  `scripts/run-e2e.sh` then sends commits whose SHA ends in an odd hex digit
  to `blacksmith-12vcpu-macos-26`, so the two instance sizes are compared on
  real focused-run traffic. It splits only that free default: a
  `MACOS_RUNNER_TESTS` value naming any other pool is used unchanged.

### Pull request pool preference

When `MACOS_RUNNER_PR` is `blacksmith-6vcpu-macos-26`, `ci.yml`'s `changes`
job picks one pool for the whole pull request run with
`scripts/ci/pr_runner_pool.py`, and every pull-request macOS job in the run
reads it: compile admission and its product consumers, `tests-build-and-lag`,
`claude-wrapper`, `cli-pipe-regressions.yml` and `remote-daemon.yml`. A run is
never split across pools, so the app-host product always meets the Xcode that
linked it. The run takes the first pool in `CI_PR_POOL_ORDER` with fewer than
`CI_PR_POOL_MAX_QUEUED` (default 3) jobs queued and no queued release or
nightly job, or else the pool with the fewest queued jobs. The macOS 15 pool
counts 12 more queued jobs than it has (`COLD_QUEUE_PENALTY`): the DerivedData
seed exists only for the lane's Xcode, so a run there compiles cold, 10 to 20
minutes longer, while a queued job on a macOS 26 pool waits about a minute.
It never has headroom, and it wins the fewest-queued fallback only when both
macOS 26 pools are queued 12 deeper. From 17:25Z to 18:10Z on 2026-09-24,
before this rule, every PR admission overflowed there at 3 queued and compiled
for 17 to 25 minutes against a 321 s seeded median.

| Variable | Default | Meaning |
| --- | --- | --- |
| `CI_PR_POOL_OVERFLOW` | unset (on) | `0` turns the preference off; every job takes its `MACOS_RUNNER_PR` route |
| `CI_PR_POOL_ORDER` | `blacksmith-12vcpu-macos-26,blacksmith-6vcpu-macos-26,blacksmith-6vcpu-macos-15` | preference order; only pools whose Xcode pin `pr_runner_pool.py` knows are accepted, and an unknown label turns the preference off |
| `CI_PR_POOL_MAX_QUEUED` | `3` | a pool has headroom below this many queued macOS jobs |

The two macOS 26 pools share the lane's Xcode. A run on
`blacksmith-6vcpu-macos-15` builds with `CMUX_CI_XCODE_APP_MACOS_15`, the pool
and Xcode `main`'s own compile admission uses, and the build-input fingerprint
follows that Xcode. Every Blacksmith pool is sponsored, so cost does not rank
them; the order is speed first.

The queue comes from the queue janitor: each sweep publishes the per-pool demand
it already listed as the `macos-pool-load` artifact, and the `changes` job
reads the newest copy uploaded from `main` of this repository. Pull request
runs created since that sweep and still in flight are replayed through the
same rule first, each
filling a pool's idle slots (about 10 per Blacksmith macOS pool, less what is
running) before it counts as queued, so a burst of pushes spreads across
pools. The whole choice costs three API
requests. A snapshot older than 45 minutes, an API error, or any event other
than `pull_request` keeps today's route. The step summary of `changes` names
the pool, the reason, and the queue it saw.

A fork pull request gets no repository variables, so the janitor copies
`MACOS_RUNNER_PR` and the three settings above into the snapshot and fork runs
follow those: `CI_PR_POOL_OVERFLOW=0` or a lane other than
`blacksmith-6vcpu-macos-26` keeps them on the Blacksmith macOS 15 fallback as
before. Fork runs never pin an Xcode (each job selects its pool's newest SDK
26 Xcode) and only use ephemeral `blacksmith-*` pools.

Owned Mac minis (fleet RFC cmuxterm-hq#573) join as class pools keyed by the
label glaeda issues to a dedicated member once it has verified the pinned
Xcode build: `glaeda-<class>-xcode-<version>`, today `glaeda-std-xcode-26.6`.
The version comes from `CMUX_CI_XCODE_APP_PR`, so moving that pin moves the
pool, and no machine carries the new label until glaeda has verified the new
Xcode on it. With `CI_PR_POOL_OWNED=1` the default order is
`glaeda-std-xcode-<version>` (48 GB minis), then `glaeda-light-xcode-<version>`
(16 GB), then the Blacksmith pools as overflow. An owned pool's capacity is its entry in
`CI_OWNED_POOL_SLOTS`, and the janitor's snapshot counts the jobs queued and
running on that label. A pull request run puts several macOS jobs on its pool
at once, each on its own machine, so a run takes the owned pool only when its
own peak is free at once. The picker runs after the suite choice and counts
that peak from the run's routing: the Claude wrapper, CLI pipe and remote
daemon lanes, beside the larger of compile admission alone or what follows it
(a full suite's seven app-host shards, tests-build-and-lag and
cli-product-tests, 12 jobs in all; a changed-suites run's one shard; a CLI
change's cli-product-tests). Taken is the larger of the jobs the janitor
saw on the pool and `committed`, the peaks the runs holding it declared, so a
run whose later jobs do not exist yet still counts them. A run created since
the snapshot has an unknown peak: any that could have taken the pool is
assumed to, and charged 4 machines, a compile-only run with every side lane,
which is what the default pull request policy runs. A full-suite run among
them is under-counted until the next snapshot; a job that then finds its
mini busy is refused or queued, and the rescue below moves it to Blacksmith.
It is skipped when the snapshot is older than 20
minutes or the label has no slots, and it is never the fewest-queued fallback.
Fork runs and retry attempts never take it. While `CI_PR_POOL_OWNED` is off,
owned labels in `CI_PR_POOL_ORDER` are dropped and the rest of the order is
used; an owned label for another Xcode than the lane's pin is dropped the same
way and named in the `changes` summary. An order left empty by that turns the
preference off. A pin path that is not `/Applications/Xcode_<version>.app`
names no owned pool.

| Variable | Default | Effect |
| --- | --- | --- |
| `CI_PR_POOL_OWNED` | unset (off) | `1` puts owned pools first and turns on the rescue below |
| `CI_OWNED_POOL_SLOTS` | unset (no slots) | JSON, owned pool label to machine count, the `conforming_count` from `glaeda-mini-fleet pools --json`: `{"glaeda-std-xcode-26.6": 12, "glaeda-light-xcode-26.6": 2}` |

Each entry of `CI_OWNED_POOL_SLOTS` that is not an owned label with a positive
whole number of machines counts as none. While owned pools are on, the
`changes` job raises a workflow warning and a summary line for each such entry,
so a typo shows up on every run instead of quietly leaving a pool unused.

An owned pool is persistent, which needs one more rule because GitHub never
re-routes a queued job: one queued there waits for that pool however long it
stays busy. An offline mini still counts as a slot, and the snapshot can be
minutes old. When the picker chooses a persistent pool, `changes`
uploads a `macos-pool-persistent-<run>-<attempt>-<jobs>-<pool>` marker (the
janitor reads the run's peak and pool from its name), and
`ci-owned-pool-rescue.yml` (from `main`, with Actions write) watches that run.
If one of its jobs waits for a persistent runner longer than
`CI_OWNED_POOL_RESCUE_SECONDS` (default 90, 30 to 600), the watcher confirms the
pull request head has not moved, cancels the run, and re-runs it. A retry
attempt never takes a persistent pool, so the re-run lands on Blacksmith as a
whole, and so does a manual "Re-run all jobs".

An owned runner can also refuse a job: glaeda's job-started hook exits 1 when
the host is busy, and the job fails within seconds. GitHub does not retry it.
The watcher treats a job on the persistent pool that failed within 120
seconds of starting, with no workflow step succeeded, as refused. It confirms
the head has not moved, cancels the run if it is still going, and re-runs its
failed jobs, so nobody has to. That attempt 2 keeps what passed and sends the
rest to `retry_runner` (below). Products built on a mini are then tested on
Blacksmith, which is sound only while both carry the same Xcode build: on
2026-09-24 the minis and Blacksmith's 6vcpu and 12vcpu macOS 26 images all
reported Xcode 26.6 build 17F113 (jobs 107712770707 and 107710434810).

"Re-run failed jobs" is different: `changes` passed, so it is not re-run, and
the failed jobs read attempt 1's outputs, owned pool included, with no watcher
(the rescue follows attempt 1 only). So a persistent choice also names
`retry_runner`, the Blacksmith pool the same rule picks on the lane's own
Xcode, which is also the Xcode the owned label names. Every pull request macOS
`runs-on`, and the app-host shards that otherwise inherit compile admission's
pool, reads `github.run_attempt > 1 && inputs.pr_retry_runner` first. It is
empty for a run on Blacksmith, so those re-run where they ran.

Compile admission on an owned Mac keeps its build state between jobs
(`scripts/ci/owned_build_state.py`) under `/Users/Shared/cmux-build-fleet/ci`:
the admission DerivedData, stamped with the canonical fingerprint (Xcode build,
canonical paths, file-system mode), the resolved Swift packages, stamped with
the `Package.resolved` hash, and GhosttyKit per ghostty revision. When the kept
DerivedData matches, the SwiftPM cache restore and the nightly seed are skipped
and the compile, which compares inputs by checksum, rebuilds only what changed
since the last job on that Mac; an unchanged pin set resolves offline. The
first run on cmux11s spent 25 minutes on the ephemeral flow instead (run
36048804178). Any mismatch or miss falls back to that flow, a DerivedData over
40 GB is dropped, and only a successful compile's DerivedData is kept. Moves
are renames on one volume, glaeda's host lock keeps one job per Mac, and
nothing is uploaded: an owned run writes only its own Mac's state. Blacksmith
and fork runs never take these steps.

The queue janitor treats an owned label as one more macOS pool. A stale pull
request run (category b: closed, merged or superseded) is cancelled there on
every sweep whatever the queue, which frees minis for current work. The other
categories cancel only while more than `CI_JANITOR_QUEUE_THRESHOLD` jobs queue
on a pool the run holds, owned pools included. With `CI_PR_POOL_OWNED=1` the
janitor also lists the artifacts of each in-flight attempt-1, same-repository
pull request CI run (one request per run, more only past 100 artifacts) to
read its marker's peak into `committed`. A run's other macOS jobs do not rule
it out: `swift-package-tests` always runs on Blacksmith beside a full suite on
an owned pool.

| Variable | Default | Effect |
| --- | --- | --- |
| `CI_OWNED_POOL_RESCUE` | unset (on while `CI_PR_POOL_OWNED` is 1) | `0` turns the watcher off |
| `CI_OWNED_POOL_RESCUE_SECONDS` | `90` | how long a job may wait for a persistent runner before the run moves to Blacksmith |

The watcher makes no API request while owned pools are off. A run on an
ephemeral pool costs it a few jobs listings until `changes` finishes, plus one
artifact listing.

The guard keeps the picker the only way onto an owned pool.
`check_no_self_hosted_fleet_runners` refuses any `glaeda-*` label in workflow
text, and `runner_label_policy.py` refuses one in any `*RUNNER*` variable, so
neither a workflow edit nor `MACOS_RUNNER_PR` can send a job there.
`check_owned_pools_route_through_picker` requires the picked label to reach
jobs only as `pr_runner` or on a `pull_request` `runs-on` branch.
`CI_PR_POOL_ORDER` is the one variable that may name owned labels (the guard's
`owned` pattern, which must match `pr_runner_pool.OWNED_LABEL`), and the CI
health report checks every other entry in it against the workflow policy.
Owned pools stay off until `CI_PR_POOL_OWNED` is 1 and `CI_OWNED_POOL_SLOTS`
gives the lane's owned label machines.

`MACOS_RUNNER_PR` does not move a lane on its own. A runner change and its
Xcode pin still have to agree, because `scripts/select-ci-xcode.sh` exits
non-zero on a pinned path that is absent.

Every job that consumes the compile-admission product runs on
`macos-compile-admission`'s pool and pins its Xcode. `app-host-unit-tests`
reads both from the admission's `runner` and `xcode_app` outputs, so it follows
any routing change there. `tests-build-and-lag` restates the admission's
expressions (paid overflow may move its non-PR runs to `MACOS_RUNNER_DISPLAY`
under the same macOS 15 pin), and `tests/test_ci_change_areas.py` fails when
the two drift apart. The cmuxTests bundle only
loads under the Xcode that linked it: a bundle linked by 26.6 (`macos-26`)
imports Testing.framework symbols 26.3 (`macos-15`) lacks and fails to dlopen
before running a test. `app_host_test_products.py restore` refuses a product
built by a newer Xcode than the job's, naming both, as well as another
revision, architecture or major Xcode. `app-host-test-rerun.yml` runs on the
Blacksmith pool whose macOS matches the source run's compile admission.

For the other pull-request jobs, the pin follows `MACOS_RUNNER_PR` through
`CMUX_CI_XCODE_APP_PR`, and the two are set together:

```bash
gh variable set MACOS_RUNNER_PR --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-26
gh variable set CMUX_CI_XCODE_APP_PR --repo manaflow-ai/cmux -b /Applications/Xcode_26.3.app
```

Unsetting both returns the lane to `blacksmith-6vcpu-macos-15` and Xcode 26.3.

`swift-package-tests` deliberately does **not** resolve through
`MACOS_RUNNER_PR`. It builds the Release Ghostty CLI helper against an
SDK 15 Xcode -- it pins `CMUX_CI_REQUIRED_MACOS_SDK_MAJOR=15` for that step
and then asserts `HELPER_SDK_VERSION == 15.*` -- and only the `macos-15`
image carries an SDK 15 Xcode. That pin dates from Zig 0.15.2, whose MachO
linker could not resolve `libSystem` against an Xcode 26.4+ SDK
(ziglang/zig#31658, fixed by #31673 in Zig 0.16.0); the Ghostty submodule has
required 0.16.0 since 2026-09-17 and `install-zig-ci.sh` reads the version from
that manifest, so the original reason is probably gone. The SDK 15 assertion is
what still holds the job, and it has not been retested on a macos-26 image. So
it stays on `MACOS_RUNNER_DUAL_XCODE` on every event, and the dual-Xcode guard in
`tests/test_ci_self_hosted_guard.sh` fails if it ever reads
`MACOS_RUNNER_PR`.
`test_macos_jobs_use_lane_specific_xcode_pin_vars` in
`tests/test_ci_change_areas.py` keeps the pin on the same escape hatch as the
pool.

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

Every workflow exercised by a `pull_request` — including local reusable
workflows reached through `workflow_call` — has an explicit repository-owner
branch before runner variables are consulted. On `manaflow-ai/cmux`, existing
repository variables and their Blacksmith fallbacks behave exactly as above. On
every other owner, Linux jobs use `ubuntu-24.04` and macOS jobs use
`macos-26` from GitHub Actions: the image and Xcode (26.6) main compiles with,
so a fork's own CI can hit main's caches, which anyone can read from
`https://ci-cache.cmux.com`. Only the jobs that build the SDK 15 Ghostty CLI
helper (`swift-package-tests`, release and nightly), `plain-paste-worker.yml`'s
`macos-15` job and `ci-macos-compat.yml`'s macOS 15 row keep a `macos-15` fork
branch, because they need that image. Fork jobs set no Xcode pin, so they take
the pool pin from `scripts/ci/xcode-pins.txt` (26.6 on `macos-26`, the Xcode
main compiles with). When a hosted image no longer carries that Xcode, a fork
falls back to the image's newest stable Xcode with a warning, so a newer image
Xcode is a cache miss, never a failure. Runs in `manaflow-ai` fail on a missing
pool Xcode instead. The self-hosted guard allows a literal `macos-26` only in this exact
`github.repository_owner != 'manaflow-ai' && 'macos-26'` form, which evaluates
solely outside `manaflow-ai`, where the fleet's `macos-26` label does not exist.

Scheduled, dispatched and push-only workflows take the same owner branch, so
a fork's own nightly, release, SDK and dispatch runs never wait on Blacksmith
either. Dispatch inputs that default to a Blacksmith label (`reload-build.yml`,
`test-e2e.yml`, `test-ios.yml`, `perf-activation.yml`) are overridden by the
owner branch; `test-e2e.yml` applies it to the pool its runner job picks. The
Blacksmith Testbox warmup has no hosted equivalent, so it is skipped outside
`manaflow-ai`.

That is the fork contract: **a fork needs zero runner variables and zero runner
provider setup to run its workflows.** Blacksmith is an
organization-level GitHub App; naming a `blacksmith-*` label in a personal
fork does not produce a useful error, it leaves the job queued indefinitely.
The fork branch therefore short-circuits before any `MACOS_RUNNER_*` or
`LINUX_RUNNER` value can select organization-only capacity.

`tests/test_ci_fork_runner_routing.py` discovers every `pull_request`
workflow, recursively follows its local reusable-workflow calls, and requires
every variable-routed `runs-on` in that closure to contain a hosted fork
branch. Across every workflow, it also rejects a Blacksmith label that a
zero-configuration run outside `manaflow-ai` could select: each expression
holding one must start with the owner branch, unless the job itself is
owner-gated or the line is allow-listed there with a reason. The upstream branch still keeps literal Blacksmith fallbacks so deleting
a repository variable cannot silently change `manaflow-ai/cmux` capacity.

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

## Owned Macs for pull request compiles

The persistent compile-admission pilot (`persistent-macos-compile.yml`, its
router, and `CI_PERSISTENT_MAC_COMPILE`) was retired before it routed any
pull request.
Owned minis serve pull request runs through the pool picker instead; see
"Pull request pool preference" above.

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

There is no automatic overflow for the runner variables. If the Tart pool is
unavailable or its queue is too long, set the affected variable to a paid
provider.

Four runner variables exist to name **metered WarpBuild capacity**, so they are
read through a second switch that lives in this repository rather than in
repository settings:

| | Effect |
| --- | --- |
| `CI_PAID_MACOS_OVERFLOW` unset or not `1` | `MACOS_RUNNER_15`, `MACOS_RUNNER_DISPLAY`, `MACOS_RUNNER_DUAL_XCODE` and `MACOS_RUNNER_26_LARGE` are **not read**; every lane takes its free Blacksmith fallback |
| `CI_PAID_MACOS_OVERFLOW` = `1` | those four variables select the pool |

Turning paid capacity **on** therefore needs two admin actions: a runner variable
pointing at Warp *and* `CI_PAID_MACOS_OVERFLOW=1`. Turning it **off** needs
either — including a pull request anyone with push access can merge. Between
2026-09-19 and 2026-09-23 these four variables, plus the former release-specific
runner variable now folded into `MACOS_RUNNER_26`, pointed at Warp, so main and
the merge queue ran metered while pull requests ran free.

`MACOS_RUNNER_26` stays ungated because it names the ordinary free macOS 26
pool used by several jobs. Its safety check is the value policy described above.
Moving `release-build` onto a paid pool therefore takes one admin action:
repointing `MACOS_RUNNER_26`.

`tests/test_ci_repo_variable_defaults.py` fails if a workflow reads one of the
four paid-overflow variables without the gate, and
`scripts/ci/ci_health_report.py` reports how many metered runner minutes each
window actually contained.

```bash
gh variable set CI_PAID_MACOS_OVERFLOW --repo manaflow-ai/cmux -b 1   # enable paid overflow
gh variable delete CI_PAID_MACOS_OVERFLOW --repo manaflow-ai/cmux     # back to free capacity
```

```bash
gh variable set LINUX_RUNNER          --repo manaflow-ai/cmux -b blacksmith-4vcpu-ubuntu-2404
gh variable set LINUX_ARM64_RUNNER    --repo manaflow-ai/cmux -b ubuntu-24.04-arm
gh variable set MACOS_RUNNER_15         --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-15
gh variable set MACOS_RUNNER_DUAL_XCODE --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-15
gh variable set MACOS_RUNNER_26         --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-26
gh variable set MACOS_RUNNER_26_LARGE   --repo manaflow-ai/cmux -b blacksmith-12vcpu-macos-26
gh variable set MACOS_RUNNER_DISPLAY    --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-15
gh variable set MACOS_RUNNER_IOS        --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-26
```

Leave `MACOS_RUNNER_PR` and `MACOS_RUNNER_TESTS` unset in either recipe.
They exist to hold the pull-request and manual test lanes on Blacksmith
independently of whatever the pool above is set to.

Restore the self-hosted pool with explicit labels. The gate above applies
here too: `MACOS_RUNNER_15`, `MACOS_RUNNER_DISPLAY` and the other gated
variables are read only when `CI_PAID_MACOS_OVERFLOW=1`, so Tart needs that
flag set even though Tart is free. Without it, these values are ignored and
every lane stays on its Blacksmith fallback, with no error. `MACOS_RUNNER_26`
is ungated, so repointing the ordinary macOS 26 pool does not require the paid
overflow switch.

```bash
gh variable set MACOS_RUNNER_15         --repo manaflow-ai/cmux -b tart-macos-15
gh variable set MACOS_RUNNER_DUAL_XCODE --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-15
gh variable set MACOS_RUNNER_26         --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-26
gh variable set MACOS_RUNNER_26_LARGE   --repo manaflow-ai/cmux -b blacksmith-12vcpu-macos-26
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
fall back to a free runner. Bare third-party provider labels (`blacksmith-*`, `warp-*`,
`depot-*`) stay allowed for deliberate single-runner pins. "Paid" there means
"not a GitHub-hosted free runner"; of the three, only Warp and Depot bill this
repository per minute, since Blacksmith is sponsored for this organization.
The CI health report counts those two. Keep new labels in
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

There is no direct-host exception: no workflow names a mini's label or runner
group. Owned pools are reached only through `pr_runner_pool.py`, behind
`CI_PR_POOL_OWNED` (see "Pull request pool preference").
Every required macOS fallback still routes to the paid hosted path.
`check_no_self_hosted_fleet_runners` in
`tests/test_ci_self_hosted_guard.sh` rejects any required-job or generic fleet
route. Repository variables may keep
pointing at the isolated `tart-*` pool for their existing jobs.
