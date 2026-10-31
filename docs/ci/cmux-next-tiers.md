# cmux-next CI tiers

A pull request into `feat-cmux-next` runs only the checks its change can break.
`scripts/ci/cmux_next_route.py` reads the changed files (the merge commit
against its first parent) and picks the tiers; the `cmux-next path routing`
job's summary lists each tier and the reason for it.

A same-repository pull request runs every tier the router picks on its own
branch, with no label and no side `next-batch/*` push (#22303), except the two
heavy app compiles: `cmux-next Release compile (Xcode 26)` and `cmux app scheme
compile (Debug)` need `full-ci` again (2026-10-21, a ~350-job Mac queue); a
MEMBER or OWNER `dev-build` PR keeps its scheme compile, and every
`feat-cmux-next` push compiles both. In place of the Release compile, the
native tier compiles the PR's head on the build fleet: `cmux-next app compile
(build fleet)` runs `cmux-ci compile-check --ref <head> --app` (about a minute,
Debug, swift.org toolchain). Its red is the PR's red. When the fleet gives no
verdict (the controller unreachable or timed out, or no client), the job fails
with "no verdict", never green, and the Mac Release compile runs instead where
the change has a Release-only input (path_route's `mac_release`); re-run the job
once the fleet answers. A red only the Linux toolchain
shows: add `full-ci` and push again (labels do not re-run this workflow), and the
Mac Release compile decides. A fork pull
request runs `cmux-next checks`, the fast tier and, for a CmuxNext `.swift`
change, the Release compile; the other Mac tiers wait for a maintainer's
`full-ci`. It never gets an owned runner, a secret or a tree dispatch. To run
every tier on a branch, not just the routed ones, dispatch the workflow on it:

```bash
gh workflow run cmux-next.yml --ref <branch>
```

Dispatch runs every tier on any ref of this repository (feat-cmux-next, a
`next-batch/*` branch or a working branch). A newer plain dispatch on the same
working branch cancels the older one, as a push to a pull request does, so a
superseded run does not hold a mini in the queue. Dispatches on
feat-cmux-next and `next-batch/*`, same-tree runs and the DEV daily keep a run
of their own and are never cancelled. When a dispatch's cmux-tui tree is still
building, its tree jobs start once the tree publishes, as for a push; the
marker records the run as a dispatch, so that same-tree run also runs
`cmux-next daemon tests` (a push's skips them). A tag dispatch's marker names the tag, which never moves, so its tree jobs start whenever the tree publishes. `cmux-next web bundles` runs on
a pull request only when a tier that restores them (swift, daemon, generated)
is routed.

| Tier | Check (job) | Runs when the PR changes | Runner |
| --- | --- | --- | --- |
| checks | `cmux-next checks` (god files, concurrency, crash safety, string tables, script tests, package conventions, tier routing) | any cmux-next path | Linux (Blacksmith) |
| generated | `cmux-next generated files` (action catalog, surfaces and inventory; CI target graph; settings exports and the defaults snapshot) | the CmuxNext package, `plans/cmux-next/`, the settings exports, the generators | mini |
| swift canary | `cmux-next Swift canary` (Debug SwiftPM build of the changed production targets) | production Swift files under `Packages/macOS/CmuxNext/Sources/` only | mini, placed first |
| native | `cmux-next app compile (build fleet)` on a same-repository PR; `cmux-next Release compile (Xcode 26)` with `full-ci`, from a fork, on a push, or when the fleet gives no verdict | Swift and app sources (a fork PR: any `.swift` file under `Packages/macOS/CmuxNext/`, other sources with `full-ci`) | build fleet (Linux); mini for Release |
| scheme | `cmux app scheme compile (Debug)` | the app host, Xcode project, CLI, resources, webviews, local packages CmuxNext uses, an executable target | mini |
| swift | `cmux-next swift test` | the test targets the target graph reaches | mini |
| daemon | `cmux-next daemon tests` (`same-tree cmux-tui` reports a tree that nothing will publish) | cmux-tui tree inputs, daemon capabilities, `pin-cmux-tui.sh`, CmuxNextDaemon or CmuxNextMobile and their dependencies, CmuxNextControl | a mini, once the tree is published |

A web nit runs no Mac tier. When every changed file is under `webviews/`, the
webviews app, the agent-pane bundle (`CmuxNextAgentPane/Resources/agent-pane/`)
or docs, and no Swift test reads it, only `cmux-next checks` runs here. ci-web
type-checks, lints and tests the sources, and `build-agent-pane-web.sh --check`
proves the committed bundle matches them; the bundle is a `.copy` resource, so
the app takes it without a compile. An explicitly requested local gallery matrix can diff the touched entries. A
`dev-build` PR still compiles its dogfood app.

A web bundle source runs no swift test of its own. The bundles' inputs
(`BUNDLE_INPUTS`: `webviews/src/`, the bundle build scripts, the schema and the
other files the bundles import) still run the compiles that ship them (`native`),
but swift test only for the test targets whose sources name the changed file
(the target graph's `reads`). The four targets that ship a bundle take it as a
`.copy` resource, or one processed `.js`, so no source edit can break their build,
and no suite asserts on a built page: the agent pane, page and Activity suites
load fixture pages (an `AgentPaneView` with a temporary `index.html`,
`loadHTMLString`, a scratch page root), and the app suites that open a real page
check only its native side. `BundleInputs` in `tests/test_cmux_next_route.py`
keeps that true: a suite in a target that links a bundle target and runs page
JavaScript must load its own document or be an opt-in bench. A test that reads a
pattern of files names the pattern (`PageDevServerTests`:
`"webviews/src/pages/*/main.tsx"`, the dev server's entries), and the graph
records the pattern, so an edit inside a page no longer runs CmuxNextPagesTests
for the whole of `webviews/src/pages/`. ci-web type-checks, lints, tests and
builds the bundles on Linux for every webviews change, as before.

A design note runs no Mac tier either. A test helper such as
`planURL(_ name:)` builds `"plans/cmux-next/\(name)"`, so the target graph
records the whole of `plans/cmux-next/` as a read. The router narrows that for
docs (`.md`, `.html`, images): a doc counts as read only when a string literal in
the reading target names it (or names the directory itself), or when a generator
writes it (`scripts/cmux-next/generated_outputs.py`). #28326 changed only
`plans/cmux-next/sidebar-owner.md` and queued the fast tier and swift test.

The Mac fast tier (`cmux-next fast tier`, the `swift` entries of
`scripts/cmux-next/fast-tier.json`) builds the CmuxNext package and runs a few
of its suites, so it runs only when that build or those suites can change: a
package target's sources or a local package it uses, a file read by a test
target that holds one of its suites (placed from `fast-tier.json` and the target
graph), a package one of its entries builds, an action its job uses, an input of
every tier, or the tier's own registry (router output `fast_tier`). The job builds
no web bundles and links CCmuxAppFFI as a pinned binary, so a change only to the
bundles' sources, to the cmux-app-ffi crates, or to files only other test targets
read skips it (#28160, #28015: acpmux Rust with the pane's protocol types, which
keep the daemon tier and the compiles). A cmux-tui-only or app-host-only change keeps its daemon and
scheme tiers and skips it too; `fast-tier-cargo` still runs on Linux.

The Swift canary is the pull-request gate for a small package-only Swift diff.
It builds only the affected CmuxNext production targets with `swift build
--configuration debug --target`, reusing the linked SwiftPM scratch on a mini.
It catches type-checking, dependency and module errors in those targets. It
does not exercise optimizer-only behavior, Release compiler settings, Xcode
scheme integration, signing or the CEF shim. So the Release compile runs on
every fork pull request that changes a `.swift` file under `Packages/macOS/CmuxNext/`
(Sources or Tests, whatever else it changes): a Release-only optimizer crash
(cx-ebm.59.5) reached the base through a PR that only had the Debug tiers. A
same-repository PR runs it only with `full-ci` or when the build fleet gives no
verdict (2026-10-21), as a fork PR does for its other native sources. Every
`feat-cmux-next` push runs it, so a Release-only break shows on the base push
and push-attribution names the PR.

A CI-only change runs no Mac tier either: workflows, `scripts/ci/`, the router,
`scripts/gh-merge-green` and their Python tests (alone or with web files).
`cmux-next.yml` counts as one only when, against the pull request's base
(`--base-rev HEAD^1`), its change leaves every Mac job and every job one needs as
it was: `on:` paths or `run-name`, or a job that runs only on Linux and that no Mac
job needs (the `checks` job, a dispatch request). A job that never runs on a pull
request adds no tier either: its `if:` requires a push, a dispatch, a branch ref or a
dispatch input, or a job that does (the DEV landing compile, the fast Release gate, the
nightly requests). The base push runs it. A change to one of the Mac jobs
`WORKFLOW_JOB_TIERS` lists runs that job's own tiers:

| job changed | tiers it runs |
| --- | --- |
| `swift-test` | swift test on every CmuxNext test target, with the generated-files check it folds in |
| `daemon-test` | the daemon suites, with the generated-files check |
| `generated-files` | generated |
| `release-compile` | native and the Mac Release compile |
| `app-compile-fleet` | native |
| `cmux-scheme-compile` | native and the scheme compile |

Before this, a change to the DEV compile's steps ran swift test, the daemon suites
and every compile (#5424). The router runs every tier, as before, for: a change to a
listed job's `if:`, a job added or removed, path routing, placement, the web bundles
job, the fast tier or the canary, a top-level key, or a base that cannot be read
(#28459 changed only `on:` paths and queued both Mac jobs). ci.yml's
guards run actionlint and the CI unit tests. When the router itself changes,
`Routing replay (router changes)` replays the last 30 merged PRs' changed files
through the base router and the PR's own (`scripts/ci/cmux_next_route_replay.py`)
and fails on any tier the new router adds, or drops without naming a fast tier.
`gh-merge-green --revert OWNER/REPO#N` undoes a bad one in a command. A file
that a Mac tier reads keeps its tier whatever its name: the Xcode pins,
`.github/actions/setup-cmux-tui-rust/`, daemon and tree inputs, generated-file
inputs such as `plans/cmux-next/`, and every file a Swift test reads.

Every tier runs on:

- a pull request labeled `full-ci`, so a batch integration PR or a fork PR
  runs every suite before it merges;
- a dispatch on any ref (`gh workflow run cmux-next.yml --ref <branch>`);
- every `feat-cmux-next` push, except `swift test`: push CI is the app build
  (Release compile and app scheme compile), so a merged PR's Swift suites run
  on the PR itself or a dispatch. A superseded push skips its other Mac jobs,
  so a burst of merges is checked once at its newest commit. The Release
  compile still runs on superseded pushes: one runs at a time and only the
  newest waits (a newer push replaces a waiting one), so a base compile break
  turns the base red within one compile of its commit. When a push job fails,
  `cmux-next push attribution` comments on each PR merged since that job last
  passed on a push. The owning lane fixes forward. The base Mac tier (daemon
  tests, generated files, the Debug app scheme compile) is not on the push: it
  runs at most once every 15 minutes, on the tip, in a `cmux-next base tier · <sha>`
  dispatch that `cmux-next-base-tier-kick.yml` starts
  (`scripts/ci/cmux_next_base_tier.py`, cmuxterm-hq#5424). Its tip holds every
  landing since the last one, so each landing gets that verdict within about
  15 minutes plus the run. When it fails, push attribution comments on the PRs
  merged since it last passed (about ten in a busy window). To name one, push a
  branch at a commit in that range and dispatch cmux-next.yml on it
  (`gh workflow run cmux-next.yml --ref <branch>`), which runs every tier there;
  halve the range until one PR is left. `vars.CMUX_NEXT_BASE_TIER_COALESCE = 0` puts the tier back on
  every push;
- a change to the manifest, the target graph, the router, the workflow or the
  test runner scripts, or to a file in the CmuxNext package that no target owns.

## Which test targets a change selects

`Packages/macOS/CmuxNext/ci-target-graph.json` comes from
`swift package dump-package`, via `scripts/cmux-next/ci-target-graph.py`:

- each target's directory and the targets and local packages it depends on;
- each local package's directory. Its own path dependencies come from
  `scripts/ci/select_package_tests.py`;
- for each test target, the repository files its sources name in string
  literals (schemas, fixtures, plans, cmux-tui vectors).

A test target runs when a target it depends on, directly or transitively,
changed, when the test target itself changed, or when a file it reads changed.
The graph is bot-only (#21946): a pull request never commits it, the `generated
drift` check fails one that does, and the base autofix regenerates it after each
merge. A manifest change routes every tier, so a pull request needs no graph of
its own. No check compares it with the manifest, because it is stale between
such a merge and the base autofix's commit; the base autofix fails when it
cannot regenerate it.

The live-daemon suites skip without the same-tree cmux-tui binary. The daemon
tier runs them against it. A UI change does not wait for the tree.

### The same-tree cmux-tui is an event

No runner waits for the tree. `cmux-next path routing` probes it once
(`pin-cmux-tui.sh probe`) when the daemon or scheme tier runs:

- published: `cmux-next daemon tests` and `cmux app scheme compile (Debug)`
  run in the same run;
- an artifacts run that can publish it is active: the run uploads a
  `cmux-next-tree-wait-<key>` marker and skips the two jobs. When that
  `cmux-tui artifacts` run publishes the key, it dispatches cmux-next's
  same-tree mode (`scripts/ci/cmux_next_tree_notify.py`) for each run that is
  still current. That run checks out the probed commit (a pull request's merge
  commit), runs only the two jobs, and posts `... (same-tree)` commit statuses
  on the push or the pull request head;
- superseded push: the two jobs skip;
- nothing will publish it: `same-tree cmux-tui` fails at once with the reason.
  The marker stays, so a later publication of the key (a re-run, a
  `cmux-tui-pin-*` push) still starts the jobs.

### What a UI-only PR no longer checks

- **First-launch tests.** `FirstLaunchTests` starts the app against the
  same-tree daemon. A change only in CmuxNextApp skips it unless the tree is
  already published, because adding CmuxNextApp to the daemon tier would make
  every UI PR wait for the tree again. A `full-ci` PR, a dispatch and the push
  run cover it.
- **App personality check.** `check-app-personalities.sh` runs with the app
  scheme compile. A new linked library changes `Package.swift`, which runs
  every tier, so a source-only CmuxNext change cannot add one.

## Generated files fix themselves

When the action contracts or the graph are stale, `cmux-next generated files`
regenerates them and uploads the patch. On a same-repository PR,
`cmux-next generated autofix` commits the patch to the PR branch if both hold:

- the patch touches only `plans/cmux-next/*.json`, `plans/cmux-next/*.md` and
  the graph;
- the branch head has not moved.

The new commit starts a fresh run. Pull before your next push.

The settings exports (`schemas/settings/settings-schema.json`, `docs/mdm/*`)
come from Swift tests. When an event changes the `CmuxNextSettings` sources or
the export tests (their source stamp, `defaults_guard.py source-stamp --ref REF`,
differs between the event's parent and its head; the stamp is derived, never
committed), `cmux-next generated files` runs
`scripts/cmux-next/regenerate-settings-exports.sh`, fails when a committed export
differs from the fresh one, and adds the regenerated files and
`defaults_guard.py snapshot` to the patch. Any other event leaves exports the
base left stale to the base autofix. On
`feat-cmux-next`, the base autofix's Mac job runs the same script after a
settings change and commits the exports and the snapshot, so a lane does not
have to run the export itself.

The defaults snapshot (`schemas/defaults/cmux-next.json`) is bot-only (#21946):
no pull request commits it, and the PR autofix leaves it out. It is stale
between a merge and the base autofix's commit, so CI never runs `check-fresh` on
an event. The base autofix
rewrites it after each merge. The defaults guard judges a pull request by the defaults its
exports and sources produce, never by a committed snapshot. A changed default passes
with an independent review receipt on the head (a comment or review whose first line is
`Review (<reviewer>): SHIP at <full head sha>`, from a member, not a self-review; the
newest verdict naming the head decides, so a later BLOCK beats an earlier SHIP) or an
approving review from a call owner in `.github/defaults-call-owners.json` other than the
author. A new setting whose default is off (false, null, `off`, `never`, `none`,
`disabled` or empty) keeps what everyone had before it existed and passes on its own.

## Warm sources

Every compile, build or test job names the warm state it starts from in
`.github/warm-sources.json`, beside the tiers above: kept DerivedData
(`deriveddata-reuse`), the per-mini SwiftPM scratch (`spm-shared`), the fleet
compiler-CAS nodes (`ssd-cas`), the DEV CAS seed (`dev-cas`), actions/cache on
Blacksmith (`actions-cache`), the controller's warm Linux lanes (`linux-pool-warm`)
and green-product reuse for the same tree (`product-reuse`). A job with none says
why (`exempt`); one that compiles cold today says `cold: ...` until its cache is wired.
`tests/test_ci_warm_sources.py` (release-notary guards) fails on a compile job missing
from the table, an entry with neither, a source the job's steps do not wire, an
exemption on a job that now wires a source, and an entry for a job that is gone. For
a new job, `python3 tests/test_ci_warm_sources.py --suggest` prints the entry its
steps give; each source's `runbook` says how to wire it.

## Measurements

Before (#17470, a UI-only PR, run 37402420094):

| Job | Wall time | Where the time went |
| --- | --- | --- |
| cmux-next swift test | 28.5 min | 13.2 min waiting for the base head's cmux-tui tree to publish, 10.4 min package tests on a busy mini, 2.6 min build |
| cmux app scheme compile (Debug) | 20.9 min | 16.9 min waiting for the same tree, 2.6 min compile |
| cmux-next Release compile | 4.4 min | |
| cmux-next checks | 1.1 min | |
| whole run | 40 min | |

The same package tests take 2.1 min on an idle mini (push run 37405228160).

### Why the tree wait took 13 minutes

`pin-cmux-tui.sh fetch` did not build anything. Its cache is already keyed by
the cmux-tui tree hash (key v2, `scripts/ci/cmux_tui_tree_key.py`). An
unchanged tree is a download of a few seconds once it is published.

The PR's merge tree had the base's cmux-tui tree, `a4098bcb`. The base had just
moved to it, and the cmux-tui artifacts workflow publishes a tree only after its
build and the `cmux_next_` daemon tests pass. Every PR merged in that window
waited for the base head's publication. That key changes often: the 40 first-parent
commits on `feat-cmux-next` up to f9e139f (about 7 hours on 2026-10-05) have
18 different keys.

A UI-only PR now neither waits for the tree nor runs the scheme compile that
bundles it.

### Sharding

Package tests are not sharded across minis. On an idle mini the whole suite
takes 2.1 min, and SwiftPM links every test target into one bundle, so each
shard pays the 2.6 min build again and asks for one more mini. The 10.4 min
on #17470 was contention on a busy mini. Selecting only the affected targets
reduces that contention, and sharding would add to it.

## Measuring test builds

The `swift-test`, `daemon-test` and `generated-files` jobs wrap their explicit
`swift build --build-tests` command with `scripts/ci/swiftpm_build_metrics.py`.
Each uploads a `cmux-next-build-metrics-<role>-<attempt>` artifact containing
`<role>.json` and the streamed `<role>.log`, including after a failed build.
The step summary reports build-step wall time and recognized SwiftPM progress
events. This does not measure compiler CPU or later builds a test or generator
script may invoke.

Compare `build_inputs_sha256` to find candidates for a shared build. It covers
the whole tracked working repository (recipe and dependency pins included) and
generated package inputs outside `.build` and dependency stores. Clean files
use Git object IDs; changed and generated inputs use their bytes. The separate
`compatibility_sha256` includes the toolchain, selected build environment,
absolute package path and resolved workspace state. The combined
`build_identity_sha256` binds both; these diagnostic identities do not authorize
product reuse. An unavailable source identity or dirty submodule leaves the
candidate identity null. `measurement_setup_seconds` reports collection overhead
separately from `build_step_seconds`.
Missing toolchain metadata leaves the compatibility identity null; the combined
identity is null whenever either component is unknown.

`scratch_before` and `scratch_after` report the linked scratch key and existing
build markers. Warm state does not prove a cache hit; `cache_hit` stays null.
`web_bundle_restore` records the existing restore action's outcome and hit
output separately. Compile/module event counts use `swiftpm-progress/v1`;
zero events mean no recognized progress was observed, not proof of zero compile
work or a cache hit. Matching candidate identities and elapsed times identify
possible duplicate build steps, not measured redundant compiler CPU.

## Queueing

A pull request's Mac jobs never share a concurrency group with a
`feat-cmux-next` push: each job of a push run holds a per-branch group, and a
pull request's jobs are grouped by the pull request (`swift test`, the canary)
or by their run. A newer push to the pull request cancels its older run. What
a pull request can wait behind is runner capacity, and `macos-placement`
decides that: an idle mini first, then Blacksmith for the fast tier, the canary,
the scheme compile and the Release compile (`docs/ci/mac-fleet.md`). The tip's
Release compile has its own reserved runner while `vars.CI_NEXT_PROMOTE_POOL` is
set, so pull request jobs do not delay nightly-next promotion; while no runner
there is idle it takes a free Blacksmith slot instead. This workflow sets no runner variable or
capacity.
