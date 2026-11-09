# cmux-next.yml notes

The comments of `.github/workflows/cmux-next.yml`, in file order, moved here verbatim so the
workflow stays under GitHub's 512,000-byte limit for a workflow file
(`tests/test_cmux_next_checks_workflow.py` caps it at 450,000 bytes). Each
heading is the YAML path of the line a comment stood above (`[x]` is the list
item whose `name:`, `id:` or value is x), and the quoted line is that line.

## `on`

Above `on:`:

```text
# Package tests and merge-gate checks for the cmux-next app package
# (Packages/macOS/CmuxNext). `swift test` runs the package's Swift Testing
# suites in-process; it never builds or launches a cmux DEV app. The checks
# are the AGENT-BRIEF merge gate: god files, main-thread concurrency and the
# string tables (the CmuxNext catalogs and InfoPlist).
#
# A pull request runs only the tiers its change can break
# (scripts/ci/cmux_next_route.py, docs/ci/cmux-next-tiers.md):
#   checks     always (Linux)
#   generated  generated action contracts, the CI target graph and the settings exports are fresh;
#              a stale file gets a bot fix commit on a same-repository PR
#   native     the Release compile, for Swift and app sources
#   scheme     the Debug app scheme compile, for the app host, Xcode project,
#              webviews and local packages
#   swift      the CmuxNext test targets the SwiftPM target graph says the
#              change reaches (Packages/macOS/CmuxNext/ci-target-graph.json)
#   daemon     the same-tree cmux-tui and the live-daemon suites, for daemon,
#              Rust core, FFI and control paths
# A same-repository pull request runs every tier the router picks on its own
# branch, with no label (#22303), except the two heavy app compiles (native and
# scheme), which need full-ci again (2026-10-21: the Mac queue was ~350 jobs
# deep), and the swift tier, which needs full-ci too (2026-11-05: of 78 PR
# swift-test check runs, 37 were cancelled by a merge, a newer push or a re-run
# and none passed; the tip suite dispatch gives the base its verdict); a MEMBER or OWNER dev-build PR keeps its scheme compile, and the
# native tier compiles the PR's head on the build fleet instead
# (app-compile-fleet; the Mac Release compile only when it gives no verdict, and only for a PR
# that changes an input only that xcodebuild sees: path_route's mac_release,
# cmux_next_route.MAC_RELEASE_INPUTS). A fork pull
# request runs the fast tier and,
# for a CmuxNext .swift change, the Release compile, and the other Mac tiers
# only with the full-ci label, on its hosted fallback. full-ci also makes the router
# pick every tier. A feat-cmux-next push runs the Mac compiles but not swift
# test (see the jobs comment below); a red push run names the pull requests in
# its range.
```

## `on.pull_request.paths[Packages/Shared/**]`

Above `- Packages/Shared/**`:

```text
# Local packages CmuxNext depends on and files its tests read
# (ci-target-graph.json `packages` and `reads`).
```

## `on.pull_request.paths[backend/catalog/cloud-operations.json]`

Above `- backend/catalog/cloud-operations.json`:

```text
# cmux-tui tree-key inputs: the crates embed these files.
```

## `on.pull_request.paths[docs/remote-agents-and-cloud.md]`

Above `- docs/remote-agents-and-cloud.md`:

```text
# cmux-tui's help-contract tests include_str! this one (acpmux and
# cmux-tui both check their help against it), so it is in the tree key
# and a change to it has to rebuild and re-run them.
```

## `on.pull_request.paths[webviews/src/**]`

Above `- webviews/src/**`:

```text
# The web bundles' sources (build output since cx-vn5; the package tests
# read the built pages; cmux_next_route.py BUNDLE_INPUTS).
```

## `on.pull_request.paths[release-notes/next/highlights/**]`

Above `- release-notes/next/highlights/**`:

```text
# The feature tips' source (webviews/scripts/pages/gen-feature-tips.mjs).
```

## `on.pull_request.paths[web/data/model-catalog/**]`

Above `- web/data/model-catalog/**`:

```text
# Files outside webviews/ that webviews sources import (web-bundle-key.py --inputs;
# tests/test_web_bundle_key_inputs.sh keeps this list complete).
```

## `on.pull_request.paths[scripts/cmux-next/fast-tier.py]`

Above `- scripts/cmux-next/fast-tier.py`:

```text
# The PR fast tier: its runner, registry, quarantine list and test.
```

## `on.pull_request.paths[Resources/bin/**]`

Above `- Resources/bin/**`:

```text
# The bundled CLI shims the app ships.
```

## `on.pull_request.paths[Packages/macOS/**]`

Above `- Packages/macOS/**`:

```text
# Keep the workflow eligible for every cmux-next product and CI input.
# The router still selects the exact tier; this list only decides whether
# the workflow starts at all.
```

## `on.push.paths[.github/workflows/nightly.yml]`

Above `- .github/workflows/nightly.yml`:

```text
# A nightly repair must earn this exact commit's Release compile before
# promotion can carry it to nightly-next. Otherwise a workflow-only fix
# (such as #21144) waits for an unrelated app change to become eligible.
```

## `on.push.paths[scripts/ci/base_red_checks.py]`

Above `- scripts/ci/base_red_checks.py`:

```text
# The push-only base-red classifier in the checks job (push only, never a
# pull request; the parity guard lists it in PUSH_ONLY_PATTERNS).
```

## `on.push.paths[scripts/cmux-next/state-roots-baseline.tsv]`

Above `- scripts/cmux-next/state-roots-baseline.tsv`:

```text
# Pull-request inputs that pushes must watch too (the parity guard,
# tests/test_ci_workflow_path_filter_parity.py).
```

## `on.push.paths[Packages/macOS/**]`

Above `- Packages/macOS/**`:

```text
# Base pushes still run the full side workflow for every package input;
# only pull requests use the focused package routing below.
```

## `on.push.paths[Packages/Shared/**]`

Above `- Packages/Shared/**`:

```text
# Local packages CmuxNext depends on and files its tests read
# (ci-target-graph.json `packages` and `reads`).
```

## `on.push.paths[backend/catalog/cloud-operations.json]`

Above `- backend/catalog/cloud-operations.json`:

```text
# cmux-tui tree-key inputs: the crates embed these files.
```

## `on.push.paths[webviews/src/**]`

Above `- webviews/src/**`:

```text
# The web bundles' sources (build output since cx-vn5; the package tests
# read the built pages; cmux_next_route.py BUNDLE_INPUTS).
```

## `on.push.paths[release-notes/next/highlights/**]`

Above `- release-notes/next/highlights/**`:

```text
# The feature tips' source (webviews/scripts/pages/gen-feature-tips.mjs).
```

## `on.push.paths[web/data/model-catalog/**]`

Above `- web/data/model-catalog/**`:

```text
# Files outside webviews/ that webviews sources import (web-bundle-key.py --inputs;
# tests/test_web_bundle_key_inputs.sh keeps this list complete).
```

## `on.push.paths[scripts/cmux-next/fast-tier.py]`

Above `- scripts/cmux-next/fast-tier.py`:

```text
# The PR fast tier: its runner, registry, quarantine list and test.
```

## `on.push.paths[Resources/bin/**]`

Above `- Resources/bin/**`:

```text
# The bundled CLI shims the app ships.
```

## `on.workflow_dispatch`

Above `workflow_dispatch:`:

```text
# Dispatch runs every tier on any ref of this repository
# (gh workflow run cmux-next.yml --ref <branch>): feat-cmux-next, the
# next-batch/* integration branches that scripts/ci/next_batch.py validates,
# or a pull request's own branch. Only someone with write access can
# dispatch, so it is as trusted as a push.
#
# Same-tree mode (same_tree_sha set): scripts/ci/cmux_next_tree_notify.py
# dispatches it from the cmux-tui artifacts workflow once a tree that a run
# probed as unpublished is published (or failed). It runs only the tree jobs
# (daemon tests, scheme compile) on same_tree_sha, or only reports the
# failure, and posts their results as commit statuses on
# same_tree_status_sha (the push, or the pull request head).
```

## `on.workflow_dispatch.inputs.tip_daemon_suite`

Above `tip_daemon_suite:`:

```text
# main's cmux-next-tip-swift-suite-dispatch.yml (its daemon suite): a feat-cmux-next push never
# gets daemon-test, so this run is the base verdict scripts/ci/base_red_excuse.py compares a pull
# request's daemon-test red with. A same-tree run it waits on carries it too (its run name).
```

## `on.workflow_dispatch.inputs.base_tier`

Above `base_tier:`:

```text
# cmux-next-base-tier-kick.yml (scripts/ci/cmux_next_base_tier.py): a feat-cmux-next push leaves
# its base Mac tier (daemon tests, generated files, the Debug app scheme compile) to this run,
# started at most once every 15 minutes on the tip (cmuxterm-hq#5424). Named
# `cmux-next base tier · <sha>`, which the kick, push attribution and base_red_excuse.py read.
```

## `on.workflow_dispatch.inputs.no_reuse`

Above `no_reuse:`:

```text
# The safety net under CI_NEXT_JOB_REUSE: a dispatch with no_reuse runs every job
# in full, reusing no recorded pass (it still records its own). A nightly one on
# feat-cmux-next re-checks what the day's reused results stood on.
```

## `env.CI_CACHE_R2_PUBLIC_URL`

Above `CI_CACHE_R2_PUBLIC_URL: ${{ vars.CI_CACHE_R2_PUBLIC_URL || 'https://ci-cache.cmux.com' }}`:

```text
# HQ's public cache edge serves read-only restores from every runner; writes
# use the controller-owned R2 credentials in the seed steps below.
```

## `env.CMUX_NEXT_STYLE_GUARDS`

Above `CMUX_NEXT_STYLE_GUARDS: warn`:

```text
# Structural, style, size and drift guards (god files, size caps, package
# conventions, motion tokens, type scale, scrollbars, icons, copy lints,
# generated-doc drift) still run and print their findings, but only warn
# (Leo, 2026-10-19: they failed pull requests for reasons unrelated to the
# change). Correctness and safety checks still fail. Set to `fail` to make
# the style guards block again.
```

## `env.CMUX_NEXT_SIDE_ROUTE`

Above `CMUX_NEXT_SIDE_ROUTE: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || (github.event_name == 'pull_request' && github.event.pull_request.head.re...`:

```text
# The label attempt 1's macOS jobs take when macos-placement finds an idle
# owned runner for them: a glaeda-* label means a mini. Each macOS job's
# runs-on, and its own CMUX_NEXT_RUNNER, restate it with the placement.
```

## `env.BASH_ENV`

Above `BASH_ENV: ${GITHUB_WORKSPACE:-/nonexistent}/scripts/ci/api_call_log/env.sh`:

```text
# Temporary REST budget attribution: one gh-call line per GitHub API call (scripts/ci/api_call_log/env.sh).
```

## `concurrency.group`

Above `group: ${{ github.event_name == 'workflow_dispatch' && inputs.same_tree_sha == '' && inputs.dev_daily != true && github.ref != 'refs/heads/feat-cmux-next' &&...`:

```text
# Pushes and dispatches get a group of their own, as in the other side
# lanes: when the owned-pool rescue re-runs an older push run, it must not
# join a group where it would replace (cancel) the newest pending run.
# The Mac jobs of a push (swift test, Release compile, generated files,
# daemon tests, scheme compile) keep independent job groups: a started job
# runs to the end and stale work is filtered before it takes a runner. Fast
# checks still run on every push. Push runs upload no
# owned-pool-watch marker, because the rescue cancels a push run with a newer
# push run behind it, running jobs included; at 1 push a minute no tip
# swift test completed (2026-10-07 00:20Z to 01:05Z).
# A plain dispatch on a working branch (not feat-cmux-next, not next-batch/*,
# not same-tree mode or the DEV daily) is grouped by its ref and a newer one
# cancels it, like a pull request's push: a superseded dispatch does not hold
# a mini in the queue.
```

## `jobs`

Above `jobs:`:

```text
# The macOS jobs run as a side lane, like relay-tls.yml and reload-build.yml:
# Trusted runs (a same-repository pull request, a push or a dispatch) stay on
# vars.CI_SIDE_LANE_RUNNER, the minis' glaeda-side-* label, while owned pools
# are on (CI_PR_POOL_OWNED is 1). Fork pull requests keep their fallback.
# Manual reruns stay minis-first. The rescue re-admits a queued run after the
# five-minute queue alarm: placement first uses a free owned GUI/session Mac,
# then the workflow's Blacksmith macOS route. macos-placement records idle
# side runners with the main picker's idle_placement() and publishes free role
# labels for the bot retry, so a job does not keep a shared concurrency slot
# on a busy Blacksmith label indefinitely. When a job takes the side label, macos-placement uploads the
# owned-pool-watch marker:
# ci-owned-pool-rescue.yml's sweeper on main adopts the run
# (owned_pool_rescue.SIDE_WORKFLOW_PATHS) and re-runs a job a mini leaves
# queued or refuses. Bot attempt 2 and later drop the stale placement output
# and re-admits it through the same fast-checks/owned-Mac/Blacksmith order; a
# person's re-run stays on the side label.
```

## `jobs.pr-quiet-period`

Above `pr-quiet-period:`:

```text
# A pull request's run waits until the PR has had no push for about 5 minutes before any Mac
# job starts. The run's group cancels in progress on a newer push, so a second push inside the
# window cancels a run before it takes a Mac. In the 82 minutes to 2026-11-05T08:36Z, 17 of 100
# PR runs were cancelled by the PR's next push (4 of them under 5 minutes after the first, the
# rest after 5 to 36 minutes of checks and compiles).
# Only macos-placement waits for it, and every Mac job (and every Mac job's build-fleet client)
# needs macos-placement, so the Mac jobs are placed from a reading taken after the wait: an idle
# runner that placement finds is still idle when the job it placed starts. The Linux work starts
# at once: portable-placement, path_route, checks, fast-tier-cargo, web-bundles and the build
# fleet's app compile (app-compile-placement, app-compile-fleet). Leo, 2026-11-08, choosing
# "the Linux checks start at once and only the Mac jobs wait": "yeah". A superseded head spends
# 3 to 8 Linux runner-minutes before the newer push cancels its run (41% of runs). It sleeps on the
# smallest Blacksmith Linux size (the linux_2 pool), so it holds no fleet runner or mini. It is
# not on hosted Ubuntu: the org runs at most 20 hosted jobs at once, and on 2026-11-07 its
# 2,103 sleeps held 6 of them on average (8,400 of 21,600 hosted minutes), so the routers and
# report steps that must start fast queued 1.5-2 min at the median through the busy hours. Its
# own start costs nothing on any runner: the sleep ends at the push time plus the window, so a
# queued start sleeps that much less. A re-run (attempt 2 and later), a `leo-named-fix` PR (landing.md: those land
# with no wait) and vars.CI_PR_QUIET_PERIOD_SECONDS = '0' skip it; pushes and dispatches never
# run it. Leo, 2026-11-05: "i meant can you do all of htem".
```

## `jobs.pr-quiet-period.runs-on`

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_na...`:

```text
# A fork pull request's sleep takes the fixed 2 vCPU label like every fork route (no pool read).
```

## `jobs.pr-quiet-period.steps[Wait until the pull request has had no push for the quiet period].continue-on-error`

Above `continue-on-error: true`:

```text
# A failed or timed-out wait never holds the checks: every job after it runs on !cancelled().
```

## `jobs.push-head-preflight`

Above `push-head-preflight:`:

```text
# feat-cmux-next push CI is the Swift app build only (Lawrence, 2026-10-10): its
# pushes run the Release compile, the app scheme compile and the nightly-next
# request. checks, web bundles, swift test, daemon tests and generated files run
# on workflow_dispatch (gh workflow run cmux-next.yml --ref <ref>). A same-repository pull
# request into feat-cmux-next runs the Mac tiers its paths reach (#22303), but the Release
# compile and the app scheme compile only with full-ci (2026-10-21). The fast-check
# path keeps the Mac tiers from occupying a scarce owned lane;
# macos-placement sends compatible work to free capacity when no owned runner is idle.
# A push can sit in the owned-pool queue after newer commits have landed.
# Resolve the branch head before any Mac job requests a runner.
# The lookup fails open so the current head still gets its compile and
# nightly-next promotion. Keep the run-id concurrency group below: rescue
# reruns of an older push must not cancel the newest pending run.
```

## `jobs.push-head-preflight.if`

Above `if: ${{ !cancelled() && inputs.same_tree_sha == '' }}`:

```text
# It starts at once: the Mac jobs wait for the pull request quiet period through macos-placement.
```

## `jobs.path_route`

Above `path_route:`:

```text
# Picks the tiers a pull request runs (scripts/ci/cmux_next_route.py; the
# header above lists them). The diff is the merge commit against its first
# parent, so commits that landed on the base after the branch point are not
# counted as the pull request's own. Labels are read live, so labeling a
# PR full-ci and re-running the workflow runs every tier, not only the
# routed ones.
# Pushes and dispatches run every tier.
#
# The daemon and scheme tiers also need this commit's same-tree cmux-tui.
# It is probed once here, never awaited (pin-cmux-tui.sh probe): published,
# the tree jobs run in this run; still being built, this run leaves a
# cmux-next-tree-wait-<key> marker and skips them, and a trusted publication
# may dispatch this workflow's same-tree mode for it
# (scripts/ci/cmux_next_tree_notify.py). A superseded push skips them. PRs
# never create a synthetic pin ref: a cold PR tree is skipped with a named
# reason, while trusted branch pushes still report an unavailable tree.
```

## `jobs.path_route.runs-on`

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_na...`:

```text
# The run's router: a declared light job (.github/runners.json hosted_light_jobs), 30-50 s of work
# (a depth-2 checkout, the path classifier, a read-only tree probe). A fresh placement observation
# takes fleet Linux or an idle mini first; a hosted/paid route remains the fail-open fallback.
```

## `jobs.path_route.timeout-minutes`

Above `timeout-minutes: 8`:

```text
# Above the probe steps' own limits, so a slow probe fails open (below)
# instead of cancelling the job and skipping every compile and test job.
```

## `jobs.path_route.permissions.actions`

Above `actions: read`:

```text
# This job executes the checked-out revision's routing and probe scripts,
# including on same-repository pull requests. It may inspect Actions and
# source, but only trusted default-branch controls may mutate either.
```

## `jobs.path_route.outputs.mac_release`

Above `mac_release: ${{ steps.route.outputs.mac_release }}`:

```text
# A same-repository pull request runs the Mac Release compile only when this is true: it changes
# an input only that xcodebuild sees (cmux_next_route.MAC_RELEASE_INPUTS).
```

## `jobs.path_route.outputs.fast_tier`

Above `fast_tier: ${{ steps.route.outputs.fast_tier }}`:

```text
# The Mac fast tier's package build and suites (cmux_next_route.py fast_tier): false for a
# pull request whose change none of them reads (a daemon-only Rust change, an app-host file).
```

## `jobs.path_route.outputs.tree_state`

Above `tree_state: ${{ steps.marker-upload.outcome == 'failure' && 'failed' || steps.tree-final.outputs.tree_state || steps.tree.outputs.tree_state }}`:

```text
# ready, deferred, superseded or failed; empty when no tree tier runs.
```

## `jobs.path_route.outputs.tree_fetch_key`

Above `tree_fetch_key: ${{ steps.tree-final.outputs.tree_fetch_key || steps.tree.outputs.tree_fetch_key }}`:

```text
# A pull request that changes no cmux-tui path and whose own tree is not
# ready: the published tree its tree jobs fetch (CMUX_TUI_TREE_KEY).
```

## `jobs.path_route.outputs.generated_host`

Above `generated_host: ${{ steps.route.outputs.generated != 'true' && 'none' || inputs.base_tier == true && 'generated-files' || github.event_name == 'push' && step...`:

```text
# The one job that checks the generated files on its own package build (HQ#4724: skip compiles
# that add no signal). daemon-test on a push it runs on (a ready tree), else swift-test where it
# runs and builds (its targets; on a pull request only with full-ci), else daemon-test where it
# runs, else the generated-files job's own build. swift-test and daemon-test then never compete with a third
# `swift build --build-tests`; generated-verdict gives the folded verdict its own check.
# A base tier run (inputs.base_tier) checks them on the generated-files job itself: its standalone
# `cmux-next generated files` verdict is the base verdict a pull request's is compared with.
```

## `jobs.path_route.steps[uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2].with.fetch-depth`

Above `fetch-depth: 2`:

```text
# The merge commit and its first parent (the base).
```

## `jobs.path_route.steps[Classify pull request paths].env.BASE_TIER_COALESCE`

Above `BASE_TIER_COALESCE: ${{ github.repository == 'manaflow-ai/cmux' && format('{0}', vars.CMUX_NEXT_BASE_TIER_COALESCE) != '0' && 'true' || 'false' }}`:

```text
# '0' turns the coalescing off: every feat-cmux-next push runs its base Mac tier again.
```

## `jobs.path_route.steps[Classify pull request paths].env.DEV_LANDING_COMPILE`

Above `DEV_LANDING_COMPILE: ${{ format('{0}', vars.CMUX_NEXT_DEV_LANDING_COMPILE) }}`:

```text
# '0': the push's scheme compile is also the DEV landing build (cmux-scheme-compile's DEV
# Release step), so a push keeps it.
```

## `jobs.path_route.steps[Classify pull request paths].env.EVENT_LABELS`

Above `EVENT_LABELS: ${{ join(github.event.pull_request.labels.*.name, ',') }}`:

```text
# The labels at the push. A re-run keeps that event, so it reads them
# live: adding full-ci or dev-build and re-running routes on them.
```

## `jobs.path_route.steps[Probe the same-tree cmux-tui]`

Above `- name: Probe the same-tree cmux-tui`:

```text
# One look (and one short re-check of a missing run list), no wait.
# Fails open: the tiers above are already routed, so a probe that errs or
# passes its 2 minutes leaves tree_state empty (the tree jobs skip) and
# every other routed job still runs (2026-10-27: per-run fetches of a
# lane-branch push burst held this step past the job limit, and the
# cancelled job skipped the Release compiles and swift test).
```

## `jobs.path_route.steps[Probe the same-tree cmux-tui].env.CMUX_TUI_TREE_RUN_FETCH_SECONDS`

Above `CMUX_TUI_TREE_RUN_FETCH_SECONDS: "45"`:

```text
# The active-run commit fetches share this budget (pin-cmux-tui.sh
# active_publisher_for_key); an unread run reads as unknown.
```

## `jobs.path_route.steps[Probe the same-tree cmux-tui].env.CMUX_TUI_TREE_PUBLISHER_SHA`

Above `CMUX_TUI_TREE_PUBLISHER_SHA: ${{ github.event_name != 'pull_request' && inputs.dev_daily != true && github.sha || '' }}`:

```text
# Push runs use the artifacts run already started by that protected
# branch. Pull requests may fall back to the base tree; a missing own
# tree fails closed because this checked-out revision cannot dispatch.
# A scheduled DEV run likewise owns its exact SHA without mutation
# authority; only trusted controls may start a publisher. Its probe
# looks once (read-only) for its push's artifacts run or a same-tree
# run and defers to it; dev-daily-tree-wait then waits.
```

## `jobs.path_route.steps[Probe the same-tree cmux-tui].env.CMUX_TUI_TREE_BASE_FALLBACK`

Above `CMUX_TUI_TREE_BASE_FALLBACK: ${{ (inputs.dev_daily == true || steps.route.outputs.own_tui == 'false') && '1' || '' }}`:

```text
# DEV is a cutting-edge app channel: if this head's daemon tree is
# still publishing, build the exact app head against the newest
# published compatible tree instead of waiting on nightly's tree.
```

## `jobs.path_route.steps[Probe the same-tree cmux-tui].env.CMUX_TUI_TREE_PUBLISHER_WAIT_SECONDS`

Above `CMUX_TUI_TREE_PUBLISHER_WAIT_SECONDS: ${{ github.event_name == 'pull_request' && '0' || '' }}`:

```text
# No PR merge-tree publisher exists. A PR looks once for an already
# published tree or trusted publisher; a cold own tree is skipped.
```

## `jobs.path_route.steps[Write the tree wait marker]`

Above `- name: Write the tree wait marker`:

```text
# What a trusted publication needs to start this run's tree jobs later.
# A cold PR tree has no publisher, so it leaves no marker. An active
# trusted run still gets one and may later start the tree jobs.
```

## `jobs.path_route.steps[Write the tree wait marker].if`

Above `if: inputs.dev_daily != true && (steps.tree.outputs.tree_state == 'deferred' || (github.event_name != 'pull_request' && steps.tree.outputs.tree_state == 'fai...`:

```text
# A DEV daily run waits for its own tree (job dev-daily-tree-wait): a
# same-tree run would start only while the tip is still its SHA.
```

## `jobs.path_route.steps[Probe the same-tree cmux-tui after the marker]`

Above `- name: Probe the same-tree cmux-tui after the marker`:

```text
# Looked at again after the marker is up: a publish that lands later
# sees the marker, and one that landed before this look is seen here.
```

## `jobs.path_route.steps[Probe the same-tree cmux-tui after the marker].timeout-minutes`

Above `timeout-minutes: 2`:

```text
# Fails open like the first probe: its tree_state stands.
```

## `jobs.path_route.steps[Probe the same-tree cmux-tui after the marker].env.CMUX_TUI_TREE_PUBLISHER_SHA`

Above `CMUX_TUI_TREE_PUBLISHER_SHA: ${{ github.event_name != 'pull_request' && inputs.dev_daily != true && github.sha || '' }}`:

```text
# A scheduled DEV run owns its exact SHA. A cold tree with no active
# publisher fails closed; this checked-out revision never starts one.
```

## `jobs.path_route.steps[Probe the same-tree cmux-tui after the marker].env.CMUX_TUI_TREE_PUBLISHER_WAIT_SECONDS`

Above `CMUX_TUI_TREE_PUBLISHER_WAIT_SECONDS: "0"`:

```text
# The first probe already inspected the trusted publisher.
```

## `jobs.dev-daily-tree-wait`

Above `dev-daily-tree-wait:`:

```text
# A cmux NEXT DEV daily run builds exactly the SHA main's dispatcher asked
# for. When its cmux-tui tree is cold, path routing defers without acquiring
# mutation authority; a trusted publisher may still satisfy the wait. This
# waits on Linux for the tree,
# then cmux-scheme-compile builds the DEV app in this run
# (scripts/cmux-next/wait-dev-daily-tree.sh, tested by
# scripts/cmux-next/tests/wait-dev-daily-tree.test.sh).
```

## `jobs.dev-daily-tree-wait.permissions.actions`

Above `actions: read`:

```text
# The selected revision may inspect a publisher, never start one.
```

## `jobs.macos-placement.needs`

Above `needs: [path_route, push-head-preflight, pr-quiet-period, app-compile-placement]`:

```text
# After the pull request quiet period (skipped outside pull requests, hence !cancelled()): every Mac
# job needs this job, so none starts before the wait ends, and each is placed from a reading taken
# after it. app-compile-placement already gave the PR's app compile its gateway runner, which this
# reading then sees busy.
```

## `jobs.macos-placement.if`

Above `if: ${{ !cancelled() && ((inputs.same_tree_sha == '' && needs.push-head-preflight.outputs.current == 'true' && needs.path_route.outputs.macos == 'true') || (...`:

```text
# Attempt 1's macOS jobs stay on the owned side label while the fleet
# drains. A bot retry runs placement again so it can use a newly free
# owned GUI/session runner before falling back to Blacksmith.
# Every step fails open: a skipped or failed placement leaves
# fallback_jobs empty, so the jobs keep the side label and the marker is
# still uploaded. It runs only where attempt 1's Mac jobs may
# take the side label (CMUX_NEXT_SIDE_ROUTE's owned branch): a fork, another
# owner, owned pools off or a re-run starts no Linux runner for it, and the
# Mac jobs (needs plus !cancelled()) take their route without it. A re-run
# needs no marker of its own: its Mac jobs take the fallback, and the
# rescue's watch of a side lane ends at attempt 2.
# Same-tree mode runs it too: its owned-pool-watch marker lets the rescue
# re-run a tree job that a mini refuses (no head to move on a dispatch).
# A pull request the router sends to no Mac tier starts no Mac job (the
# fast tier follows the route too), so it places nothing.
```

## `jobs.macos-placement.timeout-minutes`

Above `timeout-minutes: 8`:

```text
# Checkout (1m), three bounded token mints (3m), placement (2m),
# marker upload (1m), plus time for runner setup and action cleanup.
```

## `jobs.macos-placement.env`

Above `env:`:

```text
# The workflow's CMUX_NEXT_SIDE_ROUTE, with the rescue's full re-run (attempt 2 by
# github-actions[bot]) placed too: its steps read what is free when it starts, and the
# cascade jobs take a free Blacksmith slot instead of the end of the side queue they waited
# in (next_macos_cascade.bot_rerun()). Only this job's steps read this copy.
```

## `jobs.macos-placement.permissions.actions`

Above `actions: read`:

```text
# The queue janitor's pool snapshot, Blacksmith's queued jobs (next_macos_cascade.py).
```

## `jobs.macos-placement.outputs.blacksmith_12_jobs`

Above `blacksmith_12_jobs: ${{ steps.place.outputs.blacksmith_12_jobs }}`:

```text
# The jobs no idle mini took that Blacksmith has a free slot for now, 12
# vCPU first and then 6, and the Blacksmith label the bot's overflow
# attempt takes (scripts/ci/next_macos_cascade.py).
```

## `jobs.macos-placement.outputs.retry_runner`

Above `retry_runner: ${{ steps.place.outputs.free_retry_runner }}`:

```text
# The overflow label only while it has a free slot, else empty (the owned
# label below). Read from free_retry_runner, which a placement script
# predating the free-slot rule never writes.
```

## `jobs.macos-placement.outputs.deferred_runner`

Above `deferred_runner: ${{ steps.place.outputs.deferred_runner }}`:

```text
# Preserve the existing queue only when the cascade has no admissible target.
```

## `jobs.macos-placement.outputs.fresh_stalled`

Above `fresh_stalled: ${{ steps.place.outputs.fresh_stalled }}`:

```text
# The Blacksmith labels a feed's compile counts as full (next_macos_cascade.fresh_stalled()): a feat-cmux-next
# push's Release compile never falls back to one of them.
```

## `jobs.macos-placement.outputs.fleet_jobs`

Above `fleet_jobs: ${{ steps.place.outputs.fleet_jobs }}`:

```text
# The FLEET_CLIENT_JOBS that no owned or Blacksmith macOS label can take now (every one full or
# dead, next_macos_cascade.place()), space-delimited like blacksmith_6_jobs: each runs as a thin
# cmux-ci client on gateway_runner (<job>-fleet), and the job itself only reports its verdict.
```

## `jobs.macos-placement.outputs.fast_runner`

Above `fast_runner: ${{ steps.place.outputs.fast_runner }}`:

```text
# vars.CI_FAST_LANE_RUNNER while one of its runners is idle, else empty
# (side_lane_placement.fast_route()): the fast tier never queues on it.
```

## `jobs.macos-placement.outputs.fresh_runner`

Above `fresh_runner: ${{ steps.place.outputs.fresh_runner }}`:

```text
# The DEV compile slot and the feed compiles its idle runners take (side_lane_placement.fresh_route()).
```

## `jobs.macos-placement.outputs.gateway_runner`

Above `gateway_runner: ${{ steps.place.outputs.gateway_runner }}`:

```text
# vars.CI_COMPILE_CHECK_GATEWAY, or a wider class of it, while it has an idle runner for
# each gateway job, else empty (side_lane_placement.gateway_route()); gateway_attempt is
# the run attempt that judged it. A gateway job runs only on a reading from its own
# attempt; with none (a re-run, a skipped or older placement) it skips and its Mac
# fallback runs, never a queue nobody saw free.
```

## `jobs.macos-placement.outputs.placed_attempt`

Above `placed_attempt: ${{ github.run_attempt }}`:

```text
# The attempt this placement ran in. A re-run of failed jobs carries the placement job, and its
# outputs, from an earlier attempt: a job output is evaluated when its job runs, so this stays that
# attempt's number. Every Mac job reads blacksmith_12_jobs, blacksmith_6_jobs and
# retry_runner only while this equals its own run_attempt; a carried reading is stale (run
# 40398277457, 2026-10-26: attempt 2 took blacksmith-6vcpu-macos-26 on a reading 39 minutes old and
# waited 55 minutes for a runner), so the job takes the owned label instead.
```

## `jobs.macos-placement.outputs.gui_runner`

Above `gui_runner: ${{ steps.place.outputs.gui_runner }}`:

```text
# GUI suites have a separate label. The generic side label is also
# carried by headless AWS workers for compile-only capacity.
```

## `jobs.macos-placement.outputs.session_runner`

Above `session_runner: ${{ steps.place.outputs.session_runner }}`:

```text
# daemon-test and generated-files need a logged-in session, not the
# console gui token: the session label (glaeda#1530) while an online
# runner carries it and it has room (role_room(): not while the
# janitor finds it unserved, cmux#24295), else gui_runner. Empty from a
# trusted base whose placement predates it, so those jobs then read
# gui_runner. Their literal last owned leg is the gui label, never the
# session label: no placement judged it (tests/test_ci_runs_on_fallback.py).
```

## `jobs.macos-placement.outputs.gui_overflow`

Above `gui_overflow: ${{ steps.place.outputs.gui_overflow }}`:

```text
# The Blacksmith macOS label the GUI jobs take while no owned GUI runner has room (a queue deeper than
# the pool, side_lane_placement.role_room()), and on the rescue's full re-run; empty otherwise.
```

## `jobs.macos-placement.outputs.session_lane_runner`

Above `session_lane_runner: ${{ steps.place.outputs.session_lane_runner }}`:

```text
# SESSION_LANE (vars.CI_SESSION_LANE_RUNNER) while it has room (side_lane_placement.role_room()), else empty:
# generated files take the variable on this attempt only then.
```

## `jobs.macos-placement.steps[Check out the trusted placement]`

Above `- name: Check out the trusted placement`:

```text
# The placement code from the base branch, as ci-macos.yml's admission-placement uses it.
```

## `jobs.macos-placement.steps[Mint the cmux-bot runner-read token]`

Above `- name: Mint the cmux-bot runner-read token`:

```text
# The second identity for the same runner reads: when the routing App's read is refused (403s
# from 22:47Z on 2026-10-26 sent every DEV compile to an owned queue), the placement reads again
# with cmux-bot (organization self-hosted runners: read). A failed mint leaves it empty.
```

## `jobs.macos-placement.steps[Mint the glaeda read token]`

Above `- name: Mint the glaeda read token`:

```text
# Reads go through the manaflow-glaeda-route App's own budget, not the GITHUB_TOKEN
# budget every workflow shares (it ran out on 2026-10-25 and the nightly publish
# failed). No key (a fork) or a failed mint leaves it empty: GITHUB_TOKEN reads.
```

## `jobs.macos-placement.steps[Place the macOS jobs]`

Above `- name: Place the macOS jobs`:

```text
# In priority order: the scheme compile keeps its DerivedData on a mini
# (cold on Blacksmith), and only a mini compiles the CEF shim. A Release
# compile no idle mini takes (on a feat-cmux-next push: no idle promotion
# mini) takes a free Blacksmith slot (next_macos_cascade.py).
```

## `jobs.macos-placement.steps[Place the macOS jobs].env.CI_FLEET_GATES`

Above `CI_FLEET_GATES: ${{ vars.CI_FLEET_GATES }}`:

```text
# Glaeda's authoritative per-label gate reading; this avoids a second API request.
```

## `jobs.macos-placement.steps[Place the macOS jobs].env.CASCADE_RUNS`

Above `CASCADE_RUNS: >-`:

```text
# The cascade's jobs that run on this route at all (next_macos_cascade.py):
# not a job that path routing or the pull request's labels skip (a job
# missing here only stays on the minis' queue). The fast tier is always
# here; the placement drops it only while an idle runner carries
# FAST_LABEL, which it then takes (fast_runner).
```

## `jobs.macos-placement.steps[Place the macOS jobs].env.PROMOTE_LABEL`

Above `PROMOTE_LABEL: ${{ github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next' && github.run_attempt == 1 && vars.CI_NEXT_PROMOTE_POOL || '' }}`:

```text
# Attempt 1 of a feat-cmux-next push prefers the dedicated cmux NEXT
# nightly runner; a busy or unavailable runner uses Blacksmith overflow.
```

## `jobs.macos-placement.steps[Place the macOS jobs].env.FAST_LABEL`

Above `FAST_LABEL: ${{ vars.CI_FAST_LANE_RUNNER }}`:

```text
# The fast tier's reserved label, taken only while one of its runners is idle.
```

## `jobs.macos-placement.steps[Place the macOS jobs].env.SESSION_LANE`

Above `SESSION_LANE: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_n...`:

```text
# Generated files' own session lane, weighed like the gui and session routes (session_lane_runner).
# Fork branch first: a fork never reads the variable, and a label that is not glaeda-* places no lane.
```

## `jobs.macos-placement.steps[Place the macOS jobs].env.FRESH_LABEL`

Above `FRESH_LABEL: ${{ vars.CI_DEV_COMPILE_RUNNER || 'glaeda-dev-std-xcode-26.6' }}`:

```text
# The freshness slot (glaeda#1628: one side instance on opted-in minis carries only this label;
# glaeda#1636: its hook admits cmux-scheme-compile on a feat-cmux-next push or a dev_daily dispatch
# and a push's release-compile, and while idle it keeps one feed compile's units from PR jobs),
# taken while idle by the FRESH_JOBS that hook admits (FRESH_SLOT_JOBS).
```

## `jobs.macos-placement.steps[Place the macOS jobs].env.GATEWAY_LABEL`

Above `GATEWAY_LABEL: ${{ vars.CI_COMPILE_CHECK_GATEWAY }}`:

```text
# The build-fleet compiles' gateway, taken (or a wider class of it) only while a runner is
# idle (gateway_runner). With none idle, swift-canary-fleet does not run and swift-canary
# cascades. The PR's app compile took its gateway before the quiet period ended
# (app-compile-placement); with none, its Mac Release compile, which runs when
# app-compile-fleet gives no verdict, is in CASCADE_RUNS above.
```

## `jobs.macos-placement.steps[Place the macOS jobs].env.FLEET_CLIENT_JOBS`

Above `FLEET_CLIENT_JOBS: fast-tier`:

```text
# The cascade jobs with a build-fleet client job (<job>-fleet, which runs only the cmux-ci client on
# gateway_runner): with every macOS label full or dead, or when a Blacksmith macOS label took them
# (a cold build there ran the fast tier out of its 20 minutes, cmux#38130), they are listed in
# fleet_jobs instead, and the job itself only reports its client's verdict. A job joins only with its client
# (GatewayRunsOnlyTheFleetClient). A listed job's client needs an idle gateway runner of its own
# beyond GATEWAY_JOBS', or placement lists nothing (side_lane_placement.fleet_gateway()). swift-test
# and daemon-test are not cascade jobs, so placement never lists them; daemon-test also needs the
# same-tree cmux-tui daemon, which a fleet suite step reports as no result.
```

## `jobs.macos-placement.steps[Place the macOS jobs].env.GATEWAY_JOBS`

Above `GATEWAY_JOBS: >-`:

```text
# The gateway jobs this run starts (their own `if`s), each needing an idle runner.
```

## `jobs.macos-placement.steps[Place the macOS jobs].env.GUI_LAST_RESORT`

Above `GUI_LAST_RESORT: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || 'blacksmith-6vcpu-macos-26' }}`:

```text
# The GUI jobs' last resort when the placement names neither a GUI route nor a GUI overflow (the shell
# below). Fork branch first, as every runs-on here: a fork never names a Blacksmith label.
```

## `jobs.macos-placement.steps[Place the macOS jobs].env.FIRST_JOBS`

Above `FIRST_JOBS: ${{ github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next' && github.run_attempt == 1 && 'release-compile' || '' }}`:

```text
# A feat-cmux-next push's Release compile gates the nightly-next request, so the cascade
# places it ahead of the run's other jobs (next_macos_cascade.FIRST_JOBS).
```

## `jobs.macos-placement.steps[Place the macOS jobs].env.FRESH_JOBS`

Above `FRESH_JOBS: ${{ (github.run_attempt == 1 || github.run_attempt == 2 && contains(fromJSON('["github-actions[bot]","cmux-bot[bot]"]'), github.triggering_actor)...`:

```text
# The jobs a feed's freshness waits on: when the counts cannot be read (a 403 on the route token, a
# stale snapshot) they take Blacksmith 6 vCPU, the last resort, instead of an owned queue nobody
# measured (next_macos_cascade.unread_fresh_jobs()). A DEV daily's Release compile feeds the DEV
# channel, a feat-cmux-next push's gates nightly-next.
```

## `jobs.macos-placement.steps[Mark a run on the minis]`

Above `- name: Mark a run on the minis`:

```text
# Fail-safe: without the marker the run is only not watched. Skipped
# when every macOS job took its fallback, and on a push: the push Mac
# jobs' branch groups bound that queue, and the rescue would cancel a
# running push run once a newer push exists.
```

## `jobs.macos-placement.steps[Upload the owned-pool watch marker]`

Above `- name: Upload the owned-pool watch marker`:

```text
# With no free overflow slot a bot re-run takes the same side label
# (retry_runner is empty), so the rescue's cancel and re-run would only
# send the run to the back of that queue: run 39615562861 went round
# twice on 2026-10-21. The refusals marker has the sweeper re-run what a
# mini refuses and leave a long queue alone.
```

## `jobs.portable-placement`

Above `portable-placement:`:

```text
# cmux-next checks' runner.
# Jobs that need neither Linux nor Blacksmith take fleet Linux (vars.LINUX_RUNNER when it names our
# own Linux runner), else a mini idle now with no nightly job waiting on its pool, else their
# Blacksmith label (scripts/ci/portable_job_placement.py; Leo, 2026-10-31: "i mean the linux things
# cant our minis just run them"). Every step fails open: no output keeps each job's Blacksmith route.
# The placement code comes from the base branch, as macos-placement's does.
# This bootstrap must start independently of the labels it validates: hosted Ubuntu on attempt 1,
# then the measured paid retry route. Its consumers take live fleet capacity from its outputs.
```

## `jobs.portable-placement.if`

Above `if: ${{ !cancelled() && vars.CI_PORTABLE_LIGHT_JOBS_OFF != '1' && inputs.dev_daily != true && inputs.base_tier != true && inputs.same_tree_sha == '' && githu...`:

```text
# It starts at once and places only Linux-portable jobs (checks, path_route), which start at once too,
# so the runners it finds idle are still idle when the jobs it places start. The PR quiet period
# holds only the Mac jobs (macos-placement).
```

## `jobs.portable-placement.permissions.actions`

Above `actions: read`:

```text
# The queue janitor's pool snapshot (nightly jobs waiting on a pool).
```

## `jobs.portable-placement.outputs.placed_attempt`

Above `placed_attempt: ${{ github.run_attempt }}`:

```text
# A re-run of failed jobs carries this job's outputs from an earlier attempt; a job takes them
# only in the attempt that placed it, so a stale reading never sends it to a busy mini.
```

## `jobs.portable-placement.steps[Drop stale submodule checkouts (self-hosted reused workspace)]`

Above `- name: Drop stale submodule checkouts (self-hosted reused workspace)`:

```text
# A mini or fleet Linux host reuses its workspace: drop the submodule checkouts a previous job
# left there (a no-op on Blacksmith, which starts with none).
```

## `jobs.portable-placement.steps[Place the portable jobs]`

Above `- name: Place the portable jobs`:

```text
# The fresh registration census already carries the trusted queue snapshot.
# No private App token is needed: missing or stale state keeps the overflow route.
```

## `jobs.portable-placement.steps[Place the portable jobs].env.FLEET_LINUX`

Above `FLEET_LINUX: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.event_name == 'pull_request' && github.event.pull_request.head.repo.ful...`:

```text
# Fork branch first: a fork never reads the runner variables (and its job is skipped); ubuntu-24.04 places nothing.
```

## `jobs.checks.needs`

Above `needs: [portable-placement]`:

```text
# feat-cmux-next pushes run it again (Leo, 2026-10-19; cx-g34i had dropped it): a direct push's
# red shows on that push, and a pull request's red has a base run to be compared with.
# Not in a base tier run: the push of its commit already ran it.
# !cancelled(): a skipped or failed portable-placement (a fork, a re-run) leaves the Blacksmith route.
```

## `jobs.checks.runs-on`

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || needs.portable-placement.outputs.placed_attempt == format('{0}', github.run_attemp...`:

```text
# Fleet Linux, then a free mini (portable-placement), then Blacksmith 16 vCPU. The slow checks run
# concurrently, one per CPU ("Start the slow checks in the background", scripts/ci/run-checks-concurrently.sh). While the overflow
# switch has failed over it takes 8 vCPU, not 32 (.github/runners.json linux_sizes), hence 15 minutes.
# The checks are Python and bash; none needs Linux.
```

## `jobs.checks.steps`

Above `steps:`:

```text
# Pull requests into feat-cmux-next run the cheap static checks, and so does
# every feat-cmux-next push: gh-merge-green excuses a PR's red lint only when
# the base's latest push run prints every finding too, so a base red no longer
# refuses every PR (2026-10-19). The size
# cap and crash ratchet are cadence checks: they run on pushes and on the
# full-ci batched integration PR, not on every contributor PR. God files and types are warn-only
# (Lawrence 2026-10-10): over the hard ceiling (GODFILES_WARN_SLACK: allowance
# + 20% of the budget, so a new type past 1200 lines) the step writes a
# warning and passes. Other style ratchets warn under a hard ceiling and fail
# over it: l10n style errors and custom scrollbars (by count).
# A warning is ratchet debt: an annotation on the PR run (the issue-writing
# ratchet-debt job was removed 2026-10-13: push runs skipped this job then,
# and it never filed an issue). Concurrency, notification
# centers and crash safety have no warning tier. Each ceiling is set on its
# own step only: the script tests below expect every hit to fail.
# Since 2026-10-19 (Leo) every structural, style, size and drift step named
# in the aggregate's STYLE_CHECKS only warns while CMUX_NEXT_STYLE_GUARDS
# (workflow env) is `warn`; the correctness and safety steps still fail.
```

## `jobs.checks.steps[uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2].with.fetch-depth`

Above `fetch-depth: 2`:

```text
# The merge commit and its first parent: the god-file checks compare a
# pull request against its base.
```

## `jobs.checks.steps[Drop stale submodule checkouts (self-hosted reused workspace)]`

Above `- name: Drop stale submodule checkouts (self-hosted reused workspace)`:

```text
# A mini or fleet Linux host reuses its workspace: drop the submodule checkouts a previous job
# left there (a no-op on Blacksmith, which starts with none).
```

## `jobs.checks.steps[Start the slow checks in the background]`

Above `- name: Start the slow checks in the background`:

```text
# The slow independent checks run concurrently in the background, at most one per CPU, from here
# on (one after another they took about 7 of the job's 8.4 min). Each of their steps below waits
# for its own commands, prints their output and keeps its name, id and outcome. A `[step-id]`
# line names the step the commands under it belong to; the longest commands start first.
# Not here: "Pushed commits add no violations" deepens the clone and writes its step summary.
```

## `jobs.checks.steps[God files and types (Swift)]`

Above `- name: God files and types (Swift)`:

```text
# Every check runs even when an earlier one fails; the last step fails the
# job once, naming each red check. Checkout stays fatal: with no tree,
# the checks have nothing to read.
```

## `jobs.checks.steps[God files and types (Swift)].run`

Above `run: |`:

```text
# A pull request fails only on what it grew (its merge commit's first
# parent is the base), so a god file already on the base never blocks
# it. A push checks every file.
```

## `jobs.checks.steps[God files (cmux-tui Rust)].run`

Above `run: |`:

```text
# A pull request fails only on what it grew (its merge commit's first
# parent is the base), so a god file already on the base never blocks
# it. A push checks every file.
```

## `jobs.checks.steps[CmuxNextApp size cap]`

Above `- name: CmuxNextApp size cap`:

```text
# Every CmuxNextApp edit re-emits the whole module; the target may only
# shrink, new features go in their own target (code-quality.md SW14).
```

## `jobs.checks.steps[CmuxNextApp size cap].run`

Above `run: |`:

```text
# A pull request or push that does not grow the App's source passes even
# over the cap: a pull request compares with its merge commit's first
# parent, a push with the commit before it (fetched: checkout is depth 2).
# A push with no before commit (a new branch) keeps the plain cap.
```

## `jobs.checks.steps[No new SwiftUI (macOS UI is AppKit)]`

Above `- name: No new SwiftUI (macOS UI is AppKit)`:

```text
# Blocking (not a warn-only style check): the allowlist only shrinks, so a
# pull request compares with its merge commit's first parent and a push
# with the commit before it (plans/cmux-next/no-swiftui-DESIGN.md).
```

## `jobs.checks.steps[Default cursor (no pointing hand in app UI)]`

Above `- name: Default cursor (no pointing hand in app UI)`:

```text
# The user (2026-10-30): "change all pointers back to cursor-default". App UI shows the
# arrow; only web page and terminal content may show the pointing hand (allowlist).
```

## `jobs.checks.steps[One web view factory]`

Above `- name: One web view factory`:

```text
# Every web view goes through the engine decision (browser.defaultEngine,
# browser.siteEngines): PageWebView for cmux pages, BrowserTab for tabs.
```

## `jobs.checks.steps[Tests inject their notification center]`

Above `- name: Tests inject their notification center`:

```text
# A test that posts to a process-global notification center reaches every
# observer in the test process on the posting thread (#18771's signal 5).
```

## `jobs.checks.steps[Scrollbars thin, one style]`

Above `- name: Scrollbars thin, one style`:

```text
# SCROLLBARS-THIN: no forced scroller style, hidden indicators or
# custom web scrollbars outside the one shared style (SystemScrollers.swift,
# webviews/src/scrollers.ts): thin, shown only while scrolling.
```

## `jobs.checks.steps[Motion tokens]`

Above `- name: Motion tokens`:

```text
# Animation timing comes from the Motion tokens (plans/cmux-next/motion.md),
# so ui.animationSpeed and Reduce Motion reach every animation.
```

## `jobs.checks.steps[Overlays are glass, never solid]`

Above `- name: Overlays are glass, never solid`:

```text
# Glass, never solid (Leo 2026-10-21: "STOP DOING SOLID. WE HAVE GLASS, SO JUST USE GLASS."):
# popovers, tooltips, hover cards, menus and sidebar cards paint no solid fill unless
# check-overlay-glass.py lists why (ccde782cb51 turned them solid unnoticed).
```

## `jobs.checks.steps[Type scale]`

Above `- name: Type scale`:

```text
# The one type scale (schemas/type-scale/type-scale.json): its CSS and Swift copies, and no new raw
# font sizes or off-scale weights in the app's Swift (fails the checks; the webviews ratchet runs in react-apps-check).
```

## `jobs.checks.steps[UI font (the system font)]`

Above `- name: UI font (the system font)`:

```text
# UI font (Lawrence 2026-11-07: "default fonts on cmux for everything should be macos default,
# not inter"): the UI font is the macOS system font, no letter-spacing, nothing bundled
# (schemas/type-scale/ui-font-pin.json pins it). Fails on another stack, letter-spacing on the
# system font, a bundled Inter file, a webviews default stack that names Inter, or a pin change
# with no `Font-order:` trailer. A pull request's own commits are fetched for the trailer, which
# the pushed-commits step below then sees too.
```

## `jobs.checks.steps[Motion scale]`

Above `- name: Motion scale`:

```text
# The one motion duration scale (schemas/motion-scale/motion-scale.json): its Swift, CSS and
# TypeScript copies (Leo 2026-10-20: one token file both sides read).
```

## `jobs.checks.steps[Surface roles]`

Above `- name: Surface roles`:

```text
# The overlay surface roles (schemas/surface-roles/surface-roles.json): their Swift and CSS
# copies match it (Glass, never opaque: one token set for every popover, menu, card, toast and sheet).
```

## `jobs.checks.steps[Menu metrics]`

Above `- name: Menu metrics`:

```text
# The one menu row grid (schemas/menu-metrics/menu-metrics.json): its Swift and CSS copies, and no
# menu with its own paddings (Leo 2026-10-21: one left alignment across every menu).
```

## `jobs.checks.steps[Protected-folder copies]`

Above `- name: Protected-folder copies`:

```text
# LAUNCH-NO-TCC-PROMPTS: the Swift and TypeScript copies of the one
# protected-folder list (cmux-tui/crates/acpmux/data/protected-folders.json).
```

## `jobs.checks.steps[Settings source copies]`

Above `- name: Settings source copies`:

```text
# The hand-edited settings sources in schemas/settings (retired keys so
# far, cx-d5b5d) and their generated Swift copies; the daemon embeds the JSON.
```

## `jobs.checks.steps[Phone lane field allowlist]`

Above `- name: Phone lane field allowlist`:

```text
# The phone daemon lane's per-command field allowlist, generated from the daemon's request
# schema and the lane's command allowlist (DaemonLanePolicy+Fields.generated.swift).
```

## `jobs.checks.steps[Backdrop art export]`

Above `- name: Backdrop art export`:

```text
# The backdrop art list (ids, titles, image and thumbnail URLs, Shuffle Daily) exported
# from the CmuxNextDesign Swift to plans/cmux-next/backdrop-art.json for the GPUI app.
```

## `jobs.checks.steps[Script tests (pin-cmux-tui, embed-cef, ensure-cef store)]`

Above `- name: Script tests (pin-cmux-tui, embed-cef, ensure-cef store)`:

```text
# Behavior tests of the build scripts: pin-cmux-tui.sh fetch on a stale
# --ref mirror and on a reused runner workspace, embed-cef.sh reaching
# ensure-cef.sh under set -u, and ensure-cef.sh's controller artifact
# store source. The run-check test covers the same-tree wait failing
# fast when the artifacts run for its commit was cancelled or superseded.
```

## `jobs.checks.steps[Ghostty resources bundle]`

Above `- name: Ghostty resources bundle`:

```text
# The app's Ghostty shell integration comes from ghostty-next (the
# Ghostty of GhosttyNextKit and libghostty-vt): the bundle phase output
# must equal its source tree.
```

## `jobs.checks.steps[Bundled terminfo]`

Above `- name: Bundled terminfo`:

```text
# The bundled terminfo (Ghostty's entries with cmux's overlay on top)
# carries ghostty-next's capabilities and cmux's 256-color 8-15 patch.
# Its own step, so the summary names it when it is red.
```

## `jobs.checks.steps[Package conventions lint]`

Above `- name: Package conventions lint`:

```text
# The repo-wide package conventions (namespace types, free functions,
# singletons, ...). test-ios.yml runs it only for pull requests, merge
# groups and dispatches; this step covers direct feat-cmux-next pushes.
```

## `jobs.checks.steps[Browser chrome icons]`

Above `- name: Browser chrome icons`:

```text
# The browser chrome draws Chromium's own icons (design/icons/chromium): the
# generated batch is current and no browser control uses an SF Symbol or a
# non-Chromium pack icon.
```

## `jobs.checks.steps[App Store review rules (cmux-next-ios intents, Info.plist)]`

Above `- name: App Store review rules (cmux-next-ios intents, Info.plist)`:

```text
# What App Store Connect rejects only after an upload (ITMS-90626 device
# names in App Intents text, 90683 purpose strings, ...), on the
# cmux-next-ios sources. The INTERNAL builder runs it again on the built app.
```

## `jobs.checks.steps[Perf source guard (no window capture or CATransaction.flush)]`

Above `- name: Perf source guard (no window capture or CATransaction.flush)`:

```text
# The perf gate's source guard without an app (I5: a theme change captures no window and
# forces no commit): a source scan of seconds, so it stays here while the perf gate itself runs
# only in the perf cron (cmux-next-perf-budgets.yml); two hits once landed by direct push
# (36c5b4217488, 715f623c97e1).
```

## `jobs.checks.steps[No fleet host names in gallery fixtures]`

Above `- name: No fleet host names in gallery fixtures`:

```text
# Gallery fixtures are public sample data the gallery and PR captures render: they name
# machines "studio-mac" or "build-box", never a fleet host (the capture privacy check
# refuses a still that shows one, and WorkspaceHoverCardGallery's "air-blue" did).
```

## `jobs.checks.steps[Kill switches are declared, tied to a PR and unexpired]`

Above `- name: Kill switches are declared, tied to a PR and unexpired`:

```text
# Per-PR kill switches (release-notes/next/kill-switches.json): each switch names its PR,
# owner and expiry, and goes red past its expiry until the killSwitch("pr-N") call, the
# old path and the entry are removed; flags.json may turn off only declared switches.
```

## `jobs.checks.steps[Tier routing]`

Above `- name: Tier routing`:

```text
# The tier routing on the committed target graph: a UI change selects its
# own test targets, a daemon change the live-daemon suites, an unknown
# path every tier.
```

## `jobs.checks.steps[Package dependency lists sorted]`

Above `- name: Package dependency lists sorted`:

```text
# The CmuxNextAppTests dependencies are one sorted entry per line, so two
# pull requests adding different modules merge cleanly; the long lines they
# all appended to conflicted on nearly every open pull request.
```

## `jobs.checks.steps[Web bundle key inputs]`

Above `- name: Web bundle key inputs`:

```text
# The web bundle source key covers every file outside webviews/ that a bundle
# imports, and the publish and routing path lists name each one (cx-wtsf3).
```

## `jobs.checks.steps[Prebuilt web bundles install and stamp]`

Above `- name: Prebuilt web bundles install and stamp`:

```text
# build-web-bundles.sh --from installs and stamps bundles built elsewhere. It and the key
# inputs test ran last in the web-bundles job until 2026-10-20: a red there failed the job
# that swift test, daemon tests and generated files wait on, so those tiers were skipped
# (and a skipped tier reads as passing) on every pull request while it stayed red.
```

## `jobs.checks.steps[Web update pointer]`

Above `- name: Web update pointer`:

```text
# The signed web update pointer (plans/cmux-next/web-ota.md): verifies only under a listed
# key, refuses a changed payload, and never moves back.
```

## `jobs.checks.steps[Companion workflows]`

Above `- name: Companion workflows`:

```text
# The companion workflows' structure: generated-files catch-up and the
# next-batch landing queue.
```

## `jobs.checks.steps[Base-red classifier (per test)]`

Above `- name: Base-red classifier (per test)`:

```text
# "Red on the base, so not ours" is judged per failing test, and a crash or a cut-short
# run is never the base's (scripts/ci/test_reds.py, after cmux#26346 landed with its own
# signal 6 behind a job-level base red).
```

## `jobs.checks.steps[DEV update and classic import scripts]`

Above `- name: DEV update and classic import scripts`:

```text
# The cmux NEXT DEV update script (an unchanged build is left alone; an
# update keeps sessions and reopens the app) and the classic session import.
```

## `jobs.checks.steps[Routing replay (router changes)]`

Above `- name: Routing replay (router changes)`:

```text
# A pull request that changes the router replays the last 30 merged PRs' changed files
# through the base router (the merge commit's HEAD^1) and its own: a tier the new router
# adds, or drops without naming a fast tier, fails (scripts/ci/cmux_next_route_replay.py).
```

## `jobs.checks.steps[Check the app FFI pin]`

Above `- name: Check the app FFI pin`:

```text
# Package.swift links the app FFI from one pinned release; the pin must
# match the FFI sources (every crate cmux-app-ffi reaches through Cargo
# path dependencies) and the release must be built from them. Here on
# Linux it runs on every push and pull request: in swift test a newer
# push replaced the waiting job, so tip runs rarely reached it.
#
# On a pull request the base's copy of the check and of its pin reader
# (the merge commit's first parent), extracted outside the checkout,
# judges a fresh worktree of the merge commit (--tree), with only
# PATH=/usr/bin:/bin, an empty HOME and the git switches below in its
# environment. The steps above ran the pull request's code, which could
# rewrite the checkout's files on disk (the check, its reader, the
# manifest, a Cargo.toml), change PATH and the environment, or write
# dotfiles in HOME (a ~/.gitconfig hooks path, a ~/.curlrc) and git
# hooks in .git/hooks; base_red_excuse.py trusts this verdict for a
# pull request whose diff leaves the check alone. So no global or
# system git config is read, git runs no hook and no fsmonitor, and
# the base is the merge commit's first parent as its object records
# it (no graft). BASH_ENV is empty here, so the checkout's
# scripts/ci/api_call_log/env.sh is not sourced either.
```

## `jobs.checks.steps[Daemon capabilities export is fresh]`

Above `- name: Daemon capabilities export is fresh`:

```text
# plans/cmux-next/daemon-capabilities.json against the lists in
# DaemonEndpoint.swift, without a build: check-daemon-capabilities.sh
# reads the JSON only inside an app build, so a Swift-only change to the
# lists (67b13e24e84d) broke every tagged build first.
```

## `jobs.checks.steps[App capability references are listed]`

Above `- name: App capability references are listed`:

```text
# Every capability the app references and the daemon source defines is
# in DaemonCapability.required/.optional, without a build: the app build
# runs this check first, so #21322 (four unlisted capabilities) broke
# every tagged build before any PR check saw it.
```

## `jobs.checks.steps[Capability texts never say update the app]`

Above `- name: Capability texts never say update the app`:

```text
# A capability error is a version skew: it names the matching CLI or one
# exact command, never "update the app" (plans/cmux-next/version-skew.md).
```

## `jobs.checks.steps[Pushed commits add no violations]`

Above `- name: Pushed commits add no violations`:

```text
# The pre-push gate again (scripts/cmux-next/prepush-gate.py, same pinned tools): on a push,
# each pushed commit against its parent, so a commit pushed with --no-verify that adds a
# violation is named; on a pull request, what the PR adds over its base (HEAD^1).
```

## `jobs.checks.steps[Fail on any red check]`

Above `- name: Fail on any red check`:

```text
# `outcome`, not `conclusion`: continue-on-error makes every conclusion success.
# STYLE_CHECKS are the structural, style, size and drift guards: while
# CMUX_NEXT_STYLE_GUARDS is `warn` (workflow env) a red one is a warning
# annotation and does not fail the job. A style check that never ran
# (an empty outcome) still fails: that is a broken workflow, not a finding.
```

## `jobs.checks.steps[Fail on any red check].env.BASH_ENV`

Above `BASH_ENV: ""`:

```text
# The check steps above continue on error, so this step decides the job: it must not source the
# checkout's scripts/ci/api_call_log/env.sh (the workflow's BASH_ENV), which their code can rewrite.
```

## `jobs.web-bundles`

Above `web-bundles:`:

```text
# Reports a same-tree cmux-tui that nothing will publish, in red, at once.
# It waits for nothing: path routing probed the tree (tree_state=failed), or
# an artifacts run that ended without publishing it dispatched same-tree mode
# with same_tree_state=failed. A later publication of the key still starts
# the tree jobs (the marker stays) and posts their statuses.
# A ready tree is reported green the same way, so the tip has a verdict
# after a red one: a job that only ever ran red stayed a base red while it
# was skipped (NOW: "unverified: job skipped since ...").
# Builds the cmux-next web bundles once per source key (web-bundle-key.py --source: every
# input file and the pinned bun) on Linux and caches them under that key. The Mac jobs
# restore them by the same key instead of running bun and Vite+ themselves; a push to
# feat-cmux-next fills the cache every pull request can read. A pull request builds them
# only for a routed tier that restores them (swift test, daemon tests, generated files).
# A DEV daily run (direct or same-tree) builds them for the commit it compiles, next to the
# DEV Release compile, which restores them instead of building them on its Mac when this
# job (or the push of the same sources) has stored them by the time it gets there.
```

## `jobs.web-bundles.environment`

Above `environment: ${{ github.ref == 'refs/heads/feat-cmux-next' && 'next-cache-writer' || '' }}`:

```text
# Only a feat-cmux-next run enters next-cache-writer (deployment branch
# feat-cmux-next only), and only its push publishes the bundles to NEXT's
# R2 bucket; a pull request holds no credential and saves only to its
# GitHub cache.
```

## `jobs.web-bundles.steps[uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2].with.ref`

Above `ref: ${{ inputs.same_tree_sha || '' }}`:

```text
# Same-tree mode compiles the commit the tree was probed for (cmux-scheme-compile).
```

## `jobs.web-bundles.steps[Drop stale submodule checkouts (self-hosted reused workspace)]`

Above `- name: Drop stale submodule checkouts (self-hosted reused workspace)`:

```text
# runs-on can resolve to vars.LINUX_RUNNER, which may name a self-hosted
# host that reuses its workspace; drop the submodule checkouts a previous
# job left there (a no-op on Blacksmith, which starts with none).
```

## `jobs.web-bundles.steps[Give this job its own bun]`

Above `- name: Give this job its own bun`:

```text
# The minis share ~/.bun with workflows that install another bun; this
# job runs on its own copy of the pinned one (private-bun.sh).
```

## `jobs.web-bundles.steps[Setup Node]`

Above `- name: Setup Node`:

```text
# The webviews app's `vp build` must run on node (build-web-bundles.sh).
```

## `jobs.web-bundles.steps[Cache the webviews Bun package cache]`

Above `- name: Cache the webviews Bun package cache`:

```text
# A miss spends most of its time in `bun install` with an empty package cache (about
# 60 of 104 s, run 40360791277). ci-web.yml's webviews jobs keep the same cache.
```

## `jobs.web-bundles.steps[Hand the web bundles to this run's Mac jobs]`

Above `- name: Hand the web bundles to this run's Mac jobs`:

```text
# The minis cannot read this cache: on Blacksmith it is Blacksmith's own
# cache, which a self-hosted Mac never sees (2026-10-26: swift test rebuilt
# the bundles on 14 of 25 sampled jobs, generated files on 12 of 44, 40 s
# of Mac time each). So a run that does not publish them to R2 (every
# event but a feat-cmux-next push) also hands them to its own Mac jobs as
# an artifact named after the source key; a Mac job whose sources give
# the same key installs it instead of building.
```

## `jobs.web-bundles.steps[Publish the web bundles to R2 (feat-cmux-next push)]`

Above `- name: Publish the web bundles to R2 (feat-cmux-next push)`:

```text
# The Mac jobs read the bundles from R2's CDN first: the minis download
# them from there much faster than from the GitHub cache, and every
# pull request whose web sources match feat-cmux-next's hits. The `any`
# namespace is shared by every OS (the bundles are platform-independent).
# A key that is already stored is not uploaded again. A DEV daily run does not publish:
# its DEV Release compile reads this run's GitHub cache entry when R2 has no copy.
```

## `jobs.same-tree-cmux-tui.if`

Above `if: ${{ !cancelled() && github.event_name != 'pull_request' && inputs.same_tree_origin != 'pull_request' && (((needs.path_route.outputs.tree_state == 'failed...`:

```text
# A superseded push reports nothing: its newer head is tested. Pull
# requests with a cold own tree are named in path_route's summary and
# skipped here; no synthetic cmux-tui-pin ref is created for them.
```

## `jobs.swift-canary-fleet`

Above `swift-canary-fleet:`:

```text
# The build fleet's compile verdict for the Swift canary. Opt-in: with the
# CI_COMPILE_CHECK_GATEWAY variable set (a tailnet gateway runner label), a
# same-repository run hands `cmux-ci compile-check --app` the commit; the
# fleet compiles and links the app executable, which covers every
# production target the app links (the canary's targets are production
# targets only), and answers. The two production targets the app does not
# link go straight to the Mac canary. A pass lets the
# canary below report it from a small Linux runner instead of taking a Mac.
# A red, an unavailable fleet or a timeout runs the Mac canary as before,
# which prints the errors: this job never fails a run itself.
```

## `jobs.swift-canary-fleet.if`

Above `if: ${{ !cancelled() && github.repository_owner == 'manaflow-ai' && vars.CI_COMPILE_CHECK_GATEWAY != '' && needs.path_route.outputs.swift_canary == 'true' &&...`:

```text
# With macos-placement's gateway judgement in this attempt (gateway_attempt) it runs only on an
# idle gateway runner (gateway_runner); with none idle the Mac canary takes the cascade instead.
```

## `jobs.swift-canary-fleet.steps[Compile-check CmuxNext on the build fleet]`

Above `- name: Compile-check CmuxNext on the build fleet`:

```text
# The gateway checks nothing out: the fleet fetches the commit the Mac
# canary would build (github.sha: a pull request's merge commit, so a
# head that breaks against the current base is still caught). A commit
# the fleet cannot fetch is "no verdict", and the Mac canary runs.
```

## `jobs.app-compile-placement`

Above `app-compile-placement:`:

```text
# The PR app compile's gateway runner, judged at once (Leo, 2026-11-08: the Linux checks start at once
# and only the Mac jobs wait). app-compile-fleet's runner only hands the head to the build fleet, so it
# does not wait for the PR quiet period; macos-placement, which places the Mac jobs, does, and reads the
# runners again then. A side-light runner idle now takes it (side_lane_placement.app_compile_gateway(),
# gateway_route()'s rule); with none, or on a re-run (attempt 2 and later: as macos-placement's
# rerun_main(), no gateway), app-compile-fleet skips and the Mac Release compile cascades. Fails open:
# a failed read or a trusted base that predates the mode writes nothing, which is "no gateway".
```

## `jobs.app-compile-placement.timeout-minutes`

Above `timeout-minutes: 6`:

```text
# Checkout (1m), two bounded token mints (2m), the read (2m), plus runner setup.
```

## `jobs.app-compile-placement.steps[Check out the trusted placement]`

Above `- name: Check out the trusted placement`:

```text
# The placement code from the base branch, as macos-placement's.
```

## `jobs.app-compile-fleet`

Above `app-compile-fleet:`:

```text
# A same-repository pull request's app compile, on the build fleet instead
# of the Mac Release queue (2026-10-21: 76 of ~350 queued Mac jobs were
# Release compiles). It compiles and links the app at the PR's head, the
# commit the landing gate (require-cmux-guards) asks about, in about a
# minute. A fleet compile error fails this job: the PR's own red. No verdict
# (no client, the controller unreachable or timed out: any cmux-ci exit but
# 0 and 1, 69 included) fails this job too, because nothing compiled the
# head: it went green on exit 69 with no compile at all (PR #26741's head
# 292b43ef, 2026-10-28, whose change runs no Mac Release compile). The
# verdict output stays unavailable, so release-compile still runs on a Mac
# where path_route's mac_release sends it. A full-ci PR, a fork, and every
# push and dispatch keep the Mac Release compile; the base push compiles
# Release after the merge, and push-attribution names the PR on a red.
```

## `jobs.app-compile-fleet.if`

Above `if: ${{ !cancelled() && github.event_name == 'pull_request' && github.repository_owner == 'manaflow-ai' && vars.CI_COMPILE_CHECK_GATEWAY != '' && needs.path_...`:

```text
# It takes the gateway, or a wider class of it, only while app-compile-placement saw a runner idle
# (gateway_runner). With none idle it does not run: release-compile then runs, and
# macos-placement puts it in the cascade (CASCADE_RUNS), so it takes a free Blacksmith
# slot rather than the queue PR #24155's compile sat in three times on 2026-10-26.
# It does not wait for the PR quiet period: its runner only hands the head to the build fleet's
# Linux compile, and the run's group cancels it on a newer push, as does its own group below.
```

## `jobs.app-compile-fleet.steps[Compile-check the app at the pull request's head on the build fleet]`

Above `- name: Compile-check the app at the pull request's head on the build fleet`:

```text
# The gateway checks nothing out: the fleet fetches the commit itself.
```

## `jobs.swift-canary`

Above `swift-canary:`:

```text
# Small package-only Swift edits get a mini-first type-check/build canary.
# This uses the same placement and linked SwiftPM scratch as the other Mac
# jobs, so a warm mini can answer in roughly 1-2 minutes. It deliberately
# excludes the app host, package manifest, resources and toolchain inputs.
# When swift-canary-fleet passed, the job keeps its name and conclusion but
# runs on a 2 vCPU Linux runner and only reports that verdict.
```

## `jobs.swift-canary.if`

Above `if: ${{ !cancelled() && needs.path_route.outputs.swift_canary == 'true' && needs.push-head-preflight.outputs.current == 'true' && (github.event_name != 'pull...`:

```text
# Same-repository PRs and dispatches run it; a fork PR only with full-ci.
# Base pushes remain the Release backstop.
```

## `jobs.swift-canary.concurrency.cancel-in-progress`

Above `cancel-in-progress: ${{ github.event_name == 'pull_request' }}`:

```text
# A newer PR push or manual rerun supersedes an older canary. This keeps
# the queue focused on the current head instead of replaying stale
# typechecks.
```

## `jobs.swift-canary.steps[Discard the workspace repository after a failed checkout]`

Above `- name: Discard the workspace repository after a failed checkout`:

```text
# As in swift test: a partial clone left in this reused workspace fetches
# a missing blob mid-step, unretried. Retry once from a fresh repository.
```

## `jobs.swift-canary.steps[Keep Swift package builds on this owned Mac]`

Above `- name: Keep Swift package builds on this owned Mac`:

```text
# Checkout removes .build. Link the owned Mac's kept build after Xcode
# selection so its fingerprint uses the compiler that runs this job.
```

## `jobs.fast-tier-rerun-placement`

Above `fast-tier-rerun-placement:`:

```text
# A person's re-run of the fast tier, placed again (side_lane_placement.rerun_fleet()). Re-running
# failed jobs carries attempt 1's macos-placement and its outputs, so the tier took vars.MACOS_RUNNER_26
# and fast-tier-fleet skipped the stale gateway reading: #38130's attempt 2 ran out its 20 minutes on the
# same cold Blacksmith build as attempt 1. This job is skipped on attempt 1 and on the rescue's re-run
# (macos-placement places those), so a person's re-run evaluates it again. It reads the runners now and,
# while the fast tier runs again in this attempt and a gateway runner is idle for its client, lists the
# tier for fast-tier-fleet with this attempt's gateway reading; otherwise the tier keeps its route. A
# later re-run carries this job's reading too, which fast-tier-fleet then skips as an earlier attempt's.
# With owned pools off (vars.CI_PR_POOL_OWNED), as for macos-placement, it places nothing.
```

## `jobs.fast-tier-rerun-placement.timeout-minutes`

Above `timeout-minutes: 6`:

```text
# Checkout (1m), two bounded token mints (2m), the reads (2m), plus runner setup.
```

## `jobs.fast-tier-rerun-placement.permissions.actions`

Above `actions: read`:

```text
# This attempt's jobs: whether the fast tier runs again.
```

## `jobs.fast-tier-rerun-placement.steps[Check out the trusted placement]`

Above `- name: Check out the trusted placement`:

```text
# The placement code from the base branch, as macos-placement's.
```

## `jobs.fast-tier-rerun-placement.steps[Place the fast tier's re-run]`

Above `- name: Place the fast tier's re-run`:

```text
# Fails open: an unread status, a failed read or a base script that predates the re-run placement
# writes nothing, and the tier keeps its route.
```

## `jobs.fast-tier-fleet`

Above `fast-tier-fleet:`:

```text
# The fast tier as a thin build-fleet client, for when every owned and
# Blacksmith macOS label it could take is full or dead, or only a Blacksmith
# macOS label (a cold build) took it: macos-placement then
# lists it in fleet_jobs (next_macos_cascade.place(), FLEET_CLIENT_JOBS) and
# this job hands the swift entries of scripts/cmux-next/fast-tier.json to the
# fleet (`cmux-ci run` of package-test-lane.sh's suite mode, one step per
# package) instead of waiting for a Mac. The gateway runner runs nothing of
# the commit: no checkout, no action, no token, no secret, only the client
# (the checks-workflow guard GatewayRunsOnlyTheFleetClient).
# It tests the exact commit fast-tier builds (github.sha: a pull request's merge commit) and checks
# that every fleet step it reads tested that commit: no verdict, or a step at
# another commit, fails it and is never a pass. fast-tier keeps the check
# name and reports this job's verdict from a 2 vCPU Linux runner.
# A step still queued when the client stops waiting (exit 75; the step keeps its place, as the
# controller never cancels one for waiting) gives the verdict `queued`: this job passes with a
# warning and fast-tier runs the Swift suites itself on Blacksmith macOS, the cascade's next route,
# so the PR gets a verdict in the same attempt (cmux#38346: both steps queued past 600 s, then
# passed 40 minutes later, and the PR went red on the wait).
```

## `jobs.fast-tier-fleet.runs-on`

Above `runs-on: ${{ needs.fast-tier-rerun-placement.outputs.gateway_attempt == format('{0}', github.run_attempt) && needs.fast-tier-rerun-placement.outputs.gateway_...`:

```text
# This attempt's re-run reading first (fast-tier-rerun-placement), else macos-placement's.
```

## `jobs.fast-tier-fleet.timeout-minutes`

Above `timeout-minutes: 50`:

```text
# Longer than the client's queue (1200 s) plus run (1500 s) timeouts and the
# report, so the client, not the job timeout, ends a slow step.
```

## `jobs.fast-tier-fleet.steps[Run the fast tier's Swift suites on the build fleet].env.REF`

Above `REF: ${{ github.sha }}`:

```text
# github.sha: a pull request's merge commit, the tree fast-tier itself checks out (as
# swift-canary-fleet), so a head that breaks against the current base is still caught.
```

## `jobs.fast-tier-fleet.steps[Run the fast tier's Swift suites on the build fleet].env.HOME_RENDER_SUITES`

Above `HOME_RENDER_SUITES: MotionTokenTests,IntentMappingTests`:

```text
# fast-tier.json's swift entries, by package (FastTierFleetClient keeps them equal).
```

## `jobs.fast-tier-handback-placement`

Above `fast-tier-handback-placement:`:

```text
# The fast tier's queued hand-back, placed again (side_lane_placement.handback()). When fast-tier-fleet hands
# the tier back (verdict `queued`: a fleet step still queued after the client's 20-minute wait),
# macos-placement's reading is from the start of the run. This job reads the runners and Blacksmith's health
# now: the tier takes its own idle label, an idle owned side runner (a warm build), Blacksmith 6 vCPU while
# it is not full, under a declared outage, dead or stalled, and otherwise waits on the owned route. #38627's
# review: an unconditional Blacksmith 6 vCPU queued on an excluded label with no verdict.
# Fails open: an unread placement or a base script that predates it writes nothing, and the tier takes
# Blacksmith 6 vCPU as #38627 sends it.
```

## `jobs.fast-tier-handback-placement.timeout-minutes`

Above `timeout-minutes: 8`:

```text
# Checkout (1m), three bounded token mints (3m), the reads (2m), plus runner setup.
```

## `jobs.fast-tier-handback-placement.steps[Check out the trusted placement]`

Above `- name: Check out the trusted placement`:

```text
# The placement code from the base branch, as macos-placement's.
```

## `jobs.fast-tier-handback-placement.steps[Mint the glaeda read token]`

Above `- name: Mint the glaeda read token`:

```text
# Blacksmith's health (the pool snapshot's declared outages and dead labels), as macos-placement reads it.
```

## `jobs.fast-tier-handback-placement.steps[Place the fast tier's hand-back].env.SIDE_LABEL`

Above `SIDE_LABEL: ${{ github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository && 'blacksmith-6vcpu-macos-26' || v...`:

```text
# The owned side label itself: CMUX_NEXT_SIDE_ROUTE names Blacksmith on a person's re-run. A fork's
# pull request never gets it (it never reaches this job either: its fleet client does not run).
```

## `jobs.fast-tier`

Above `fast-tier:`:

```text
# The PR fast tier (hq#1915, cx-29ch2): every registered deterministic suite
# (scripts/cmux-next/fast-tier.json) on every feat-cmux-next PR and push,
# whatever paths changed, without the gui token. Target: under 5 minutes
# with the build. A fail-then-pass entry is FLAKY and fails the job: it is
# never retried silently (fast-tier.py's flake policy). The registry is split
# by kind: this Mac job builds and runs the Swift entries, and
# fast-tier-cargo runs the cargo and script entries beside it, so the Mac no
# longer builds cmux-tui (297-422 s) after CmuxNext.
# A pull request whose change no fast-tier Swift entry builds or reads starts
# no Mac fast tier: its result is the base's. That is every PR the router
# sends to no Mac tier (only web or CI files), and one whose Mac tiers are
# only the daemon or scheme compile (cmux-tui Rust, the app host), which the
# package build cannot see (cmux_next_route.py fast_tier). The cargo half
# still runs, and a route with no answer (a failed path_route) runs it as before.
```

## `jobs.fast-tier.environment`

Above `environment: ${{ github.ref == 'refs/heads/main' && 'ci-cache-writer' || '' }}`:

```text
# The cache saves name the R2 write credentials, which live in the ci-cache-writer
# environment (main only; tests/test_ci_pull_request_caches_are_read_only.py). This job
# never runs on main, so it still enters no environment: the line changes nothing at run time.
```

## `jobs.fast-tier.runs-on`

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name !...`:

```text
# vars.CI_FAST_LANE_RUNNER is the fast tier's own reserved runner label
# (glaeda-fast-<class>-xcode-26.6). The tier takes it only through the
# placement's fast_runner, set while one of its runners is idle, and only on
# attempt 1: a re-run reuses attempt 1's placement, whose idle reading is stale.
# With no fast runner idle, fast_runner names an idle light side runner instead
# (glaeda-side-light-xcode-26.6, side_lane_placement.light_fast_route(); Leo, 2026-11-08:
# "the light minis are largely idling"), never while a nightly job waits on the light minis.
# Otherwise the tier takes the current cascade allocation. With every
# alternative excluded, deferred_runner preserves the base owned queue;
# it never bypasses Blacksmith outage/nightly exclusions or skips tests.
# fast-tier-fleet replaces that deferred case when placement lists the tier for the fleet.
# When fast-tier-fleet ran (macos-placement found every macOS label it could take full or
# dead, or only a Blacksmith macOS label took the tier), this job keeps its check name and exit code but runs on fleet Linux (vars.LINUX_RUNNER
# when it names our own runner, as portable-placement does), else a 2 vCPU Blacksmith Linux runner, and
# only reports that job's verdict: every other step is off (CMUX_FAST_TIER_FLEET, or it reads a
# step that is). fast_runner is empty then: placement lists only a tier no idle runner took.
# When the client hands the tier back (verdict `queued`: a fleet step still queued past its wait),
# the tier runs in full, with 35 minutes, where fast-tier-handback-placement's fresh reading sends it
# (an idle owned Mac, else Blacksmith 6 vCPU unless excluded, else the owned route), else on
# Blacksmith 6 vCPU.
```

## `jobs.fast-tier.permissions.actions`

Above `actions: read`:

```text
# The reuse lookup lists artifacts.
```

## `jobs.fast-tier.timeout-minutes`

Above `timeout-minutes: ${{ contains(fromJSON('["success","failure","cancelled"]'), needs.fast-tier-fleet.result) && needs.fast-tier-fleet.outputs.verdict != 'queue...`:

```text
# A cold package build can exceed the 5-minute target; the job still runs
# the entries so a cold mini reports, and the summary shows the time.
# The fleet's `queued` hand-back always runs cold on Blacksmith 6 vCPU macOS, whose fast-tier p90 was
# 19.8 minutes (#38181's data), so it gets 35: a slow cold build still gives the verdict.
```

## `jobs.fast-tier.env.CMUX_FAST_TIER_FLEET`

Above `CMUX_FAST_TIER_FLEET: ${{ contains(fromJSON('["success","failure","cancelled"]'), needs.fast-tier-fleet.result) && needs.fast-tier-fleet.outputs.verdict != '...`:

```text
# 'report' when fast-tier-fleet ran with a verdict (or none) to report: the steps below then only
# report it. A `queued` hand-back runs them in full.
```

## `jobs.fast-tier.steps[Report the build fleet's fast tier verdict]`

Above `- name: Report the build fleet's fast tier verdict`:

```text
# The build fleet's verdict, under this job's name: fail and no verdict both fail it.
```

## `jobs.fast-tier.steps[Give this job its own acpmux home]`

Above `- name: Give this job its own acpmux home`:

```text
# This job's tests can start acpmux daemons: they get a home of the job's
# own, never the runner's ~/.acpmux, the mini's own daemon
# (tests/test_ci_acpmux_job_home.py).
```

## `jobs.fast-tier.steps[Checkout].with.clean`

Above `clean: false`:

```text
# A reused mini keeps ignored SwiftPM/Cargo/Zig outputs warm. The
# default clean=true walks and deletes those trees before checkout;
# clean untracked source explicitly below while preserving caches.
```

## `jobs.fast-tier.steps[Discard the workspace repository after a failed checkout]`

Above `- name: Discard the workspace repository after a failed checkout`:

```text
# As in swift test: a partial clone left in this reused workspace fetches
# a missing blob mid-step, unretried. Retry once from a fresh repository.
```

## `jobs.fast-tier.steps[Drop stale submodule checkouts (self-hosted reused workspace)]`

Above `- name: Drop stale submodule checkouts (self-hosted reused workspace)`:

```text
# The Swift entries need no submodule (cmux-tui and its ghostty-next build
# moved to fast-tier-cargo), so drop whatever a previous job left.
```

## `jobs.fast-tier.steps[Fingerprint this job's inputs]`

Above `- name: Fingerprint this job's inputs`:

```text
# With vars.CI_NEXT_JOB_REUSE, a pass on the same inputs stands for this run: the
# steps below skip and the summary names the run that passed. The key
# (scripts/ci/job_input_fingerprint.py) is the commit's full tree hash, this
# workflow file's blob hash and the toolchain below; a missing toolchain value
# gives no key. Not on a fork pull request, which could record a pass of its
# own under any key.
```

## `jobs.fast-tier.steps[Keep Swift package builds on this owned Mac]`

Above `- name: Keep Swift package builds on this owned Mac`:

```text
# Checkout removes .build. On an owned Mac the tier builds in one of the
# mini's shared roots (scripts/ci/owned_spm_scratch.py lease): a mirror of
# this checkout at a path every runner slot shares, so the build the last
# fast tier on any slot left is warm here. Its output `root` is where the
# tier runs; with no root free it links this workspace's own kept build.
# After Xcode selection, so its fingerprint uses the compiler of this job.
```

## `jobs.fast-tier.steps[Compute fast-tier cache keys]`

Above `- name: Compute fast-tier cache keys`:

```text
# Owned minis keep their builds on their own SSD (above). Blacksmith overflow
# restores the newest seed cmux-next-fast-tier-seed.yml saved from a
# feat-cmux-next push to cmux-ci-cache-next, through its public URL: no
# credential, and a pull request never writes. The swift directory comes by
# prefix; the home directory by that seed's exact commit, so both come from
# one seed and match the input-time manifest in the swift directory.
```

## `jobs.fast-tier.steps[Replay the seed's input times]`

Above `- name: Replay the seed's input times`:

```text
# A fresh checkout stamps every source with the checkout time, which SwiftPM
# reads as "changed". Give each file whose content matches the
# seed's the time the seed built it from, so only what changed rebuilds.
```

## `jobs.fast-tier.steps[Stop this job's acpmux daemons and remove its home]`

Above `- name: Stop this job's acpmux daemons and remove its home`:

```text
# Also after a failure or a cancel: end the daemon of this job's home and
# its agents (shutdown never starts one), then delete the home.
```

## `jobs.fast-tier.steps[Record this pass for the same inputs]`

Above `- name: Record this pass for the same inputs`:

```text
# A pass records itself for the next run on the same inputs: an artifact named after
# the key, which every pull request and the base can list (scripts/ci/job_reuse.py
# takes only passes of this repository's own runs). Never from a fork pull request.
# An uncached (no_reuse) run records too.
```

## `jobs.fast-tier-cargo`

Above `fast-tier-cargo:`:

```text
# The fast tier's cargo and portable script entries: cmux-tui-core, the
# layout reducer and performance completeness, run beside the Mac job, so
# the Mac runs only Swift. Same gating, flake policy and quarantine list as
# fast-tier; its own check name, receipt and concurrency group.
```

## `jobs.fast-tier-cargo.runs-on`

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_na...`:

```text
# As cmux-tui.yml's Linux test job: a fork keeps the public or 4-vCPU lane.
```

## `jobs.fast-tier-cargo.permissions.actions`

Above `actions: read`:

```text
# The reuse lookup lists artifacts.
```

## `jobs.fast-tier-cargo.env`

Above `env:`:

```text
# cmux-tui-core's ghostty-vt-sys builds libghostty-vt from the ghostty-next gitlink with zig,
# as in cmux-tui.yml (an empty CMUX_GHOSTTY_SRC overrides a runner-level one).
```

## `jobs.fast-tier-cargo.steps[Install Linux build dependencies]`

Above `- name: Install Linux build dependencies`:

```text
# clang (bindgen's libclang), Zig and Rust come before the reuse key, which
# names their versions.
```

## `jobs.fast-tier-cargo.steps[Fingerprint this job's inputs]`

Above `- name: Fingerprint this job's inputs`:

```text
# With vars.CI_NEXT_JOB_REUSE, a pass on the same inputs stands for this run: the
# steps below skip and the summary names the run that passed. The key
# (scripts/ci/job_input_fingerprint.py) is the commit's full tree hash, this
# workflow file's blob hash and the toolchain below; a missing toolchain value
# gives no key. Not on a fork pull request, which could record a pass of its
# own under any key.
```

## `jobs.fast-tier-cargo.steps[Verify planner promotion evidence]`

Above `- name: Verify planner promotion evidence`:

```text
# The mode switch is deliberately insufficient on its own.  Promotion
# needs a protected repository variable carrying an HQ receipt for this
# exact planner policy after a complete 24-hour mirror window with a
# measured zero false-skip rate.  A pull request cannot edit vars, so
# its checkout cannot forge promotion evidence. Missing, stale, or
# malformed evidence leaves this step false and the job runs in full.
```

## `jobs.fast-tier-cargo.steps[Look for a trusted planner pass]`

Above `- name: Look for a trusted planner pass`:

```text
# Enforcement is promoted only after the HQ mirror collector has a complete
# 24-hour window with zero false skips. Its producer is a trusted push on
# feat-cmux-next; pull-request artifacts are evidence, never reusable passes.
# CI_REBUILD_MIRROR=0 keeps the old whole-tree mode available as a kill switch.
```

## `jobs.fast-tier-cargo.steps[Cache cargo build]`

Above `- name: Cache cargo build`:

```text
# As cmux-tui.yml: cargo's registry and dependency builds under cmux-tui/target.
# Only a feat-cmux-next push saves this build cache; a pull request reads the base
# branch's. (The pass record at the end of the job is a separate artifact.)
```

## `jobs.fast-tier-cargo.steps[Fetch the ghostty-next Zig packages (cached, deadlined, retried)]`

Above `- name: Fetch the ghostty-next Zig packages (cached, deadlined, retried)`:

```text
# ghostty-vt-sys's build.rs runs zig, which downloads the packages itself, once and
# unretried: a mid-stream read error failed the job (pkg/highway ReadFailed). Fetch
# them first, each attempt under a deadline and retried.
```

## `jobs.fast-tier-cargo.steps[Record rebuild mirror outcome]`

Above `- name: Record rebuild mirror outcome`:

```text
# Observe the candidate and the full run together. Before promotion no
# candidate skips; after promotion only a trusted push pass can skip.
```

## `jobs.fast-tier-cargo.steps[Record this pass for the same inputs]`

Above `- name: Record this pass for the same inputs`:

```text
# A pass records itself for the next run on the same inputs: an artifact named after
# the key, which every pull request and the base can list (scripts/ci/job_reuse.py
# takes only passes of this repository's own runs). Never from a fork pull request.
# An uncached (no_reuse) run records too.
```

## `jobs.swift-test`

Above `swift-test:`:

```text
# The CmuxNext test targets the change reaches: path_route's swift_filter
# (an empty filter runs every target, as on a full-ci PR, a push or a dispatch). No
# cmux-tui wait: the live-daemon suites skip unless the same-tree binary is
# already published, and daemon-test runs them against it.
# PR package/generated jobs read only this attempt's cascade allocations.
# With missing or carried outputs, stay on the owned side pool: a repository's
# generic MACOS_RUNNER_26 may name paid capacity with no bounded allocation.
# The bot's attempt 4 leaves the side pool for the small overflow, like every
# other cmux-next fleet fallback (run_attempt <= 3, #22565).
# Keep the existing owned-pool switch: when disabled, retain its small overflow.
```

## `jobs.swift-test.if`

Above `if: ${{ !(github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next') && (!cancelled() && (needs.web-bundles.result == 'success' || needs.web-b...`:

```text
# A pull request (same-repository or fork) runs it only with full-ci. On
# every PR push it gave no signal: of 78 PR check runs (2026-11-02 to 11-05)
# 37 were cancelled (17 by the PR merging first, 10 by a newer push, 10 by a
# re-run at the same head), 37 skipped, 4 failed and none passed. A
# feat-cmux-next push skips it too (push CI is the app build only, see the
# jobs comment), so a dispatch is where the Swift suites run: main's
# cmux-next-tip-swift-suite-dispatch.yml runs them on the tip when Swift
# changed (the base verdict), and gh workflow run runs them on any ref.
```

## `jobs.swift-test.concurrency`

Above `concurrency:`:

```text
# A push's Mac job waits for the same job of the running push run and is
# never cancelled once it runs; a newer push replaces only the waiting one
# (see the workflow concurrency comment).
```

## `jobs.swift-test.concurrency.cancel-in-progress`

Above `cancel-in-progress: ${{ github.event_name == 'pull_request' }}`:

```text
# Report-only PR attempts are superseded by a newer push or rerun.
```

## `jobs.swift-test.environment`

Above `environment: ${{ github.event_name != 'pull_request' && 'ci-routing-agent' || '' }}`:

```text
# Same-repository PR tests use the generic picker route (or its Blacksmith overflow), so display labels never gate them.
```

## `jobs.swift-test.permissions.actions`

Above `actions: read`:

```text
# The reuse lookup lists artifacts.
```

## `jobs.swift-test.timeout-minutes`

Above `timeout-minutes: 135`:

```text
# A cold build of the package graph (CmuxNext plus its Shared and iOS test
# dependencies) and the selected suites. Admission (up to 20 min), cache
# restore (~7 min) and the build (~6 min) used most of 60 before a full
# broad pass (~860 s on a slow mini) ran, so 90; the main-thread-heavy
# suites' serial step (up to 60 min, out of the broad pass since #26809)
# makes it 135.
```

## `jobs.swift-test.outputs.generated_files`

Above `generated_files: ${{ steps.reuse.outputs.hit == 'true' && 'fresh' || steps.generated-files-verdict.outputs.verdict }}`:

```text
# The folded generated files verdict (generated-verdict reads it): fresh, stale, catalog or empty. A
# reused pass of a folded run was recorded only with the generated files fresh.
```

## `jobs.swift-test.env.CMUX_NEXT_RUNNER`

Above `CMUX_NEXT_RUNNER: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || github.event_name == 'pull_request' && github.event.pull_request.head.repo.fu...`:

```text
# This job's label (its runs-on): a glaeda-* label means a mini.
```

## `jobs.swift-test.env.CMUX_CI_REQUIRED_MACOS_SDK_MAJOR`

Above `CMUX_CI_REQUIRED_MACOS_SDK_MAJOR: "26"`:

```text
# The package deploys to macOS 26, so the test runner needs a macOS 26
# host and SDK.
```

## `jobs.swift-test.env.CMUX_NEXT_FOLD_GENERATED`

Above `CMUX_NEXT_FOLD_GENERATED: ${{ needs.path_route.outputs.generated_host == 'swift-test' }}`:

```text
# The generated files are checked here, on this job's package build, when path routing
# picks this job (generated_host): no generated-files job builds the same package and tests.
```

## `jobs.swift-test.steps[Give this job its own acpmux home]`

Above `- name: Give this job its own acpmux home`:

```text
# This job's tests can start acpmux daemons: they get a home of the job's
# own, never the runner's ~/.acpmux, the mini's own daemon
# (tests/test_ci_acpmux_job_home.py).
```

## `jobs.swift-test.steps[Checkout].with.submodules`

Above `submodules: false`:

```text
# The package graph reads no submodule; GhosttyNextKit comes from
# SwiftPM (Packages/Shared/CmuxGhosttyKit).
```

## `jobs.swift-test.steps[Discard the workspace repository after a failed checkout]`

Above `- name: Discard the workspace repository after a failed checkout`:

```text
# A blob-filtered checkout by another job leaves a partial clone in this
# reused workspace, and a missing blob is fetched from GitHub mid-step,
# unretried. Retry once from a fresh repository; a second failure fails.
```

## `jobs.swift-test.steps[Retry checkout after transient network failure].with.submodules`

Above `submodules: false`:

```text
# The package graph reads no submodule; GhosttyNextKit comes from
# SwiftPM (Packages/Shared/CmuxGhosttyKit).
```

## `jobs.swift-test.steps[Drop stale submodule checkouts (self-hosted reused workspace)]`

Above `- name: Drop stale submodule checkouts (self-hosted reused workspace)`:

```text
# A mini reuses its workspace: drop the submodule checkouts a previous
# job left (scripts/ci/reset-stale-submodules.sh), as on a fresh checkout.
```

## `jobs.swift-test.steps[Require the GUI session on a mini]`

Above `- name: Require the GUI session on a mini`:

```text
# The GUI-tagged suites (.requiresGUISession, .requiresPasteboard; for
# example SidebarLiveReorderTests) skip when the host has no display or
# pasteboard. Every glaeda mini has both: in 153 swift-test jobs
# (2026-10-04/05) all 11 minis behind the side label ran
# SidebarLiveReorderTests and no GUI or pasteboard test skipped. On a
# mini, CMUX_TEST_REQUIRE_GUI=1 turns a lost display into a failure
# instead of a silent skip. Blacksmith and hosted labels
# keep the skip: nothing has shown that they have a display session.
# Not on a pull request: display tests gate no PR (Leo, 2026-10-31: "i dont like doing display
# tests anymore"), so a PR's display suites skip, and a lost display never fails a PR job. Pushes
# and nightlies keep the requirement as advisory coverage.
```

## `jobs.swift-test.steps[Fingerprint this job's inputs]`

Above `- name: Fingerprint this job's inputs`:

```text
# With vars.CI_NEXT_JOB_REUSE, a pass on the same inputs stands for this run: the
# steps below skip and the summary names the run that passed. The key
# (scripts/ci/job_input_fingerprint.py swift-test) is the commit's full tree hash, this
# workflow file, the toolchain and the env flags below; a missing value gives no key. A run that
# checks the generated files here (CMUX_NEXT_FOLD_GENERATED) also keys the base commit they are
# compared against (generated_base), and records a pass only when they are fresh.
# Any change to the tree, a base move included, changes the key. Not on a fork pull
# request, which could record a pass of its own under any key.
```

## `jobs.swift-test.steps[Mint the cmux-bot artifact read token]`

Above `- name: Mint the cmux-bot artifact read token`:

```text
# A feat-cmux-next push or dispatch lists the pass artifacts with a cmux-bot token,
# off the repository token's hourly budget; a pull request run, or a failed mint,
# keeps the workflow token (scripts/ci/job_reuse.py).
```

## `jobs.swift-test.steps[Keep Swift package builds on this owned Mac]`

Above `- name: Keep Swift package builds on this owned Mac`:

```text
# Checkout removes .build. Link the owned Mac's kept build after Xcode
# selection so its fingerprint uses the compiler that runs this job.
```

## `jobs.swift-test.steps[Compute the fast-tier seed keys]`

Above `- name: Compute the fast-tier seed keys`:

```text
# Off the owned Macs, start from the build a feat-cmux-next push seeded for the fast tier
# (cmux-next-fast-tier-seed.yml): the same `swift build --build-tests` of this package at a
# recent base, at the same workspace path. With the seed's input times replayed, only what
# this change touched compiles, so a daemon-only change compiles no Swift and goes straight
# to the tests. The seed's resource bundles are dropped first (owned_spm_scratch.py
# drop-bundles, as a kept build's are). Any miss builds as before.
```

## `jobs.swift-test.steps[Set up pinned cmux-tui Rust (sidebar layout reducer)]`

Above `- name: Set up pinned cmux-tui Rust (sidebar layout reducer)`:

```text
# The sidebar layout reducer's cargo tests run in fast-tier-cargo on Linux
# (fast-tier.json "sidebar layout reducer") on every feat-cmux-next pull
# request and push, so this Mac job runs them only on the events of its own
# that fast-tier-cargo does not take: a dispatch or a main push (2026-10-26).
```

## `jobs.swift-test.steps[Script tests (bundle-server-helper)]`

Above `- name: Script tests (bundle-server-helper)`:

```text
# macOS-only script behavior tests (PlistBuddy, plutil, lipo): the "Bundle
# server helper" phase writes the server helper and agent plists without
# the app's processed Info.plist, and release signing signs every
# libexec helper and restamps the plists from the final bundle id; the
# app personality check reads the bundle's Info.plist.
```

## `jobs.swift-test.steps[Setup Bun]`

Above `- name: Setup Bun`:

```text
# The package's resources include the web bundles (agent pane, pages,
# Activity) and the tests read them: build them from the
# sources (cx-vn5) with the bun webviews/package.json pins.
```

## `jobs.swift-test.steps[Give this job its own bun]`

Above `- name: Give this job its own bun`:

```text
# The minis share ~/.bun with workflows that install another bun; this
# job runs on its own copy of the pinned one (private-bun.sh).
```

## `jobs.swift-test.steps[Setup Node]`

Above `- name: Setup Node`:

```text
# The webviews app's `vp build` must run on node: on bun it emits
# different bytes (build-web-bundles.sh).
```

## `jobs.swift-test.steps[Source key of the web bundles]`

Above `- name: Source key of the web bundles`:

```text
# The Linux web-bundles job builds the bundles once per source key and caches them; a
# hit installs them here instead of building, and a miss builds them in the next step.
```

## `jobs.swift-test.steps[Restore the web bundles from R2]`

Above `- name: Restore the web bundles from R2`:

```text
# R2 first (feat-cmux-next's bundles, published by the web-bundles job of
# its pushes; no credential), then this run's GitHub cache entry.
```

## `jobs.swift-test.steps[Check generated action catalog, surfaces and inventory]`

Above `- name: Check generated action catalog, surfaces and inventory`:

```text
# The generated files checks (CMUX_NEXT_FOLD_GENERATED), on the package and tests built above
# and before the catalogs are compiled into the resource bundles, as the generated-files job
# runs them. generated-verdict gives their verdict (this job's generated_files output).
```

## `jobs.swift-test.steps[Find the main-thread-heavy suites]`

Above `- name: Find the main-thread-heavy suites`:

```text
# The suites of the selected targets that drive the main thread for long
# stretches (Core Animation frame commits, real WebKit downloads), read
# from the test sources: the changed-suites pass and the broad pass skip
# them and a step of their own runs them, each in a fresh process.
```

## `jobs.swift-test.steps[Run package tests (changed suites first, then selected targets)]`

Above `- name: Run package tests (changed suites first, then selected targets)`:

```text
# Samples and fails a run still going after 15 minutes, so a hang shows
# its stacks; each test step timeout stops it holding the runner regardless.
# Control tests use tight request deadlines and run in their own process so
# they do not compete with the other MainActor-isolated suites.
```

## `jobs.swift-test.steps[Run package tests (changed suites first, then selected targets)].env.CMUX_NEXT_TEST_HANG_SECONDS`

Above `CMUX_NEXT_TEST_HANG_SECONDS: "1500"`:

```text
# Whole-run limit per pass. The hang guard is the stall rule (no test
# finished in CMUX_NEXT_TEST_STUCK_SECONDS, default 300), so a real
# hang ends in ~5 min; this only caps a slow healthy pass (~860 s).
# Both passes share one deadline below the step's 40 minutes. On a
# 6-vCPU overflow Mac the shards run one at a time (width 1): the
# broad pass took 1,266-1,371 s over four runs and 1,725 s in run
# 41372093339, where the last shard (CmuxNextAppTests.Cloud, ~90 s
# alone) started with 33 s left and was cut at its 60 s floor.
```

## `jobs.swift-test.steps[Run package tests (changed suites first, then selected targets)].env.SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH`

Above `SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH: "1"`:

```text
# One Swift Testing test at a time inside each shard process; the
# shards themselves run side by side (swift-test-shards.py). A test's
# time limit counts from its start, and Swift Testing otherwise starts
# all ~5,900 at once (width 6 here before #26809). With 6 at once in
# each of 3 shards, suites that pass alone at the base went red only
# in shards: WorkspaceGroupPinLive, ClickedLinkFocus,
# BrowserEngineStateRestore, RapidWorkspaceCreate,
# WorkspaceHoverCardScroll, MarkdownTableWidthMemory (run
# 40896449485); at 1 at once all six passed (run 40906115871), and
# the pass took 9.5 min against 8.1.
```

## `jobs.swift-test.steps[Run package test shards the broad pass spilled]`

Above `- name: Run package test shards the broad pass spilled`:

```text
# The shards the broad pass had no time for. Each shard there started with the time left to
# the pass's deadline, so one slow shard cut the next ones short: in run 41665450504 shard 13
# took 867 s and shards 14 and 15 were killed at a 60 s limit, 0 of 447 finished tests red,
# and a cut-short run is never a base red. A shard with under its floor left (450 s, the p90
# of 28 measured shards; swift-test-shards.py SHARD_FLOOR_SECONDS) is spilled here and runs
# with a deadline of its own. It runs after a red broad pass too, so its verdict is not lost.
```

## `jobs.swift-test.steps[Run CloudBringBack cases in fresh processes]`

Above `- name: Run CloudBringBack cases in fresh processes`:

```text
# Cloud bring-back round trips launch two daemons and mutate shared
# AppKit/registry state. Run each case in a fresh process so a prior
# round trip cannot starve the next case's 60-second action deadline.
```

## `jobs.swift-test.steps[Run the commit-boundary audit in its own process]`

Above `- name: Run the commit-boundary audit in its own process`:

```text
# The commit-boundary audit reads every observer on the main run loop, so
# it runs in its own process: another suite's after-commit observer
# (a pending AfterFrameCommit, a view's observer not yet released) is
# that suite's state, not AppKit's or Core Animation's.
```

## `jobs.swift-test.steps[Run main-thread-heavy suites in their own process]`

Above `- name: Run main-thread-heavy suites in their own process`:

```text
# Suites that hold the test process's main thread for minutes when they
# share it (scripts/cmux-next/main-thread-heavy-suites.py says which),
# run in their own process, one test at a time. Each Core Animation
# commit lays out every window the process holds: in the shared pass
# SidebarHugeGroupTests' oneGroup10k (about 1 s alone) and
# SidebarLagTests held the main thread for 5 to 11+ minutes, and
# RemoteVideoPageTests' WebKit downloads held it in a kernel call
# (SandboxExtension::createHandle -> __mac_syscall) for 300+ s. Every
# main-actor test beside them stalled or failed on timing, and the stuck
# watchdog killed the run with hundreds of tests unfinished (#26809's
# runs 40660100939, 40677563234 and 40683540650). Each suite gets a fresh
# process: in one shared serial process the windows earlier gallery
# suites left open made SidebarScrollCostTests' 500-row scroll take 300+
# s and the stuck watchdog ended the step (run 40693598261). A hang or a
# red here is this step's red, and every suite still runs. Each suite's
# watchdog limits come from main-thread-heavy-suites.py --runs: 600 s for
# the run and 300 s with no test finished, or above the suite's own
# `.timeLimit` (ClassicUpgradeHugeSimulationTests: 15 min, so 1200 s and
# 1020 s; it took 412 s alone and one test was open 572 s in a shard).
```

## `jobs.swift-test.steps[Run control package tests and callback regressions]`

Above `- name: Run control package tests and callback regressions`:

```text
# Each isolated step below runs when its suites' target is selected and
# the build succeeded, even after a failed test step, so one red step
# does not hide the others.
# Some suites of this target hold the main thread on purpose (the
# watchdog's stall and CPU tests, slow action spans, ControlLaneTests'
# stalls, the work queue's floods); others check that a main-actor
# request answers within its own deadline. Run together, a 2 to 5 s
# hold made every request beside it answer `timeout`
# (ActionRunCreatedTests, ActionBatchTests and BrowserTabMirrorTests
# failed on every tip run, job 122086769190). The holders run after the
# rest, one test at a time; the rest stays parallel. The suites that
# check a production deadline itself (ActionRunCreatedTests' 2 s,
# TerminalStartDeadlineTests' terminal start) run in that serial pass
# too: the parallel pass still held the main actor past 2 s at its start
# on loaded minis (jobs 122242957690, 122236716988, 122240111475).
```

## `jobs.swift-test.steps[Run CLI parity tests]`

Above `- name: Run CLI parity tests`:

```text
# The CLI parity tests assert routing, not scheduler throughput. Concurrent
# app/catalog setup can occupy the main actor longer than their real request
# deadlines, so they run alone and one test at a time.
```

## `jobs.swift-test.steps[Run state-resource regressions]`

Above `- name: Run state-resource regressions`:

```text
# The state-resource event round trips against the real daemon need their
# own process: unrelated suites can delay callbacks beyond these tests'
# existing deadlines. Every test still runs.
```

## `jobs.swift-test.steps[Give the generated files verdict]`

Above `- name: Give the generated files verdict`:

```text
# The folded verdict, for generated-verdict: never this job's own result, so a stale file
# does not turn `cmux-next swift test` red, and a red `cmux-next swift test` does not hide a stale file.
```

## `jobs.swift-test.steps[Give the generated files verdict].env.CATALOG`

Above `CATALOG: ${{ steps.actions.outputs.catalog }}`:

```text
# failure when the action checks fail with fresh exports too (judge-action-exports.sh): not stale.
```

## `jobs.swift-test.steps[Stop this job's acpmux daemons and remove its home]`

Above `- name: Stop this job's acpmux daemons and remove its home`:

```text
# Also after a failure or a cancel: end the daemon of this job's home and
# its agents (shutdown never starts one), then delete the home.
```

## `jobs.swift-test.steps[Upload the test helper's crash reports]`

Above `- name: Upload the test helper's crash reports`:

```text
# A test helper that died on a signal leaves its crash report here
# (scripts/cmux-next/swift-test-with-hang-sampler.sh): the crashed
# thread names the test that trapped.
```

## `jobs.swift-test.steps[Record this pass for the same inputs]`

Above `- name: Record this pass for the same inputs`:

```text
# A pass records itself for the next run on the same inputs: an artifact named after
# the key, which every pull request and the base can list (scripts/ci/job_reuse.py
# takes only passes of this repository's own runs). Never from a fork pull request.
# An uncached (no_reuse) run records too.
```

## `jobs.daemon-test`

Above `daemon-test:`:

```text
# The live-daemon suites (daemon integration and branch tests, the mobile
# live daemon and first launch) against this commit's own cmux-tui tree,
# which the gate above waits for on Linux. Only the daemon tier runs it:
# daemon, Rust core, FFI and control paths on a same-repository PR (a fork
# PR with full-ci), and every push and dispatch.
```

## `jobs.daemon-test.if`

Above `if: ${{ inputs.same_tree_origin != 'push' && !cancelled() && (needs.web-bundles.result == 'success' || needs.web-bundles.result == 'skipped') && (github.even...`:

```text
# This run's own tier on a published tree (path routing's probe), or
# same-tree mode after the artifacts workflow published it.
```

## `jobs.daemon-test.concurrency`

Above `concurrency:`:

```text
# A push's Mac job waits for the same job of the running push run and is
# never cancelled once it runs; a newer push replaces only the waiting one
# (see the workflow concurrency comment).
```

## `jobs.daemon-test.permissions`

Above `permissions:`:

```text
# actions: read lets the same-tree cmux-tui fetch read the artifacts runs.
```

## `jobs.daemon-test.permissions.statuses`

Above `statuses: write`:

```text
# statuses: write reports a same-tree mode result on the tested commit.
```

## `jobs.daemon-test.outputs.generated_files`

Above `generated_files: ${{ steps.generated-files-verdict.outputs.verdict }}`:

```text
# The folded generated files verdict (generated-verdict reads it): fresh, stale, catalog or empty.
```

## `jobs.daemon-test.env.CMUX_TUI_TREE_KEY`

Above `CMUX_TUI_TREE_KEY: ${{ inputs.same_tree_sha == '' && needs.path_route.outputs.tree_fetch_key || '' }}`:

```text
# A pull request that changes no cmux-tui path runs on the newest
# published tree when its own is not ready (path routing's probe).
```

## `jobs.daemon-test.env.CMUX_NEXT_FOLD_GENERATED`

Above `CMUX_NEXT_FOLD_GENERATED: ${{ needs.path_route.outputs.generated_host == 'daemon-test' }}`:

```text
# The generated files are checked here, on this job's package build, when path routing
# picks this job (generated_host): a push it runs on, or a pull request swift-test does
# not build. No generated-files job builds the same package and tests.
```

## `jobs.daemon-test.steps[Give this job its own acpmux home]`

Above `- name: Give this job its own acpmux home`:

```text
# This job's tests can start acpmux daemons: they get a home of the job's
# own, never the runner's ~/.acpmux, the mini's own daemon
# (tests/test_ci_acpmux_job_home.py).
```

## `jobs.daemon-test.steps[Checkout].with.ref`

Above `ref: ${{ inputs.same_tree_sha || '' }}`:

```text
# Same-tree mode tests the commit the tree was probed for.
```

## `jobs.daemon-test.steps[Checkout].with.submodules`

Above `submodules: false`:

```text
# The package graph reads no submodule; GhosttyNextKit comes from
# SwiftPM (Packages/Shared/CmuxGhosttyKit).
```

## `jobs.daemon-test.steps[Discard the workspace repository after a failed checkout]`

Above `- name: Discard the workspace repository after a failed checkout`:

```text
# A blob-filtered checkout by another job leaves a partial clone in this
# reused workspace, and a missing blob is fetched from GitHub mid-step,
# unretried. Retry once from a fresh repository; a second failure fails.
```

## `jobs.daemon-test.steps[Retry checkout after transient network failure].with.ref`

Above `ref: ${{ inputs.same_tree_sha || '' }}`:

```text
# Same-tree mode tests the commit the tree was probed for.
```

## `jobs.daemon-test.steps[Retry checkout after transient network failure].with.submodules`

Above `submodules: false`:

```text
# The package graph reads no submodule; GhosttyNextKit comes from
# SwiftPM (Packages/Shared/CmuxGhosttyKit).
```

## `jobs.daemon-test.steps[Drop stale submodule checkouts (self-hosted reused workspace)]`

Above `- name: Drop stale submodule checkouts (self-hosted reused workspace)`:

```text
# A mini reuses its workspace: drop the submodule checkouts a previous
# job left (scripts/ci/reset-stale-submodules.sh), as on a fresh checkout.
```

## `jobs.daemon-test.steps[Require the GUI session on a mini]`

Above `- name: Require the GUI session on a mini`:

```text
# The GUI-tagged suites (.requiresGUISession, .requiresPasteboard; for
# example SidebarLiveReorderTests) skip when the host has no display or
# pasteboard. Every glaeda mini has both: in 153 swift-test jobs
# (2026-10-04/05) all 11 minis behind the side label ran
# SidebarLiveReorderTests and no GUI or pasteboard test skipped. On a
# mini, CMUX_TEST_REQUIRE_GUI=1 turns a lost display into a failure
# instead of a silent skip. Blacksmith and hosted labels
# keep the skip: nothing has shown that they have a display session.
# Not on a pull request: display tests gate no PR (Leo, 2026-10-31: "i dont like doing display
# tests anymore"), so a PR's display suites skip, and a lost display never fails a PR job. Pushes
# and nightlies keep the requirement as advisory coverage.
```

## `jobs.daemon-test.steps[Keep Swift package builds on this owned Mac]`

Above `- name: Keep Swift package builds on this owned Mac`:

```text
# Checkout removes .build. Link the owned Mac's kept build after Xcode
# selection so its fingerprint uses the compiler that runs this job.
```

## `jobs.daemon-test.steps[Compute the fast-tier seed keys]`

Above `- name: Compute the fast-tier seed keys`:

```text
# Off the owned Macs, start from the build a feat-cmux-next push seeded for the fast tier
# (cmux-next-fast-tier-seed.yml): the same `swift build --build-tests` of this package at a
# recent base, at the same workspace path. With the seed's input times replayed, only what
# this change touched compiles, so a daemon-only change compiles no Swift and goes straight
# to the tests. The seed's resource bundles are dropped first (owned_spm_scratch.py
# drop-bundles, as a kept build's are). Any miss builds as before.
```

## `jobs.daemon-test.steps[Setup Bun]`

Above `- name: Setup Bun`:

```text
# The package's resources include the web bundles (agent pane, pages,
# Activity) and the tests read them: build them from the
# sources (cx-vn5) with the bun webviews/package.json pins.
```

## `jobs.daemon-test.steps[Give this job its own bun]`

Above `- name: Give this job its own bun`:

```text
# The minis share ~/.bun with workflows that install another bun; this
# job runs on its own copy of the pinned one (private-bun.sh).
```

## `jobs.daemon-test.steps[Setup Node]`

Above `- name: Setup Node`:

```text
# The webviews app's `vp build` must run on node: on bun it emits
# different bytes (build-web-bundles.sh).
```

## `jobs.daemon-test.steps[Source key of the web bundles]`

Above `- name: Source key of the web bundles`:

```text
# The Linux web-bundles job builds the bundles once per source key and caches them; a
# hit installs them here instead of building, and a miss builds them in the next step.
```

## `jobs.daemon-test.steps[Restore the web bundles from R2]`

Above `- name: Restore the web bundles from R2`:

```text
# R2 first (feat-cmux-next's bundles, published by the web-bundles job of
# its pushes; no credential), then this run's GitHub cache entry.
```

## `jobs.daemon-test.steps[Check generated action catalog, surfaces and inventory]`

Above `- name: Check generated action catalog, surfaces and inventory`:

```text
# The generated files checks (CMUX_NEXT_FOLD_GENERATED), on the package and tests built above
# and before the catalogs are compiled into the resource bundles, as the generated-files job
# runs them. generated-verdict gives their verdict (this job's generated_files output).
```

## `jobs.daemon-test.steps[Pack the exports for the base autofix]`

Above `- name: Pack the exports for the base autofix`:

```text
# The base autofix's exports, on a push or base tier run whose generated files this job checks
# (the generated-files job's step of the same name, which that run skips).
```

## `jobs.daemon-test.steps[Clean generated layout-reducer FFI lockfile]`

Above `- name: Clean generated layout-reducer FFI lockfile`:

```text
# Building the package's reducer FFI can rewrite the isolated crate's
# workspace lockfile. Put the checkout back immediately before
# pin-cmux-tui validates it: the committed lockfile (#37324 tracks it)
# is restored, and an untracked one is removed. Deleting a tracked
# lockfile leaves the tree dirty, and pin-cmux-tui refuses that.
```

## `jobs.daemon-test.steps[Fetch the same-tree cmux-tui].env.CMUX_TUI_TREE_WAIT_SECONDS`

Above `CMUX_TUI_TREE_WAIT_SECONDS: "120"`:

```text
# Published before this job starts (probe or same-tree mode): a download.
```

## `jobs.daemon-test.steps[Fetch the same-tree cmux-tui].env.CMUX_TUI_TREE_PUBLISHER_SHA`

Above `CMUX_TUI_TREE_PUBLISHER_SHA: ${{ inputs.same_tree_sha == '' && github.event_name != 'pull_request' && github.sha || '' }}`:

```text
# Push and dispatch runs fail fast when the artifacts runs for this
# commit were cancelled or superseded (pin-cmux-tui.sh --help).
```

## `jobs.daemon-test.steps[Regenerate stale files]`

Above `- name: Regenerate stale files`:

```text
# A test helper that died on a signal leaves its crash report here
# (scripts/cmux-next/swift-test-with-hang-sampler.sh): the crashed
# thread names the test that trapped.
# The generated files verdict of a push (the checks above), as generated-files gives it.
# Only the generated paths are collected into the artifact.
```

## `jobs.daemon-test.steps[Give the generated files verdict]`

Above `- name: Give the generated files verdict`:

```text
# The folded verdict, for generated-verdict: never this job's own result, so a stale file
# does not turn `cmux-next daemon tests` red, and a red `cmux-next daemon tests` does not hide a stale file.
```

## `jobs.daemon-test.steps[Give the generated files verdict].env.CATALOG`

Above `CATALOG: ${{ steps.actions.outputs.catalog }}`:

```text
# failure when the action checks fail with fresh exports too (judge-action-exports.sh): not stale.
```

## `jobs.daemon-test.steps[Stop this job's acpmux daemons and remove its home]`

Above `- name: Stop this job's acpmux daemons and remove its home`:

```text
# Also after a failure or a cancel: end the daemon of this job's home and
# its agents (shutdown never starts one), then delete the home.
```

## `jobs.daemon-test.steps[Report the same-tree result on the tested commit]`

Above `- name: Report the same-tree result on the tested commit`:

```text
# Generated files are fresh: the action catalog, surfaces and inventory
# (ActionSurfaceParityTests and its siblings) and the settings exports,
# against a fresh export; the CI target graph and the defaults snapshot are
# bot-only (#21946) and not checked. Its
# own job, so a pull request that skips the package tests still cannot land
# a stale export (feat-cmux-next went red at a925bd9 that way). When a file
# is stale, the job regenerates it, uploads the regenerated files as the
# cmux-next-generated-patch artifact and fails with the commands to run.

    # Same-tree mode: the result goes on the commit the run was for (a push,
    # or the pull request head), whichever ref the dispatch ran on.
```

## `jobs.generated-files.if`

Above `if: ${{ !cancelled() && (needs.web-bundles.result == 'success' || needs.web-bundles.result == 'skipped') && needs.path_route.outputs.generated == 'true' && n...`:

```text
# Only where path routing picks it (generated_host): a run that swift-test or daemon-test
# builds the package in checks its generated files there (CMUX_NEXT_FOLD_GENERATED), and
# generated-verdict gives that verdict.
```

## `jobs.generated-files.concurrency`

Above `concurrency:`:

```text
# Bind pushes to their exact source head. A stalled old head therefore
# cannot occupy the one branch-wide pending slot for every newer head.
```

## `jobs.generated-files.environment`

Above `environment: ${{ github.event_name != 'pull_request' && 'ci-routing-agent' || '' }}`:

```text
# vars.CI_SESSION_LANE_RUNNER is generated files' own owned label (glaeda-session-light-xcode-26.6,
# the light minis' session runner: a logged-in session, no console token). It is set only after
# those runners are registered; while it is unset the route below is unchanged. The fork clause
# stays first, so a fork pull request never reaches it. Same-repository PRs use the
# generic side picker and its bounded overflow, never the console GUI label.
```

## `jobs.generated-files.permissions.actions`

Above `actions: read`:

```text
# The reuse lookup lists artifacts.
```

## `jobs.generated-files.steps[Give this job its own acpmux home]`

Above `- name: Give this job its own acpmux home`:

```text
# This job's tests can start acpmux daemons: they get a home of the job's
# own, never the runner's ~/.acpmux, the mini's own daemon
# (tests/test_ci_acpmux_job_home.py).
```

## `jobs.generated-files.steps[Checkout].with.submodules`

Above `submodules: false`:

```text
# The package graph reads no submodule; GhosttyNextKit comes from
# SwiftPM (Packages/Shared/CmuxGhosttyKit).
```

## `jobs.generated-files.steps[Discard the workspace repository after a failed checkout]`

Above `- name: Discard the workspace repository after a failed checkout`:

```text
# A blob-filtered checkout by another job leaves a partial clone in this
# reused workspace, and a missing blob is fetched from GitHub mid-step,
# unretried. Retry once from a fresh repository; a second failure fails.
```

## `jobs.generated-files.steps[Retry checkout after transient network failure].with.submodules`

Above `submodules: false`:

```text
# The package graph reads no submodule; GhosttyNextKit comes from
# SwiftPM (Packages/Shared/CmuxGhosttyKit).
```

## `jobs.generated-files.steps[Drop stale submodule checkouts (self-hosted reused workspace)]`

Above `- name: Drop stale submodule checkouts (self-hosted reused workspace)`:

```text
# A mini reuses its workspace: drop the submodule checkouts a previous
# job left (scripts/ci/reset-stale-submodules.sh), as on a fresh checkout.
```

## `jobs.generated-files.steps[Require the GUI session on a mini]`

Above `- name: Require the GUI session on a mini`:

```text
# The GUI-tagged suites (.requiresGUISession, .requiresPasteboard; for
# example SidebarLiveReorderTests) skip when the host has no display or
# pasteboard. Every glaeda mini has both: in 153 swift-test jobs
# (2026-10-04/05) all 11 minis behind the side label ran
# SidebarLiveReorderTests and no GUI or pasteboard test skipped. On a
# mini, CMUX_TEST_REQUIRE_GUI=1 turns a lost display into a failure
# instead of a silent skip. Blacksmith and hosted labels
# keep the skip: nothing has shown that they have a display session.
# Not on a pull request: display tests gate no PR (Leo, 2026-10-31: "i dont like doing display
# tests anymore"), so a PR's display suites skip, and a lost display never fails a PR job. Pushes
# and nightlies keep the requirement as advisory coverage.
```

## `jobs.generated-files.steps[Fingerprint this job's inputs]`

Above `- name: Fingerprint this job's inputs`:

```text
# With vars.CI_NEXT_JOB_REUSE, a pass on the same inputs stands for this run: the
# steps below skip and the summary names the run that passed. The key
# (scripts/ci/job_input_fingerprint.py generated-files) is the commit's full tree hash, this
# workflow file, the toolchain and the env flags below; a missing value gives no key.
# Any change to the tree, a base move included, changes the key. Not on a fork pull
# request, which could record a pass of its own under any key.
```

## `jobs.generated-files.steps[Mint the cmux-bot artifact read token]`

Above `- name: Mint the cmux-bot artifact read token`:

```text
# A feat-cmux-next push or dispatch lists the pass artifacts with a cmux-bot token,
# off the repository token's hourly budget; a pull request run, or a failed mint,
# keeps the workflow token (scripts/ci/job_reuse.py).
```

## `jobs.generated-files.steps[Keep Swift package builds on this owned Mac]`

Above `- name: Keep Swift package builds on this owned Mac`:

```text
# Checkout removes .build. Link the owned Mac's kept build after Xcode
# selection so its fingerprint uses the compiler that runs this job.
```

## `jobs.generated-files.steps[Compute the fast-tier seed keys]`

Above `- name: Compute the fast-tier seed keys`:

```text
# Off the owned Macs, start from the build a feat-cmux-next push seeded for the fast tier
# (cmux-next-fast-tier-seed.yml): the same `swift build --build-tests` of this package at a
# recent base, at the same workspace path. With the seed's input times replayed, only what
# this change touched compiles, so a daemon-only change compiles no Swift and goes straight
# to the tests. The seed's resource bundles are dropped first (owned_spm_scratch.py
# drop-bundles, as a kept build's are). Any miss builds as before.
```

## `jobs.generated-files.steps[Setup Bun]`

Above `- name: Setup Bun`:

```text
# The package's resources include the web bundles (agent pane, pages,
# Activity) and the tests read them: build them from the
# sources (cx-vn5) with the bun webviews/package.json pins.
```

## `jobs.generated-files.steps[Give this job its own bun]`

Above `- name: Give this job its own bun`:

```text
# The minis share ~/.bun with workflows that install another bun; this
# job runs on its own copy of the pinned one (private-bun.sh).
```

## `jobs.generated-files.steps[Setup Node]`

Above `- name: Setup Node`:

```text
# The webviews app's `vp build` must run on node: on bun it emits
# different bytes (build-web-bundles.sh).
```

## `jobs.generated-files.steps[Source key of the web bundles]`

Above `- name: Source key of the web bundles`:

```text
# The Linux web-bundles job builds the bundles once per source key and caches them; a
# hit installs them here instead of building, and a miss builds them in the next step.
```

## `jobs.generated-files.steps[Restore the web bundles from R2]`

Above `- name: Restore the web bundles from R2`:

```text
# R2 first (feat-cmux-next's bundles, published by the web-bundles job of
# its pushes; no credential), then this run's GitHub cache entry.
```

## `jobs.generated-files.steps[Check the settings exports]`

Above `- name: Check the settings exports`:

```text
# The CI target graph is bot-only (scripts/cmux-next/generated_outputs.py,
# #21946): it is stale on every event between a merge that adds a target
# and the base autofix's commit, so no event checks it here.

# The settings exports (schemas/settings/settings-schema.json, docs/mdm)
# are compared with a fresh export, never with a committed stamp of their
# sources (Leo 2026-10-21: "just generate and don't commit"). The script
# says when it exports and whose staleness a stale export is; the
# daemon-test job's folded copy runs the same one.
```

## `jobs.generated-files.steps[Pack the exports for the base autofix]`

Above `- name: Pack the exports for the base autofix`:

```text
# The base autofix's action and settings exports, made on this build instead of a second Mac
# build of the same push (cmuxterm-hq#5424): every export regenerated, packed under this commit's
# tree (scripts/cmux-next/base_autofix_pushed_exports.py), and uploaded for
# cmux-next-base-autofix.yml's pushed-exports job. Pushes of feat-cmux-next and its base tier
# dispatches (cmux-next-base-tier-kick.yml, which these checks move to) only, so a pack is only
# ever this repository's merged code. It puts the checkout's exports back as they were, so
# the steps below see what the checks left; a failure makes no pack (the autofix's Mac job then
# regenerates them) and never fails this job. vars.CMUX_NEXT_BASE_EXPORTS_PACK=0 turns it off.
```

## `jobs.generated-files.steps[Regenerate stale files]`

Above `- name: Regenerate stale files`:

```text
# Only the generated paths are collected into the artifact.
```

## `jobs.generated-files.steps[Stop this job's acpmux daemons and remove its home]`

Above `- name: Stop this job's acpmux daemons and remove its home`:

```text
# Also after a failure or a cancel: end the daemon of this job's home and
# its agents (shutdown never starts one), then delete the home.
```

## `jobs.generated-files.steps[Record this pass for the same inputs]`

Above `- name: Record this pass for the same inputs`:

```text
# A pass records itself for the next run on the same inputs: an artifact named after
# the key, which every pull request and the base can list (scripts/ci/job_reuse.py
# takes only passes of this repository's own runs). Never from a fork pull request.
# An uncached (no_reuse) run records too.
```

## `jobs.generated-verdict`

Above `generated-verdict:`:

```text
# The generated files verdict of a run whose swift-test or daemon-test checked them on its own
# package build (path_route's generated_host, CMUX_NEXT_FOLD_GENERATED): its own check, on Linux,
# so a stale file is never a red swift or daemon test and a red test never hides a stale file.
# A host that never gave a verdict (its build failed, it stopped early) fails this too.
```

## `jobs.release-compile-fast`

Above `release-compile-fast:`:

```text
# The fleet compile check is the first Release gate. It checks the exact
# source without occupying a Mac runner.
# Keep the fast-check wrapper's name distinct from the admission gate below:
# an unavailable wrapper is a successful job but is not a Release compile.
```

## `jobs.release-compile-fast.if`

Above `if: ${{ !cancelled() && needs.path_route.outputs.native == 'true' && needs.push-head-preflight.outputs.current == 'true' && github.repository_owner == 'manaf...`:

```text
# It submits the fleet compile check from a gateway runner macos-placement saw idle in this
# attempt (gateway_runner), like the other build-fleet gateway jobs. With none idle (or no
# reading from this attempt) it does not skip into the Mac queue: it runs on Linux and reads the
# build fleet's own Release (-Onone) compile of this push, the one compile-status publishes as
# cmux-next/compile (the controller compiles every feat-cmux-next push on the Linux pool). Only
# when that gives no verdict does release-compile run on a Mac. On 2026-11-02 from 09:39Z every
# gateway runner was busy, so pushes 622a6b75 and 0fa148c5 queued their Mac Release compile for
# over two hours while cmux-next/compile had passed both in three minutes.
```

## `jobs.release-compile-fast.steps[Run the fast fleet compile check]`

Above `- name: Run the fast fleet compile check`:

```text
# A compile failure keeps this step red but not the job, and the admission
# job turns verdict=fail red under the gate name. Without a verdict (the
# job refused at runner setup or killed, or this step died before writing
# one) release-compile takes over instead.
```

## `jobs.release-compile-fast.steps[Run the fast fleet compile check].env.GATEWAY`

Above `GATEWAY: ${{ needs.macos-placement.outputs.gateway_attempt == format('{0}', github.run_attempt) && needs.macos-placement.outputs.gateway_runner || '' }}`:

```text
# Set when this job took an idle gateway runner; empty on the Linux route.
```

## `jobs.release-compile-fast.steps[Run the fast fleet compile check].env.RESULTS`

Above `RESULTS: https://gh-events.cmux.com/compile-checks/v1`:

```text
# The build fleet's compile results (compile-status reads the same endpoint, unauthenticated).
```

## `jobs.release-compile-fast-admission`

Above `release-compile-fast-admission:`:

```text
# Promotion admission keys off this exact job name. Keep it separate from
# the fast-check wrapper so unavailable fast checks cannot satisfy the gate.
# It runs whenever the fast check ran and did not hand off to the Mac
# fallback, and is green only on a pass: a fleet compile error stays red
# under the gate name. The fallback takes over on verdict unavailable and
# whenever the fast check finished without a verdict (refused at runner
# setup, or its step died first), so exactly one job carries the gate name
# for a push.
# It requests promotion itself, once green: a request from the fast check
# reached main before this job existed (main waits about 30 s for it), and a
# rerun of only this gate never reruns a downstream request skipped earlier.
```

## `jobs.release-compile-fast-admission.timeout-minutes`

Above `timeout-minutes: 10`:

```text
# The request fetches feat-cmux-next's recent history to find the newest
# commit with the published tree (the --tree-ready search).
```

## `jobs.release-compile.continue-on-error`

Above `continue-on-error: false`:

```text
# The base's compile check: a current feat-cmux-next push compiles once its
# preflight sees it is still the tip. Superseded pushes skip before queueing,
# while a compile that has started gets its own run group and cannot be
# evicted by a newer push. This leaves one running compile and the newest
# current tip queued without GitHub's one-pending-run eviction.
# Release runs on every base push, next-batch/* push and dispatch, and on a
# PR the native tier reaches with full-ci. #22325 ran it on every
# same-repository PR; on 2026-10-21 (~20:10Z) 76 of the ~350 queued Mac jobs
# were this compile, so a same-repository PR compiles its head on the build
# fleet (app-compile-fleet) and runs this only with full-ci or when the
# fleet gave no verdict; its merge is compiled by the base push
# (push-attribution names it on a red).
# A fork PR runs it with full-ci, or when it changes any .swift
# file under Packages/macOS/CmuxNext/ (Sources or Tests, whatever else it
# changes; path_route's cmuxnext_swift). A Release-only
# optimizer crash (cx-ebm.59.5: EarlyPerfInliner on a main-actor generic
# class's isolated deinit) reached the base through such a PR, because the
# Debug fast tier and Debug `swift build` cannot see it.
# When macos-placement skips (a fork PR), `!cancelled()` keeps this job
# running and runs-on below takes the shared fallback route.
```

## `jobs.release-compile.concurrency`

Above `concurrency:`:

```text
# A started push compile has a per-run group and is never cancelled by a
# newer push. Superseded pushes are skipped by the job condition above.
```

## `jobs.release-compile.runs-on`

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name !...`:

```text
# The fleet compile check is the primary gate. This Mac job is only the
# compatible fallback when it has no verdict; on a push (attempt 1) it
# takes an idle freshness slot first (macos-placement's fresh_runner, the
# glaeda-dev-* label PR jobs never target), then a free fleet Mac, then
# Blacksmith macOS. A busy or offline slot is skipped at placement, so it
# never queues on the slot.
# A same-repository PR takes the Blacksmith label macos-placement gave it
# only when no idle mini took it (the cascade counts the idle minis first),
# else the owned side label. Its runner output is the side label whether or
# not a mini is free, so reading it first left a PR's compile queued on a
# saturated side label with no path off it (cmux#26723, 2026-10-29).
```

## `jobs.release-compile.permissions.actions`

Above `actions: write`:

```text
# The reuse lookup lists artifacts.
```

## `jobs.release-compile.timeout-minutes`

Above `timeout-minutes: 60`:

```text
# One-architecture Release (-O, whole-module) xcodebuild of CmuxNextApp
# with the nightly's Xcode. Debug `swift build` and Xcode 27 accept code
# that this rejects; without this job such code fails only the nightly.
```

## `jobs.release-compile.env.CMUX_NEXT_RUNNER`

Above `CMUX_NEXT_RUNNER: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || github.event_name == 'pull_request' && github.event.pull_request.head.repo.fu...`:

```text
# This job's label (its runs-on): a glaeda-* label means a mini.
```

## `jobs.release-compile.steps[Discard the workspace repository after a failed checkout]`

Above `- name: Discard the workspace repository after a failed checkout`:

```text
# A blob-filtered checkout by another job leaves a partial clone in this
# reused workspace, and a missing blob is fetched from GitHub mid-step,
# unretried. Retry once from a fresh repository; a second failure fails.
```

## `jobs.release-compile.steps[Drop stale submodule checkouts (self-hosted reused workspace)]`

Above `- name: Drop stale submodule checkouts (self-hosted reused workspace)`:

```text
# A mini reuses its workspace: drop the submodule checkouts a previous
# job left (scripts/ci/reset-stale-submodules.sh), as on a fresh checkout.
```

## `jobs.release-compile.steps[Fingerprint this job's inputs]`

Above `- name: Fingerprint this job's inputs`:

```text
# With vars.CI_NEXT_JOB_REUSE, a pass on the same inputs stands for this run: the
# steps below skip and the summary names the run that passed. The key
# (scripts/ci/job_input_fingerprint.py release-compile) is the commit's full tree hash, this
# workflow file, the toolchain and the env flags below; a missing value gives no key.
# Any change to the tree, a base move included, changes the key. Not on a fork pull
# request, which could record a pass of its own under any key.
```

## `jobs.release-compile.steps[Mint the cmux-bot artifact read token]`

Above `- name: Mint the cmux-bot artifact read token`:

```text
# A feat-cmux-next push or dispatch lists the pass artifacts with a cmux-bot token,
# off the repository token's hourly budget; a pull request run, or a failed mint,
# keeps the workflow token (scripts/ci/job_reuse.py).
```

## `jobs.release-compile.steps[Release compile]`

Above `- name: Release compile`:

```text
# On a mini, the compile reads the fleet's shared compile cache (glaeda fleet-cas, the store
# on cmux-lawrence's SSD) from the host's canonical root, read-only: only the trusted
# writer fills it (scripts/cmux-next/release-compile-fleet-cas.sh). A node that does not
# answer or a root another compile holds builds per runner as before, at once.
# vars.CMUX_NEXT_RELEASE_FLEET_CAS=off turns it off.
```

## `jobs.release-compile.steps[Warn on missing Release bundle notices]`

Above `- name: Warn on missing Release bundle notices`:

```text
# Early advisory for a newly bundled binary. The signed nightly check
# remains authoritative, but this names an unmapped file during review.
```

## `jobs.release-compile.steps[Fetch the Chromium engine]`

Above `- name: Fetch the Chromium engine`:

```text
# On a mini, the CEF glue (CEF's C++ wrapper, the CEFShim dylib and the
# helper binary) is also compiled against the pinned Chromium engine
# (scripts/cmux-next/cef-manifest.json), the way the app's Embed CEF
# phase builds it, so a shim or manifest change the engine does not
# accept fails here and not in the nightly. ensure-cef.sh fills the
# mini's kept host cache (scripts/cmux-next/cef-cache-root.sh) from the private R2
# bucket with the read-only key, which only this step receives and only
# in same-repository runs, as in ci-macos.yml's admission; later runs
# read the cache. A runner's own ~/.secrets file is never a source.
# Blacksmith runs skip both steps: they keep no cache, so each run would
# pay the download and the wrapper compile. So the check is advisory: a
# re-run (Blacksmith) or a fork pull request does not repeat it.
```

## `jobs.release-compile.steps[Chromium Objective-C contract against the pinned engine]`

Above `- name: Chromium Objective-C contract against the pinned engine`:

```text
# The pinned engine's Objective-C selectors for NSApp and its delegate
# against the reviewed contract (scripts/cmux-next/chromium-objc-contract.json):
# an engine that can send cmux an unreviewed selector fails here, before
# it ships ("unrecognized selector", 2026-10-20).
```

## `jobs.release-compile.steps[Request nightly-next promotion after this gate]`

Above `- name: Request nightly-next promotion after this gate`:

```text
# A pass records itself for the next run on the same inputs: an artifact named after
# the key, which every pull request and the base can list (scripts/ci/job_reuse.py
# takes only passes of this repository's own runs). Never from a fork pull request.
# An uncached (no_reuse) run records too. On a mini, only a run whose CEF shim compile
# and Objective-C contract check ran records: a pass that skipped them does not stand
# for a run that would have checked them.
# A rerun of only this gate does not rerun a downstream job that was
# skipped in the original attempt. Request here as well as in the small
# downstream helper so a newly green rerun always reaches main.
```

## `jobs.swift-exports-cache`

Above `swift-exports-cache:`:

```text
# Caches the Swift exports of a green feat-cmux-next push under their source
# key (scripts/cmux-next/swift-exports-key.py), so a job that only reads them
# (the web bundles read the settings schema) can restore them with
# swift-exports-cache.sh install instead of a Mac build (cx-vn5). A push runs
# every tier, so on success the committed exports are the ones the Swift
# tests checked.
```

## `jobs.swift-exports-cache.if`

Above `if: ${{ !cancelled() && github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next' && needs.path_route.result == 'success' && needs.checks.resu...`:

```text
# generated-files skips a push whose generated files daemon-test checks (CMUX_NEXT_FOLD_GENERATED);
# generated-verdict gives that verdict.
# !cancelled() and each need's result: the implicit success() reads every ancestor, and pr-quiet-period skips on a push.
```

## `jobs.request-nightly-next`

Above `request-nightly-next:`:

```text
# A green Release compile on a feat-cmux-next push asks main's nightly.yml to
# promote this commit to the protected `nightly-next` branch. The fast-check gate
# (release-compile-fast-admission) requests in its own job, once green; the Mac
# job below requests only when it had no verdict. (A separate helper job after
# the fast gate repeated the same request at the same commit: dropped.) Main's promote job refuses a head whose push run has no successful
# Release compile, so each request waits for its own gate and for nothing else.
# Since 2026-10-28 this request only reports: request-nightly-next.sh dispatches
# the promotion only from main's 30-minute nightly-next-tick.yml
# (NIGHTLY_NEXT_PROMOTE=1), so a burst of landings starts one nightly build,
# not one each (six ran at once). Only main's job, in the `release` environment,
# holds the release App key and checks this push run's Release compile; this
# job only needs actions: write to request it.
# The request also waits for this commit's cmux-tui tree: the nightly builds
# the tip with the tip's own nightly.yml and daemon only when that tree is
# published (a tip with a building tree failed runs 37767816879 and
# 37769010617). When the tree publishes after this job,
# cmux-tui-artifacts.yml's request-nightly-next asks instead
# (scripts/cmux-next/request-nightly-next.sh, tested by
# scripts/cmux-next/tests/request-nightly-next.test.sh).
```

## `jobs.request-nightly-next.steps[Drop stale submodule checkouts (self-hosted reused workspace)]`

Above `- name: Drop stale submodule checkouts (self-hosted reused workspace)`:

```text
# A mini reuses its workspace: drop the submodule checkouts a previous
# job left (scripts/ci/reset-stale-submodules.sh), as on a fresh checkout.
```

## `jobs.request-nightly-next.steps[Request a nightly-next continuation for an accepted pending build]`

Above `- name: Request a nightly-next continuation for an accepted pending build`:

```text
# GitHub runs `schedule` only from main's workflow, so this green compile
# is the periodic tick that publishes an earlier nightly-next build Apple
# accepted after its run stopped waiting (cx-f58x). It builds nothing and
# submits nothing (scripts/cmux-next/continue-nightly-next.sh, tested by
# scripts/cmux-next/tests/continue-nightly-next.test.sh).
```

## `jobs.dev-daily-place`

Above `dev-daily-place:`:

```text
# A DEV daily's Release compile (cmux-scheme-compile) goes to the idle owned Mac whose host tree last
# compiled the nearest commit (scripts/ci/dev_landing_place.py with FRESH_LABEL, place_daily()). From one
# runner listing: a host with any busy runner is occupied (whatever holds its host lock runs there); a
# pick claims a host only when its label resolves to exactly one idle runner (a DEV slot or root runner by
# its static label, or the one idle DEV slot), scored by the host's cmux-next-dev-cas-holder-<host>
# record. Otherwise the shared DEV slot label, then the side label, at once: it never waits. With nothing
# owned idle it prints no route and the compile keeps macos-placement's. A warm host compiles in about
# 130 s of xcodebuild, a host with no tree in about 808 s (2026-10-28, 15 DEV compiles, 4 warm).
# vars.CMUX_NEXT_DEV_COMPILE_AFFINITY=0 turns it off.
# It runs only when cmux-scheme-compile will (the same tree condition), so it never waits for a skipped compile.
# It places only a run whose DEV Release app gets built: it carries that step's dispatch condition
# (compile-cmux-next-dev-release's `if`) word for word, so a daily from another branch or for a stale
# commit never holds a Mac. tests/test_cmux_next_dev_landing_workflow.py keeps the two the same.
```

## `jobs.dev-daily-place.outputs.runs_on`

Above `runs_on: ${{ steps.place.outputs.runs_on }}`:

```text
# JSON for cmux-scheme-compile's runs-on (a pinned runner is [its pool label, glaeda-runner-<name>]),
# and that list's first label for the job's CMUX_NEXT_RUNNER copy; both empty keep the job's route.
```

## `jobs.dev-daily-place.steps[Place the DEV compile on the nearest cache].env.BLACKSMITH_CANDIDATE`

Above `BLACKSMITH_CANDIDATE: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || github.event_name == 'pull_request' && github.event.pull_request.head.rep...`:

```text
# With no owned runner idle the compile overflows to the Blacksmith macOS label whose queue moves
# (dev_landing_place.blacksmith_overflow(), the nightly signer's pick), not the busy DEV slot.
# The owner and fork branches only satisfy tests/test_ci_fork_runner_routing.py (this job runs only in
# manaflow-ai on dispatch); blacksmith_overflow() drops 'macos-26' and keeps the Blacksmith labels.
```

## `jobs.cmux-scheme-compile.if`

Above `if: ${{ (github.event_name != 'pull_request' || contains(github.event.pull_request.labels.*.name, 'full-ci') || github.event.pull_request.head.repo.full_name...`:

```text
# This run's own tier on a published tree (path routing's probe), or
# same-tree mode after the artifacts workflow published it.
```

## `jobs.cmux-scheme-compile.concurrency`

Above `concurrency:`:

```text
# A push's Mac fallback waits only when the fleet compile check gives no verdict.
# It is never cancelled once it runs; a newer push is filtered by the head
# preflight before it can take a runner.
```

## `jobs.cmux-scheme-compile.permissions`

Above `permissions:`:

```text
# actions: read lets the same-tree cmux-tui wait read the artifacts runs.
```

## `jobs.cmux-scheme-compile.permissions.statuses`

Above `statuses: write`:

```text
# statuses: write reports a same-tree mode result on the tested commit.
```

## `jobs.cmux-scheme-compile.timeout-minutes`

Above `timeout-minutes: 60`:

```text
# Debug arm64 xcodebuild of the cmux app scheme: the app host and every
# local package it links (CmuxControlSocket, CmuxCore, ...), which the
# CmuxNext jobs above never compile. A main merge once left
# CmuxControlSocket extending deleted types and only fleet dev builds
# failed. On a mini the DerivedData is kept per runner, so a run compiles
# what changed; Blacksmith builds it cold. A change inside the CmuxNext
# package skips it: the Release compile builds CmuxNextApp and all it links.
```

## `jobs.cmux-scheme-compile.outputs`

Above `outputs:`:

```text
# The crash gate step's outcome, for the crash-ends-app job (that job is the red check, so a
# crash freeze never fails the app-producing job the dogfood and daily publishers read).
# No perf step runs here (Lawrence 2026-10-23: nothing perf-related blocks or slows a push or a
# pull request): the launch-time budget and the perf counter gate run in the perf cron,
# .github/workflows/cmux-next-perf-budgets.yml, on the bench host.
```

## `jobs.cmux-scheme-compile.env.BASH_ENV`

Above `BASH_ENV: ""`:

```text
# scripts/install-rust-ci.sh appends to a set BASH_ENV; keep it unset here (scripts/ci/api_call_log/env.sh).
```

## `jobs.cmux-scheme-compile.env.CMUX_NEXT_RUNNER`

Above `CMUX_NEXT_RUNNER: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || github.event_name == 'pull_request' && github.event.pull_request.head.repo.fu...`:

```text
# This job's label (its runs-on): a glaeda-* label means a mini.
```

## `jobs.cmux-scheme-compile.env.CMUX_TUI_TREE_KEY`

Above `CMUX_TUI_TREE_KEY: ${{ inputs.same_tree_sha == '' && (needs.dev-daily-tree-wait.outputs.tree_fetch_key || needs.path_route.outputs.tree_fetch_key) || '' }}`:

```text
# A pull request that changes no cmux-tui path runs on the newest
# published tree when its own is not ready (path routing's probe).
```

## `jobs.cmux-scheme-compile.steps[Require the requested DEV daily commit]`

Above `- name: Require the requested DEV daily commit`:

```text
# A dev_daily run (direct or same-tree) builds only the SHA the
# dispatcher asked for. A merge that moved feat-cmux-next first must
# fail here: an empty success would read as that tip being published.
```

## `jobs.cmux-scheme-compile.steps[Checkout].with.ref`

Above `ref: ${{ inputs.same_tree_sha || '' }}`:

```text
# Same-tree mode tests the commit the tree was probed for.
```

## `jobs.cmux-scheme-compile.steps[Discard the workspace repository after a failed checkout]`

Above `- name: Discard the workspace repository after a failed checkout`:

```text
# A blob-filtered checkout by another job leaves a partial clone in this
# reused workspace, and a missing blob is fetched from GitHub mid-step,
# unretried. Retry once from a fresh repository; a second failure fails.
```

## `jobs.cmux-scheme-compile.steps[Retry checkout after transient network failure].with.ref`

Above `ref: ${{ inputs.same_tree_sha || '' }}`:

```text
# Same-tree mode tests the commit the tree was probed for.
```

## `jobs.cmux-scheme-compile.steps[Drop stale submodule checkouts (self-hosted reused workspace)]`

Above `- name: Drop stale submodule checkouts (self-hosted reused workspace)`:

```text
# A mini reuses its workspace: drop the submodule checkouts a previous
# job left (scripts/ci/reset-stale-submodules.sh), as on a fresh checkout.
```

## `jobs.cmux-scheme-compile.steps[Decide the fleet build's REF capture]`

Above `- name: Decide the fleet build's REF capture`:

```text
# A feat-cmux-next push's DEV Release app is dev-landing-compile's (one producer of the
# run's cmux-next-dev-daily-unsigned-<sha>); this job builds it on a push only while
# vars.CMUX_NEXT_DEV_LANDING_COMPILE is 0.
# The fleet whole-app build plans from the rules of one real Mac build of the same shape
# (its REF). With CMUX_NEXT_HYBRID_REF_CAPTURE=1 this compile records them, on a mini only,
# when the inputs that change build lines (scripts/cmux-next/hybrid_ref_capture.py key)
# have no complete capture yet; most landings share a key and skip it.
# tests/test_cmux_next_hybrid_ref_capture.py keeps HYBRID_REF_SETTINGS equal to the compile's.
```

## `jobs.cmux-scheme-compile.steps[Decide the fleet build's REF capture].if`

Above `if: vars.CMUX_NEXT_HYBRID_REF_CAPTURE == '1' && ((github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next' && needs.push-head-preflight.outpu...`:

```text
# Before the product lookup: a key with no capture compiles instead of reusing a product
# (a reused product compiles nothing, so there would be no build to capture).
```

## `jobs.cmux-scheme-compile.steps[Decide the fleet build's REF capture].timeout-minutes`

Above `timeout-minutes: 12`:

```text
# The lookup waits out a rate limit for at most 10 minutes (hybrid_ref_capture.py have).
```

## `jobs.cmux-scheme-compile.steps[Decide the fleet build's REF capture].env.HYBRID_REF_SETTINGS`

Above `HYBRID_REF_SETTINGS: |`:

```text
# The compile step's build-line settings, one NAME=VALUE a line (not as env: only the
# compile step may carry them).
```

## `jobs.cmux-scheme-compile.steps[Look up the DEV Release app compiled on the same inputs]`

Above `- name: Look up the DEV Release app compiled on the same inputs`:

```text
# The DEV Release app is reused, not recompiled, when nothing it is built from changed
# (scripts/ci/dev_release_product_reuse.py): the key is job_input_fingerprint.py
# dev-release-product (the tree minus docs, tests and other products, this workflow, Xcode,
# the SDK and the cmux-tui tree), never a branch or commit. A hit downloads the app another
# feat-cmux-next push or DEV run recorded under it and checks its SHA-256; a dev_daily run then
# skips the steps below that only feed xcodebuild. A miss, or any error, compiles as before.
# The key is the tree this job checked out and builds (the pushed or dispatched commit's).
# Signing and publishing still run at this exact SHA (cmux-next-dev-daily.yml). Only this
# workflow on feat-cmux-next reuses: never nightly or stable builds (hq#3967).
```

## `jobs.cmux-scheme-compile.steps[Look up the DEV Release app compiled on the same inputs].env.SKIP_REASON`

Above `SKIP_REASON: ${{ inputs.no_reuse == true && 'no_reuse dispatch' || steps.hybrid-ref.outputs.compile == 'true' && 'a REF capture needs a real compile' || form...`:

```text
# format(): an unset variable is null, and null == '0' is true (both coerce to the number 0).
```

## `jobs.cmux-scheme-compile.steps[Look up the DEV Release app compiled on the same inputs].env.SWIFT_COMPILATION_MODE`

Above `SWIFT_COMPILATION_MODE: ${{ vars.CMUX_NEXT_DEV_SWIFT_COMPILATION_MODE || 'auto' }}`:

```text
# A repository variable the compile step reads changes the product but not this file: key it.
```

## `jobs.cmux-scheme-compile.steps[Fetch the same-tree cmux-tui]`

Above `- name: Fetch the same-tree cmux-tui`:

```text
# The Bundle cmux-tui phase bundles this commit's same-tree cmux-tui
# and runs check-daemon-capabilities.sh on it (Debug builds).
```

## `jobs.cmux-scheme-compile.steps[Fetch the same-tree cmux-tui].env.CMUX_TUI_TREE_WAIT_SECONDS`

Above `CMUX_TUI_TREE_WAIT_SECONDS: "120"`:

```text
# See the package test job above. The helper compares the merge tree
# with its first parent and waits for the base artifact when equal.
# Published before this job starts (probe or same-tree mode): a download.
```

## `jobs.cmux-scheme-compile.steps[Fetch the same-tree cmux-tui].env.CMUX_TUI_TREE_PUBLISHER_SHA`

Above `CMUX_TUI_TREE_PUBLISHER_SHA: ${{ inputs.same_tree_sha == '' && github.event_name != 'pull_request' && github.sha || '' }}`:

```text
# Push and dispatch runs fail fast when the artifacts runs for this
# commit were cancelled or superseded (pin-cmux-tui.sh --help).
```

## `jobs.cmux-scheme-compile.steps[Install Go for the embedded tailnet archive]`

Above `- name: Install Go for the embedded tailnet archive`:

```text
# The same-tree fetch above also brought this tree's acpmux (built once
# with the cmux-tui binaries, cmuxterm-hq#1279). A tree published before
# the tree build carried acpmux has none, and this compiles it.
```

## `jobs.cmux-scheme-compile.steps[Source key of the web bundles]`

Above `- name: Source key of the web bundles`:

```text
# The app's web bundles are build output (cx-vn5); the "Verify web
# bundles" phase refuses an app built without them, and this job's app is
# the dogfood artifact. The Linux web-bundles job builds them once per
# source key (web-bundle-key.py --source) and stores them under it; this
# job installs that tree when it finds it and builds them itself, with bun
# and node, only when it does not. Restored or built, they are the same
# bytes: the key hashes every input and the pinned bun, and the build runs
# on node on both (build-web-bundles.sh).
# A mini reuses its workspace: start from no restored tree, so nothing a
# previous job restored there can be installed with this key's bundles.
```

## `jobs.cmux-scheme-compile.steps[Restore the web bundles from R2]`

Above `- name: Restore the web bundles from R2`:

```text
# R2 first (feat-cmux-next's bundles, published by the web-bundles job of
# its pushes; no credential), then this run's GitHub cache entry.
```

## `jobs.cmux-scheme-compile.steps[Install the restored web bundles]`

Above `- name: Install the restored web bundles`:

```text
# --from checks the tree is complete and that its generated inspector page
# is the committed one, then installs and stamps it. A refusal builds below.
```

## `jobs.cmux-scheme-compile.steps[Give this job its own bun]`

Above `- name: Give this job its own bun`:

```text
# The minis share ~/.bun with workflows that install another bun; this
# job runs on its own copy of the pinned one (private-bun.sh).
```

## `jobs.cmux-scheme-compile.steps[Setup Node]`

Above `- name: Setup Node`:

```text
# The webviews app's `vp build` must run on node: on bun it emits
# different bytes (build-web-bundles.sh).
```

## `jobs.cmux-scheme-compile.steps[Key the DEV compile cache (Blacksmith)]`

Above `- name: Key the DEV compile cache (Blacksmith)`:

```text
# A current feat-cmux-next push also produces the Release app consumed by
# cmux-next-dev-daily.yml. Keep this separate from the Debug dogfood
# product: the daily channel has its own stable identity and must never
# replace the existing PR artifact.
# A Blacksmith VM keeps no cache between jobs, so its DEV compile's Xcode compilation cache
# rides Blacksmith's own actions/cache, served next to the runner, as classic's nightly does
# (Leo, 2026-10-26: "just give them the cache"). The newest entry under the key's prefix
# restores; a mini keeps its cache on disk and skips these (scripts/cmux-next/dev-vm-cas-key.sh).
```

## `jobs.cmux-scheme-compile.steps[Compile the cmux NEXT DEV Release app].env.CMUX_NEXT_BROWSER_DATA_IMPORT`

Above `CMUX_NEXT_BROWSER_DATA_IMPORT: full`:

```text
# The DEV app is the tip app (Leo, 2026-10-24), so it builds the
# browser-data import as published nightly-next builds do (nightly.yml
# NIGHTLY_NEXT_BROWSER_DATA_IMPORT; Apple accepted it in run 42176643049,
# cx-f58x). `compiled-out` builds it out again; this step runs no proof
# that could hold the DEV zip (#25050).
```

## `jobs.cmux-scheme-compile.steps[Compile the cmux NEXT DEV Release app].env.CMUX_NEXT_COMPILATION_CACHE`

Above `CMUX_NEXT_COMPILATION_CACHE: ${{ vars.CMUX_NEXT_DEV_COMPILATION_CACHE || '1' }}`:

```text
# The DEV app's warm state is the host's own content-addressed Xcode
# compilation cache (no kept build products, no remote store:
# scripts/cmux-next/lib/compilation-cache.sh), built per file with -O
# (singlefile, Xcode's "Incremental") so a one-file change replays
# every other file. auto (compile-dev-release.sh) compiles whole-module instead
# when the build has no host cache to replay (lock busy, cache off, not a mini).
# Repo variables switch each back: CMUX_NEXT_DEV_COMPILATION_CACHE=0,
# CMUX_NEXT_DEV_SWIFT_COMPILATION_MODE=wholemodule (or singlefile, everywhere).
```

## `jobs.cmux-scheme-compile.steps[Compile the cmux NEXT DEV Release app].env.CMUX_NEXT_DEV_VM_CACHE`

Above `CMUX_NEXT_DEV_VM_CACHE: ${{ steps.vm-cas-restore.outcome == 'success' && '1' || '' }}`:

```text
# A miss is a restore that succeeded (singlefile fills the line); a failed restore
# compiles as before, whole-module with no cache.
```

## `jobs.cmux-scheme-compile.steps[Save the DEV compile cache (Blacksmith)]`

Above `- name: Save the DEV compile cache (Blacksmith)`:

```text
# The compile already pruned it to its bound (or dropped it past 6 GiB: lib/compilation-cache.sh).
```

## `jobs.cmux-scheme-compile.steps[Save the DEV compile cache (Blacksmith)].if`

Above `if: steps.vm-cas-restore.outcome == 'success' && steps.compile-cmux-next-dev-release.outcome == 'success'`:

```text
# Only a vm-mode (singlefile) build's cache: a whole-module one would replay nothing.
```

## `jobs.cmux-scheme-compile.steps[Record this host's cache for the next landing's placement]`

Above `- name: Record this host's cache for the next landing's placement`:

```text
# A host build moved this host's cache: the record the next landing's placement reads.
```

## `jobs.cmux-scheme-compile.steps[Record this host's cache for the next landing's placement].if`

Above `if: steps.compile-cmux-next-dev-release.outcome == 'success' && (inputs.same_tree_sha == '' || inputs.same_tree_sha == github.sha)`:

```text
# A same-tree dispatch compiles inputs.same_tree_sha, not its run's head_sha (the record's commit).
```

## `jobs.cmux-scheme-compile.steps[Record the DEV Release app under its input key]`

Above `- name: Record the DEV Release app under its input key`:

```text
# The record a later run on the same inputs looks up (dev_release_product_reuse.py lookup):
# this run's product artifact, its SHA-256 and where the bytes were compiled (provenance).
```

## `jobs.cmux-scheme-compile.steps[Record the DEV Release app under its input key].env.SWIFT_MODE`

Above `SWIFT_MODE: ${{ steps.dev-product.outputs.hit == 'true' && steps.dev-product.outputs.swift_mode || steps.compile-cmux-next-dev-release.outputs.swift_mode }}`:

```text
# Reporting only (the key keeps the requested mode): what `auto` resolved to, the reused source's on a hit.
```

## `jobs.cmux-scheme-compile.steps[Upload the DEV Release app record].with.retention-days`

Above `retention-days: 2`:

```text
# As long as the product artifact it names.
```

## `jobs.cmux-scheme-compile.steps[Crash ends the app]`

Above `- name: Crash ends the app`:

```text
# A crash ends the app, never freezes it (2026-10-20 NIGHTLY freezes): with
# Sentry on, an uncaught exception must end the process within 8 s and a
# crash path that blocks must end within the crash deadline. The step
# does not fail this job; the crash-ends-app job reports it.
```

## `jobs.cmux-scheme-compile.steps[Package the trusted cmux-next dogfood artifact]`

Above `- name: Package the trusted cmux-next dogfood artifact`:

```text
# The default-branch publisher consumes the exact app produced by this
# job.  Keep the upload limited to same-repository member PRs carrying
# the existing dev-build label; the publisher repeats this trust check
# before it writes the immutable R2 object or comments on the PR.
```

## `jobs.cmux-scheme-compile.steps[Package the trusted cmux-next dogfood artifact].if`

Above `if: ${{ always() && ((github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next') || (github.event_name == 'pull_request' && github.event.pull_...`:

```text
# Keep packaging independent of any earlier step's failure. The
# app-producing compile is the admission boundary; unrelated checks
# and tests are separate jobs and must not suppress this artifact.
```

## `jobs.cmux-scheme-compile.steps[Capture the fleet build's REF]`

Above `- name: Capture the fleet build's REF`:

```text
# Last, so nothing in this job waits for it; bounded so it cannot reach the job's limit or hold
# the push compile slot long (a capture is a few minutes, about once a day). Only a host-mode build (one tree and DerivedData
# per host, the paths every mini shares) is captured, from the snapshot compile-dev-release.sh
# cloned while it held the host lock (another build may own the host tree by now). The packs go to the build fleet's
# private store; the manifest artifact names their sizes and sha256 only.
```

## `jobs.cmux-scheme-compile.steps[Capture the fleet build's REF].env.HYBRID_REF_SETTINGS`

Above `HYBRID_REF_SETTINGS: |`:

```text
# The compile step's build-line settings, one NAME=VALUE a line (not as env: only the
# compile step may carry them).
```

## `jobs.crash-ends-app`

Above `crash-ends-app:`:

```text
# The crash gate runs in cmux-scheme-compile on the app that job built. This
# job is its check: red when a crash froze the app instead of ending it.
```

## `jobs.crash-ends-app.steps[Report the same-tree result on the tested commit]`

Above `- name: Report the same-tree result on the tested commit`:

```text
# The post-merge backstop: every feat-cmux-next push runs its push tiers (a
# superseded push skips its Mac jobs, so a burst of merges is checked once,
# at its newest commit). When a check job fails, this comments on each pull
# request merged since that job last passed on a push, so the owning lane
# fixes forward (scripts/ci/cmux_next_push_attribution.py). It reads the
# Actions and pulls APIs; no branch code runs.

    # Same-tree mode: the result goes on the commit the run was for (a push,
    # or the pull request head), whichever ref the dispatch ran on.
```

## `jobs.dev-landing-place`

Above `dev-landing-place:`:

```text
# GITHUB_TOKEN workflow_dispatch does not emit workflow_run, so hand the
# exact successful DEV artifact to the publisher here instead of waiting for
# the cron dispatcher. The dispatcher remains the retry/backstop for a lost
# or failed handoff.
# !cancelled(): without a status function the implicit success() also reads
# every job upstream of cmux-scheme-compile, and a DEV run always skips some
# (dev-daily-tree-wait when the tree was ready), so this job was skipped on
# every run and the publisher waited for the next cron tick (source run
# 40124390153, 2026-10-24). The result check below still requires the compile.
# A same-tree DEV run is handed over only when it ran on the commit it built:
# the publisher requires the run's head_sha to be the SHA in its name.
# The handoff spends no GITHUB_TOKEN budget: every workflow in the repository
# shares that one installation budget an hour, and it was spent by the time
# each DEV compile finished on 2026-10-26 (source runs 40280000359,
# 40298830622, 40306882038 failed with "API rate limit exceeded for
# installation"), so the five-minute dispatcher, on the same budget, handed
# them over only after the reset, 12 to 46 minutes later. The
# manaflow-glaeda-route App this workflow already mints for runner placement
# has its own budget and the installation's actions: write; GITHUB_TOKEN,
# waiting through a rate limit as scripts/ci/gh_budget_wait.sh does (#25434),
# is the fallback when the App token cannot be minted or its dispatch fails.
# Every feat-cmux-next landing compiles the cmux NEXT DEV Release app at once, instead of
# waiting for main's DEV dispatcher (Leo, 2026-10-26: "you can just not have 93 commit caps if
# you're just doing it more often"): each compile starts from a cache at most a landing or two
# behind, and records its app under the whole-app reuse key (dev_release_product_reuse.py), so
# the DEV run the dispatcher later starts for that commit reuses it instead of compiling.
# Placement follows the routing order (scripts/ci/dev_landing_place.py): the free owned Mac
# whose host tree last compiled the nearest commit (its cmux-next-dev-cas-holder-<host>
# record), else any free owned Mac. With none free for about two minutes there is no landing
# compile: it only warms a host tree, which a Blacksmith macOS VM does not keep, so the DEV run
# compiles that commit on its own route.
# Each landing's compile is its own run's job and is never cancelled. The tree probe is the DEV
# run's: this commit's published cmux-tui tree, else the newest published one.
# vars.CMUX_NEXT_DEV_LANDING_COMPILE=0 turns both jobs off.
```

## `jobs.dev-landing-compile.environment`

Above `environment: ${{ vars.CMUX_NEXT_DEV_CAS_URL != '' && 'next-dev-cas' || '' }}`:

```text
# The fleet-shared compile cache (scripts/cmux-next/dev_cas_seed.py) is on once
# vars.CMUX_NEXT_DEV_CAS_URL names its store. Its token lives in next-dev-cas, an
# environment whose deployment branch is feat-cmux-next only; this job runs only on a
# feat-cmux-next push.
```

## `jobs.dev-landing-compile.env.BASH_ENV`

Above `BASH_ENV: ""`:

```text
# scripts/install-rust-ci.sh appends to a set BASH_ENV; keep it unset here (scripts/ci/api_call_log/env.sh).
```

## `jobs.dev-landing-compile.env.CMUX_NEXT_RUNNER`

Above `CMUX_NEXT_RUNNER: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || needs.dev-landing-place.outputs.runner_label || (github.event_name == 'pull_r...`:

```text
# The placed label's first entry (a glaeda-* label means a mini).
```

## `jobs.dev-landing-compile.steps[Look up the DEV Release app compiled on the same inputs]`

Above `- name: Look up the DEV Release app compiled on the same inputs`:

```text
# The same key and lookup as cmux-scheme-compile's (a DEV run that compiled these inputs first).
```

## `jobs.dev-landing-compile.steps[Compile the cmux NEXT DEV Release app].env.CMUX_NEXT_DEV_CAS_URL`

Above `CMUX_NEXT_DEV_CAS_URL: ${{ vars.CMUX_NEXT_DEV_CAS_URL }}`:

```text
# The shared compile cache: compile-dev-release.sh hands the tokens to the seed restore
# alone and unsets them before the build.
```

## `jobs.dev-landing-compile.steps[Publish the compile cache seed]`

Above `- name: Publish the compile cache seed`:

```text
# A host build packed its compile cache: put it in the shared store and record its digest
# for the next landings' seed restore (dev_cas_seed.py). Never fails the landing.
```

## `jobs.dev-landing-compile.steps[Record the DEV Release app under its input key].env.SWIFT_MODE`

Above `SWIFT_MODE: ${{ steps.dev-product.outputs.hit == 'true' && steps.dev-product.outputs.swift_mode || steps.compile.outputs.swift_mode }}`:

```text
# Reporting only (the key keeps the requested mode): what `auto` resolved to, the reused source's on a hit.
```

## `jobs.dev-landing-compile.steps[Report the landing compile]`

Above `- name: Report the landing compile`:

```text
# Where this landing compiled and how far its cache was: the host, the commit the cache
# last held, the gap, and the overflow. A host build leaves the record the next
# landing's placement reads (cmux-next-dev-cas-holder-<host>).
```

## `jobs.request-cmux-next-dev-publish.environment`

Above `environment:`:

```text
# The App key is a repository secret; this is the credential-free environment
# macos-placement mints the same App's token under (test_supplychain_security.py).
```

## `jobs.request-cmux-next-dev-publish.timeout-minutes`

Above `timeout-minutes: 70`:

```text
# The GITHUB_TOKEN fallback may wait up to an hour for the budget's reset.
```

## `jobs.request-cmux-next-dev-publish.steps[Record source queue and handoff receipt]`

Above `- name: Record source queue and handoff receipt`:

```text
# Evidence only: a refused read must never hold up the dispatch below.
```

## `jobs.request-cmux-next-dev-publish.steps[Dispatch with GITHUB_TOKEN, waiting through a rate limit]`

Above `- name: Dispatch with GITHUB_TOKEN, waiting through a rate limit`:

```text
# The fallback holds only GITHUB_TOKEN. A refusal for the rate limit waits
# for the budget's reset and tries again, at most 3 tries and an hour of
# waiting in all (the bounded wait of scripts/ci/gh_budget_wait.sh, #25434);
# a refused request did nothing on GitHub's side, so the retry is safe.
```

## `jobs.pr-red-checks`

Above `pr-red-checks:`:

```text
# The checks job's red sub-checks join the PR's red-checks line (pr-red-checks-comment.yml), each
# compared with the base's run: ci.yml and cmux-next-guards.yml call it after their own checks.
```

## `jobs.push-attribution.if`

Above `if: ${{ failure() && inputs.dev_daily != true && (github.event_name == 'push' || inputs.same_tree_origin == 'push' || inputs.base_tier == true) && github.ref...`:

```text
# Also a same-tree mode run for a feat-cmux-next push: the tree jobs of a
# push whose tree was published after its run probed it run there. And a
# base tier run (or its same-tree run): the range since the base tier last
# passed holds the landings it covers.
```

## `jobs.push-attribution.steps[Fetch the branch's recent commits]`

Above `- name: Fetch the branch's recent commits`:

```text
# The range and its pull requests come from first-parent history (commits only, no
# trees), not the compare and commits/{sha}/pulls APIs; a failed fetch leaves the API path.
```

## `jobs.push-attribution.steps[Mint the cmux-bot read token]`

Above `- name: Mint the cmux-bot read token`:

```text
# The Actions reads (about 40 runs' jobs) use a cmux-bot token, off the repository
# token's hourly budget; this job runs only for feat-cmux-next pushes and dispatches.
# Comments stay on the workflow token. A failed mint leaves every read on it.
```

## `jobs.release-compile-revert`

Above `release-compile-revert:`:

```text
# The base-break rule, automated: a feat-cmux-next push whose Mac Release compile failed in its
# compile step (pull requests get the fleet compile at -Onone, so -O codegen and the final app link
# are first compiled here) opens the revert of the one merge since the compile last passed,
# within minutes. Several merges in the range, or a red older than the scanned runs, open
# nothing (push attribution comments on each). The revert is pushed and opened by the
# manaflow-glaeda-route App so its own CI runs; it lands through the normal review path.
```

## `jobs.release-compile-revert.environment`

Above `environment:`:

```text
# The environment macos-placement already takes on a push for the same App key; push-only here.
```

## `jobs.release-compile-revert.steps[uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2]`

Above `- uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2`:

```text
# The newest tip, so the revert applies to what is there now.
```

## `jobs.compile-status`

Above `compile-status:`:

```text
# The pull request's Release compile gate: the commit status cmux-next/compile on the exact
# head. The build fleet's controller compiles every feat-cmux-next head and same-repository PR
# head (SwiftPM Release at -Onone); this job reads that one result and publishes it.
# The controller holds no GitHub key and posts nothing: the status comes only from here, with
# a cmux-bot token (statuses: write) minted from the repository secret. Any other route that
# compiles the head (a Blacksmith job of this repository) posts the same context with the
# same mapping.
#
# Mapping, fail closed: pass is success; fail is failure with the compile log as its link;
# unavailable, no result by the deadline, a result for another sha, repo, configuration or
# recipe version, or a mint or post error is failure. The wait blocks on the endpoint
# (`wait=N` returns at a terminal state, else at its deadline) under one overall deadline of
# 40 min from the job's start, each read hard-bounded by `timeout` to what is left; a missing result (404) is
# retried by curl itself, 30 s apart, inside that bound. The terminal post comes before the
# App token's hour ends (it is minted just before the wait). Nothing sleeps in a loop here.
#
# Forks get no secret and no status: the job does not run, the gate is missing, and a missing
# gate does not admit. The job checks nothing out: no pull request code runs beside the token.
```

## `jobs.compile-status.steps[Wait for the fleet Release compile and publish cmux-next/compile].env.PR`

Above `PR: ${{ github.event.pull_request.number }}`:

```text
# The pull request this head belongs to (empty on a push). A head whose run the controller never
# saw has no check; a read that names its pull request has the controller queue one
# (cmuxterm-hq#5571), instead of this step waiting 40 minutes for a check that never comes.
```
