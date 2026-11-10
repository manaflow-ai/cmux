# cmux-next.yml: the longer notes

GitHub refuses a workflow file over 500 KB (512,000 bytes) before any job starts, so every pull request
and push loses the whole workflow (2026-11-10: #40348 took the file to 512,883 bytes). The longest
explanations live here; the workflow keeps a `# Why: ...#note-N` line where each stood.
`tests/test_ci_workflow_file_size.py` holds every workflow under the limit with room to spare.

## note-1

Above `pr-quiet-period` in `.github/workflows/cmux-next.yml`.

A pull request's run waits until the PR has had no push for about 5 minutes before any Mac
job starts. The run's group cancels in progress on a newer push, so a second push inside the
window cancels a run before it takes a Mac. In the 82 minutes to 2026-11-05T08:36Z, 17 of 100
PR runs were cancelled by the PR's next push (4 of them under 5 minutes after the first, the
rest after 5 to 36 minutes of checks and compiles).
Only macos-placement waits for it, and every Mac job (and every Mac job's build-fleet client)
needs macos-placement, so the Mac jobs are placed from a reading taken after the wait: an idle
runner that placement finds is still idle when the job it placed starts. The Linux work starts
at once: portable-placement, path_route, checks, fast-tier-cargo, web-bundles and the build
fleet's app compile (app-compile-placement, app-compile-fleet). Leo, 2026-11-08, choosing
"the Linux checks start at once and only the Mac jobs wait": "yeah". A superseded head spends
3 to 8 Linux runner-minutes before the newer push cancels its run (41% of runs). It sleeps on the
smallest Blacksmith Linux size (the linux_2 pool), so it holds no fleet runner or mini. It is
not on hosted Ubuntu: the org runs at most 20 hosted jobs at once, and on 2026-11-07 its
2,103 sleeps held 6 of them on average (8,400 of 21,600 hosted minutes), so the routers and
report steps that must start fast queued 1.5-2 min at the median through the busy hours. Its
own start costs nothing on any runner: the sleep ends at the push time plus the window, so a
queued start sleeps that much less. A re-run (attempt 2 and later), a `leo-named-fix` PR (landing.md: those land
with no wait) and vars.CI_PR_QUIET_PERIOD_SECONDS = '0' skip it; pushes and dispatches never
run it. Leo, 2026-11-05: "i meant can you do all of htem".

## note-2

Above `checks: steps` in `.github/workflows/cmux-next.yml`.

Pull requests into feat-cmux-next run the cheap static checks, and so does
every feat-cmux-next push: gh-merge-green excuses a PR's red lint only when
the base's latest push run prints every finding too, so a base red no longer
refuses every PR (2026-10-19). The size
cap and crash ratchet are cadence checks: they run on pushes and on the
full-ci batched integration PR, not on every contributor PR. God files and types are warn-only
(Lawrence 2026-10-10): over the hard ceiling (GODFILES_WARN_SLACK: allowance
+ 20% of the budget, so a new type past 1200 lines) the step writes a
warning and passes. Other style ratchets warn under a hard ceiling and fail
over it: l10n style errors and custom scrollbars (by count).
A warning is ratchet debt: an annotation on the PR run (the issue-writing
ratchet-debt job was removed 2026-10-13: push runs skipped this job then,
and it never filed an issue). Concurrency, notification
centers and crash safety have no warning tier. Each ceiling is set on its
own step only: the script tests below expect every hit to fail.
Since 2026-10-19 (Leo) every structural, style, size and drift step named
in the aggregate's STYLE_CHECKS only warns while CMUX_NEXT_STYLE_GUARDS
(workflow env) is `warn`; the correctness and safety steps still fail.

## note-3

Above `checks: Check the app FFI pin` in `.github/workflows/cmux-next.yml`.

Package.swift links the app FFI from one pinned release; the pin must
match the FFI sources (every crate cmux-app-ffi reaches through Cargo
path dependencies) and the release must be built from them. Here on
Linux it runs on every push and pull request: in swift test a newer
push replaced the waiting job, so tip runs rarely reached it.

On a pull request the base's copy of the check and of its pin reader
(the merge commit's first parent), extracted outside the checkout,
judges a fresh worktree of the merge commit (--tree), with only
PATH=/usr/bin:/bin, an empty HOME and the git switches below in its
environment. The steps above ran the pull request's code, which could
rewrite the checkout's files on disk (the check, its reader, the
manifest, a Cargo.toml), change PATH and the environment, or write
dotfiles in HOME (a ~/.gitconfig hooks path, a ~/.curlrc) and git
hooks in .git/hooks; base_red_excuse.py trusts this verdict for a
pull request whose diff leaves the check alone. So no global or
system git config is read, git runs no hook and no fsmonitor, and
the base is the merge commit's first parent as its object records
it (no graft). BASH_ENV is empty here, so the checkout's
scripts/ci/api_call_log/env.sh is not sourced either.

## note-4

Above `fast-tier-fleet` in `.github/workflows/cmux-next.yml`.

The fast tier as a thin build-fleet client, for when every owned and
Blacksmith macOS label it could take is full or dead, or only a Blacksmith
macOS label (a cold build) took it: macos-placement then
lists it in fleet_jobs (next_macos_cascade.place(), FLEET_CLIENT_JOBS) and
this job hands the swift entries of scripts/cmux-next/fast-tier.json to the
fleet (`cmux-ci run` of package-test-lane.sh's suite mode, one step per
package) instead of waiting for a Mac. The gateway runner runs nothing of
the commit: no checkout, no action, no token, no secret, only the client
(the checks-workflow guard GatewayRunsOnlyTheFleetClient).
It tests the exact commit fast-tier builds (github.sha: a pull request's merge commit) and checks
that every fleet step it reads tested that commit: no verdict, or a step at
another commit, fails it and is never a pass. fast-tier keeps the check
name and reports this job's verdict from a 2 vCPU Linux runner.
A step still queued when the client stops waiting (exit 75; the step keeps its place, as the
controller never cancels one for waiting) gives the verdict `queued`: this job passes with a
warning and fast-tier runs the Swift suites itself on Blacksmith macOS, the cascade's next route,
so the PR gets a verdict in the same attempt (cmux#38346: both steps queued past 600 s, then
passed 40 minutes later, and the PR went red on the wait).

## note-5

Above `fast-tier: runs-on` in `.github/workflows/cmux-next.yml`.

vars.CI_FAST_LANE_RUNNER is the fast tier's own reserved runner label
(glaeda-fast-<class>-xcode-26.6). The tier takes it only through the
placement's fast_runner, set while one of its runners is idle, and only on
attempt 1: a re-run reuses attempt 1's placement, whose idle reading is stale.
With no fast runner idle, fast_runner names an idle light side runner instead
(glaeda-side-light-xcode-26.6, side_lane_placement.light_fast_route(); Leo, 2026-11-08:
"the light minis are largely idling"), never while a nightly job waits on the light minis.
Otherwise the tier takes the current cascade allocation. With every
alternative excluded, deferred_runner preserves the base owned queue;
it never bypasses Blacksmith outage/nightly exclusions or skips tests.
fast-tier-fleet replaces that deferred case when placement lists the tier for the fleet.
When fast-tier-fleet ran (macos-placement found every macOS label it could take full or
dead, or only a Blacksmith macOS label took the tier), this job keeps its check name and exit code but runs on fleet Linux (vars.LINUX_RUNNER
when it names our own runner, as portable-placement does), else a 2 vCPU Blacksmith Linux runner, and
only reports that job's verdict: every other step is off (CMUX_FAST_TIER_FLEET, or it reads a
step that is). fast_runner is empty then: placement lists only a tier no idle runner took.
When the client hands the tier back (verdict `queued`: a fleet step still queued past its wait),
the tier runs in full, with 35 minutes, where fast-tier-handback-placement's fresh reading sends it
(an idle owned Mac, else Blacksmith 6 vCPU unless excluded, else the owned route), else on
Blacksmith 6 vCPU.

## note-6

Above `release-compile: continue-on-error` in `.github/workflows/cmux-next.yml`.

The base's compile check: a current feat-cmux-next push compiles once its
preflight sees it is still the tip. Superseded pushes skip before queueing,
while a compile that has started gets its own run group and cannot be
evicted by a newer push. This leaves one running compile and the newest
current tip queued without GitHub's one-pending-run eviction.
Release runs on every base push, next-batch/* push and dispatch, and on a
PR the native tier reaches with full-ci. #22325 ran it on every
same-repository PR; on 2026-10-21 (~20:10Z) 76 of the ~350 queued Mac jobs
were this compile, so a same-repository PR compiles its head on the build
fleet (app-compile-fleet) and runs this only with full-ci or when the
fleet gave no verdict; its merge is compiled by the base push
(push-attribution names it on a red).
A fork PR runs it with full-ci, or when it changes any .swift
file under Packages/macOS/CmuxNext/ (Sources or Tests, whatever else it
changes; path_route's cmuxnext_swift). A Release-only
optimizer crash (cx-ebm.59.5: EarlyPerfInliner on a main-actor generic
class's isolated deinit) reached the base through such a PR, because the
Debug fast tier and Debug `swift build` cannot see it.
When macos-placement skips (a fork PR), `!cancelled()` keeps this job
running and runs-on below takes the shared fallback route.

## note-7

Above `request-nightly-next` in `.github/workflows/cmux-next.yml`.

A green Release compile on a feat-cmux-next push asks main's nightly.yml to
promote this commit to the protected `nightly-next` branch. The fast-check gate
(release-compile-fast-admission) requests in its own job, once green; the Mac
job below requests only when it had no verdict. (A separate helper job after
the fast gate repeated the same request at the same commit: dropped.) Main's promote job refuses a head whose push run has no successful
Release compile, so each request waits for its own gate and for nothing else.
Since 2026-10-28 this request only reports: request-nightly-next.sh dispatches
the promotion only from main's 30-minute nightly-next-tick.yml
(NIGHTLY_NEXT_PROMOTE=1), so a burst of landings starts one nightly build,
not one each (six ran at once). Only main's job, in the `release` environment,
holds the release App key and checks this push run's Release compile; this
job only needs actions: write to request it.
The request also waits for this commit's cmux-tui tree: the nightly builds
the tip with the tip's own nightly.yml and daemon only when that tree is
published (a tip with a building tree failed runs 37767816879 and
37769010617). When the tree publishes after this job,
cmux-tui-artifacts.yml's request-nightly-next asks instead
(scripts/cmux-next/request-nightly-next.sh, tested by
scripts/cmux-next/tests/request-nightly-next.test.sh).

## note-8

Above `dev-daily-place` in `.github/workflows/cmux-next.yml`.

A DEV daily's Release compile (cmux-scheme-compile) goes to the idle owned Mac whose host tree last
compiled the nearest commit (scripts/ci/dev_landing_place.py with FRESH_LABEL, place_daily()). From one
runner listing: a host with any busy runner is occupied (whatever holds its host lock runs there); a
pick claims a host only when its label resolves to exactly one idle runner (a DEV slot or root runner by
its static label, or the one idle DEV slot), scored by the host's cmux-next-dev-cas-holder-<host>
record. Otherwise the shared DEV slot label, then the side label, at once: it never waits. With nothing
owned idle it prints no route and the compile keeps macos-placement's. A warm host compiles in about
130 s of xcodebuild, a host with no tree in about 808 s (2026-10-28, 15 DEV compiles, 4 warm).
vars.CMUX_NEXT_DEV_COMPILE_AFFINITY=0 turns it off.
It runs only when cmux-scheme-compile will (the same tree condition), so it never waits for a skipped compile.
It places only a run whose DEV Release app gets built: it carries that step's dispatch condition
(compile-cmux-next-dev-release's `if`) word for word, so a daily from another branch or for a stale
commit never holds a Mac. tests/test_cmux_next_dev_landing_workflow.py keeps the two the same.

## note-9

Above `dev-landing-place` in `.github/workflows/cmux-next.yml`.

GITHUB_TOKEN workflow_dispatch does not emit workflow_run, so hand the
exact successful DEV artifact to the publisher here instead of waiting for
the cron dispatcher. The dispatcher remains the retry/backstop for a lost
or failed handoff.
!cancelled(): without a status function the implicit success() also reads
every job upstream of cmux-scheme-compile, and a DEV run always skips some
(dev-daily-tree-wait when the tree was ready), so this job was skipped on
every run and the publisher waited for the next cron tick (source run
40124390153, 2026-10-24). The result check below still requires the compile.
A same-tree DEV run is handed over only when it ran on the commit it built:
the publisher requires the run's head_sha to be the SHA in its name.
The handoff spends no GITHUB_TOKEN budget: every workflow in the repository
shares that one installation budget an hour, and it was spent by the time
each DEV compile finished on 2026-10-26 (source runs 40280000359,
40298830622, 40306882038 failed with "API rate limit exceeded for
installation"), so the five-minute dispatcher, on the same budget, handed
them over only after the reset, 12 to 46 minutes later. The
manaflow-glaeda-route App this workflow already mints for runner placement
has its own budget and the installation's actions: write; GITHUB_TOKEN,
waiting through a rate limit as scripts/ci/gh_budget_wait.sh does (#25434),
is the fallback when the App token cannot be minted or its dispatch fails.
Every feat-cmux-next landing compiles the cmux NEXT DEV Release app at once, instead of
waiting for main's DEV dispatcher (Leo, 2026-10-26: "you can just not have 93 commit caps if
you're just doing it more often"): each compile starts from a cache at most a landing or two
behind, and records its app under the whole-app reuse key (dev_release_product_reuse.py), so
the DEV run the dispatcher later starts for that commit reuses it instead of compiling.
Placement follows the routing order (scripts/ci/dev_landing_place.py): the free owned Mac
whose host tree last compiled the nearest commit (its cmux-next-dev-cas-holder-<host>
record), else any free owned Mac. With none free for about two minutes there is no landing
compile: it only warms a host tree, which a Blacksmith macOS VM does not keep, so the DEV run
compiles that commit on its own route.
Each landing's compile is its own run's job and is never cancelled. The tree probe is the DEV
run's: this commit's published cmux-tui tree, else the newest published one.
vars.CMUX_NEXT_DEV_LANDING_COMPILE=0 turns both jobs off.

## note-10

Above `compile-status` in `.github/workflows/cmux-next.yml`.

The pull request's Release compile gate: the commit status cmux-next/compile on the exact
head. The build fleet's controller compiles every feat-cmux-next head and same-repository PR
head (SwiftPM Release at -Onone); this job reads that one result and publishes it.
The controller holds no GitHub key and posts nothing: the status comes only from here, with
a cmux-bot token (statuses: write) minted from the repository secret. Any other route that
compiles the head (a Blacksmith job of this repository) posts the same context with the
same mapping.

Mapping, fail closed: pass is success; fail is failure with the compile log as its link;
unavailable, no result by the deadline, a result for another sha, repo, configuration or
recipe version, or a mint or post error is failure. The wait blocks on the endpoint
(`wait=N` returns at a terminal state, else at its deadline) under one overall deadline of
40 min from the job's start, each read hard-bounded by `timeout` to what is left; a missing result (404) is
retried by curl itself, 30 s apart, inside that bound. The terminal post comes before the
App token's hour ends (it is minted just before the wait). Nothing sleeps in a loop here.

Forks get no secret and no status: the job does not run, the gate is missing, and a missing
gate does not admit. The job checks nothing out: no pull request code runs beside the token.

## note-11

Above `push-head-preflight` in `.github/workflows/cmux-next.yml`.

pushes run the Release compile, the app scheme compile and the nightly-next
request. checks, web bundles, swift test, daemon tests and generated files run
on workflow_dispatch (gh workflow run cmux-next.yml --ref <ref>). A same-repository pull
request into feat-cmux-next runs the Mac tiers its paths reach (#22303), but the Release
compile and the app scheme compile only with full-ci (2026-10-21). The fast-check
path keeps the Mac tiers from occupying a scarce owned lane;
macos-placement sends compatible work to free capacity when no owned runner is idle.
A push can sit in the owned-pool queue after newer commits have landed.
Resolve the branch head before any Mac job requests a runner.
The lookup fails open so the current head still gets its compile and
nightly-next promotion. Keep the run-id concurrency group below: rescue
reruns of an older push must not cancel the newest pending run.

## note-12

Above `path_route: generated_host` in `.github/workflows/cmux-next.yml`.

The one job that checks the generated files on its own package build (HQ#4724: skip compiles
that add no signal). daemon-test on a push it runs on (a ready tree), else swift-test where it
runs and builds (its targets; on a pull request only with full-ci), else daemon-test where it
runs, else the generated-files job's own build. swift-test and daemon-test then never compete with a third
`swift build --build-tests`; generated-verdict gives the folded verdict its own check.
A base tier run (inputs.base_tier) checks them on the generated-files job itself: its standalone
`cmux-next generated files` verdict is the base verdict a pull request's is compared with.

## note-13

Above `path_route: CMUX_TUI_TREE_PUBLISHER_SHA` in `.github/workflows/cmux-next.yml`.

Push runs use the artifacts run already started by that protected
branch. Pull requests may fall back to the base tree; a missing own
tree fails closed because this checked-out revision cannot dispatch.
A scheduled DEV run likewise owns its exact SHA without mutation
authority; only trusted controls may start a publisher. Its probe
looks once (read-only) for its push's artifacts run or a same-tree
run and defers to it; dev-daily-tree-wait then waits.

## note-14

Above `dev-daily-tree-wait` in `.github/workflows/cmux-next.yml`.

for. When its cmux-tui tree is cold, path routing defers without acquiring
mutation authority; a trusted publisher may still satisfy the wait. This
waits on Linux for the tree,
then cmux-scheme-compile builds the DEV app in this run
(scripts/cmux-next/wait-dev-daily-tree.sh, tested by
scripts/cmux-next/tests/wait-dev-daily-tree.test.sh).

## note-15

Above `macos-placement: needs` in `.github/workflows/cmux-next.yml`.

After the pull request quiet period (skipped outside pull requests, hence !cancelled()): every Mac
job needs this job, so none starts before the wait ends, and each is placed from a reading taken
after it. app-compile-placement already gave the PR's app compile its gateway runner, which this
reading then sees busy.

## note-16

Above `macos-placement: env` in `.github/workflows/cmux-next.yml`.

The workflow's CMUX_NEXT_SIDE_ROUTE, with the rescue's full re-run (attempt 2 by
github-actions[bot]) placed too: its steps read what is free when it starts, and the
cascade jobs take a free Blacksmith slot instead of the end of the side queue they waited
in (next_macos_cascade.bot_rerun()). Only this job's steps read this copy.

## note-17

Above `macos-placement: fleet_jobs` in `.github/workflows/cmux-next.yml`.

The FLEET_CLIENT_JOBS that no owned or Blacksmith macOS label can take now (every one full or
dead, next_macos_cascade.place()), space-delimited like blacksmith_6_jobs: each runs as a thin
cmux-ci client on gateway_runner (<job>-fleet), and the job itself only reports its verdict.

## note-18

Above `macos-placement: gateway_runner` in `.github/workflows/cmux-next.yml`.

vars.CI_COMPILE_CHECK_GATEWAY, or a wider class of it, while it has an idle runner for
each gateway job, else empty (side_lane_placement.gateway_route()); gateway_attempt is
the run attempt that judged it. A gateway job runs only on a reading from its own
attempt; with none (a re-run, a skipped or older placement) it skips and its Mac
fallback runs, never a queue nobody saw free.

## note-19

Above `macos-placement: placed_attempt` in `.github/workflows/cmux-next.yml`.

The attempt this placement ran in. A re-run of failed jobs carries the placement job, and its
outputs, from an earlier attempt: a job output is evaluated when its job runs, so this stays that
attempt's number. Every Mac job reads blacksmith_12_jobs, blacksmith_6_jobs and
retry_runner only while this equals its own run_attempt; a carried reading is stale (run
40398277457, 2026-10-26: attempt 2 took blacksmith-6vcpu-macos-26 on a reading 39 minutes old and
waited 55 minutes for a runner), so the job takes the owned label instead.

## note-20

Above `macos-placement: session_runner` in `.github/workflows/cmux-next.yml`.

daemon-test and generated-files need a logged-in session, not the
console gui token: the session label (glaeda#1530) while an online
runner carries it and it has room (role_room(): not while the
janitor finds it unserved, cmux#24295), else gui_runner. Empty from a
trusted base whose placement predates it, so those jobs then read
gui_runner. Their literal last owned leg is the gui label, never the
session label: no placement judged it (tests/test_ci_runs_on_fallback.py).

## note-21

Above `macos-placement: Place the macOS jobs` in `.github/workflows/cmux-next.yml`.

In priority order: the scheme compile keeps its DerivedData on a mini
(cold on Blacksmith), and only a mini compiles the CEF shim. A Release
compile no idle mini takes (on a feat-cmux-next push: no idle promotion
mini) takes a free Blacksmith slot (next_macos_cascade.py).

## note-22

Above `macos-placement: CASCADE_RUNS` in `.github/workflows/cmux-next.yml`.

The cascade's jobs that run on this route at all (next_macos_cascade.py):
not a job that path routing or the pull request's labels skip (a job
missing here only stays on the minis' queue). The fast tier is always
here; the placement drops it only while an idle runner carries
FAST_LABEL, which it then takes (fast_runner).

## note-23

Above `macos-placement: FRESH_LABEL` in `.github/workflows/cmux-next.yml`.

The freshness slot (glaeda#1628: one side instance on opted-in minis carries only this label;
glaeda#1636: its hook admits cmux-scheme-compile on a feat-cmux-next push or a dev_daily dispatch
and a push's release-compile, and while idle it keeps one feed compile's units from PR jobs),
taken while idle by the FRESH_JOBS that hook admits (FRESH_SLOT_JOBS).

## note-24

Above `macos-placement: FLEET_CLIENT_JOBS` in `.github/workflows/cmux-next.yml`.

The cascade jobs with a build-fleet client job (<job>-fleet, which runs only the cmux-ci client on
gateway_runner): with every macOS label full or dead, or when a Blacksmith macOS label took them
(a cold build there ran the fast tier out of its 20 minutes, cmux#38130), they are listed in
fleet_jobs instead, and the job itself only reports its client's verdict. A job joins only with its client
(GatewayRunsOnlyTheFleetClient). A listed job's client needs an idle gateway runner of its own
beyond GATEWAY_JOBS', or placement lists nothing (side_lane_placement.fleet_gateway()). swift-test
and daemon-test are not cascade jobs, so placement never lists them; daemon-test also needs the
same-tree cmux-tui daemon, which a fleet suite step reports as no result.

## note-25

Above `portable-placement` in `.github/workflows/cmux-next.yml`.

cmux-next checks' runner.
Jobs that need neither Linux nor Blacksmith take fleet Linux (vars.LINUX_RUNNER when it names our
own Linux runner), else a mini idle now with no nightly job waiting on its pool, else their
Blacksmith label (scripts/ci/portable_job_placement.py; Leo, 2026-10-31: "i mean the linux things
cant our minis just run them"). Every step fails open: no output keeps each job's Blacksmith route.
The placement code comes from the base branch, as macos-placement's does.
This bootstrap must start independently of the labels it validates: hosted Ubuntu on attempt 1,
then the measured paid retry route. Its consumers take live fleet capacity from its outputs.

## note-26

Above `checks: needs` in `.github/workflows/cmux-next.yml`.

feat-cmux-next pushes run it again (Leo, 2026-10-19; cx-g34i had dropped it): a direct push's
red shows on that push, and a pull request's red has a base run to be compared with.
Not in a base tier run: the push of its commit already ran it.
!cancelled(): a skipped or failed portable-placement (a fork, a re-run) leaves the Blacksmith route.

## note-27

Above `checks: Start the slow checks in the background` in `.github/workflows/cmux-next.yml`.

The slow independent checks run concurrently in the background, at most one per CPU, from here
on (one after another they took about 7 of the job's 8.4 min). Each of their steps below waits
for its own commands, prints their output and keeps its name, id and outcome. A `[step-id]`
line names the step the commands under it belong to; the longest commands start first.
Not here: "Pushed commits add no violations" deepens the clone and writes its step summary.

## note-28

Above `checks: UI font (the system font)` in `.github/workflows/cmux-next.yml`.

UI font (Lawrence 2026-11-07: "default fonts on cmux for everything should be macos default,
not inter"): the UI font is the macOS system font, no letter-spacing, nothing bundled
(schemas/type-scale/ui-font-pin.json pins it). Fails on another stack, letter-spacing on the
system font, a bundled Inter file, a webviews default stack that names Inter, or a pin change
with no `Font-order:` trailer. A pull request's own commits are fetched for the trailer, which
the pushed-commits step below then sees too.

## note-29

Above `checks: Script tests (pin-cmux-tui, embed-cef, ensure-cef store)` in `.github/workflows/cmux-next.yml`.

Behavior tests of the build scripts: pin-cmux-tui.sh fetch on a stale
--ref mirror and on a reused runner workspace, embed-cef.sh reaching
ensure-cef.sh under set -u, and ensure-cef.sh's controller artifact
store source. The run-check test covers the same-tree wait failing
fast when the artifacts run for its commit was cancelled or superseded.

## note-30

Above `checks: Prebuilt web bundles install and stamp` in `.github/workflows/cmux-next.yml`.

build-web-bundles.sh --from installs and stamps bundles built elsewhere. It and the key
inputs test ran last in the web-bundles job until 2026-10-20: a red there failed the job
that swift test, daemon tests and generated files wait on, so those tiers were skipped
(and a skipped tier reads as passing) on every pull request while it stayed red.

## note-31

Above `checks: Fail on any red check` in `.github/workflows/cmux-next.yml`.

STYLE_CHECKS are the structural, style, size and drift guards: while
CMUX_NEXT_STYLE_GUARDS is `warn` (workflow env) a red one is a warning
annotation and does not fail the job. A style check that never ran
(an empty outcome) still fails: that is a broken workflow, not a finding.

## note-32

Above `web-bundles` in `.github/workflows/cmux-next.yml`.

It waits for nothing: path routing probed the tree (tree_state=failed), or
an artifacts run that ended without publishing it dispatched same-tree mode
with same_tree_state=failed; that one first re-runs its commit's
artifacts run (cmux_tui_tree_takeover.py), red only if it can't.
A publication of the key starts the tree jobs (the marker stays). A ready
tree is reported green, so the tip has a verdict after a red one.
Builds the cmux-next web bundles once per source key (web-bundle-key.py --source) on
Linux and caches them; the Mac jobs restore them by that key instead of running bun.
A pull request builds them only for a routed tier that restores them; a DEV daily run
builds them for the commit its DEV Release compile restores them for.

## note-33

Above `swift-canary-fleet` in `.github/workflows/cmux-next.yml`.

CI_COMPILE_CHECK_GATEWAY variable set (a tailnet gateway runner label), a
same-repository run hands `cmux-ci compile-check --app` the commit; the
fleet compiles and links the app executable, which covers every
production target the app links (the canary's targets are production
targets only), and answers. The two production targets the app does not
link go straight to the Mac canary. A pass lets the
canary below report it from a small Linux runner instead of taking a Mac.
A red, an unavailable fleet or a timeout runs the Mac canary as before,
which prints the errors: this job never fails a run itself.

## note-34

Above `swift-canary-fleet: Compile-check CmuxNext on the build fleet` in `.github/workflows/cmux-next.yml`.

The gateway checks nothing out: the fleet fetches the commit the Mac
canary would build (github.sha: a pull request's merge commit, so a
head that breaks against the current base is still caught). A commit
the fleet cannot fetch is "no verdict", and the Mac canary runs.

## note-35

Above `app-compile-placement` in `.github/workflows/cmux-next.yml`.

and only the Mac jobs wait). app-compile-fleet's runner only hands the head to the build fleet, so it
does not wait for the PR quiet period; macos-placement, which places the Mac jobs, does, and reads the
runners again then. A side-light runner idle now takes it (side_lane_placement.app_compile_gateway(),
gateway_route()'s rule); with none, or on a re-run (attempt 2 and later: as macos-placement's
rerun_main(), no gateway), app-compile-fleet skips and the Mac Release compile cascades. Fails open:
a failed read or a trusted base that predates the mode writes nothing, which is "no gateway".

## note-36

Above `swift-canary` in `.github/workflows/cmux-next.yml`.

This uses the same placement and linked SwiftPM scratch as the other Mac
jobs, so a warm mini can answer in roughly 1-2 minutes. It deliberately
excludes the app host, package manifest, resources and toolchain inputs.
When swift-canary-fleet passed, the job keeps its name and conclusion but
runs on a 2 vCPU Linux runner and only reports that verdict.

## note-37

Above `fast-tier-handback-placement` in `.github/workflows/cmux-next.yml`.

the tier back (verdict `queued`: a fleet step still queued after the client's 20-minute wait),
macos-placement's reading is from the start of the run. This job reads the runners and Blacksmith's health
now: the tier takes its own idle label, an idle owned side runner (a warm build), Blacksmith 6 vCPU while
it is not full, under a declared outage, dead or stalled, and otherwise waits on the owned route. #38627's
review: an unconditional Blacksmith 6 vCPU queued on an excluded label with no verdict.
Fails open: an unread placement or a base script that predates it writes nothing, and the tier takes
Blacksmith 6 vCPU as #38627 sends it.

## note-38

Above `fast-tier` in `.github/workflows/cmux-next.yml`.

(scripts/cmux-next/fast-tier.json) on every feat-cmux-next PR and push,
whatever paths changed, without the gui token. Target: under 5 minutes
with the build. A fail-then-pass entry is FLAKY and fails the job: it is
never retried silently (fast-tier.py's flake policy). The registry is split
by kind: this Mac job builds and runs the Swift entries, and
fast-tier-cargo runs the cargo and script entries beside it, so the Mac no
longer builds cmux-tui (297-422 s) after CmuxNext.
A pull request whose change no fast-tier Swift entry builds or reads starts
no Mac fast tier: its result is the base's. That is every PR the router
sends to no Mac tier (only web or CI files), and one whose Mac tiers are
only the daemon or scheme compile (cmux-tui Rust, the app host), which the
package build cannot see (cmux_next_route.py fast_tier). The cargo half
still runs, and a route with no answer (a failed path_route) runs it as before.

## note-39

Above `fast-tier: timeout-minutes` in `.github/workflows/cmux-next.yml`.

A cold package build can exceed the 5-minute target; the job still runs
the entries so a cold mini reports, and the summary shows the time.
The fleet's `queued` hand-back always runs cold on Blacksmith 6 vCPU macOS, whose fast-tier p90 was
19.8 minutes (#38181's data), so it gets 35: a slow cold build still gives the verdict.

## note-40

Above `fast-tier: Fingerprint this job's inputs` in `.github/workflows/cmux-next.yml`.

With vars.CI_NEXT_JOB_REUSE, a pass on the same inputs stands for this run: the
steps below skip and the summary names the run that passed. The key
(scripts/ci/job_input_fingerprint.py) is the commit's full tree hash, this
workflow file's blob hash and the toolchain below; a missing toolchain value
gives no key. Not on a fork pull request, which could record a pass of its
own under any key.

## note-41

Above `fast-tier: Keep Swift package builds on this owned Mac` in `.github/workflows/cmux-next.yml`.

mini's shared roots (scripts/ci/owned_spm_scratch.py lease): a mirror of
this checkout at a path every runner slot shares, so the build the last
fast tier on any slot left is warm here. Its output `root` is where the
tier runs; with no root free it links this workspace's own kept build.
After Xcode selection, so its fingerprint uses the compiler of this job.

## note-42

Above `fast-tier: Record this pass for the same inputs` in `.github/workflows/cmux-next.yml`.

A pass records itself for the next run on the same inputs: an artifact named after
the key, which every pull request and the base can list (scripts/ci/job_reuse.py
takes only passes of this repository's own runs). Never from a fork pull request.
An uncached (no_reuse) run records too.

## note-43

Above `fast-tier-cargo: Fingerprint this job's inputs` in `.github/workflows/cmux-next.yml`.

With vars.CI_NEXT_JOB_REUSE, a pass on the same inputs stands for this run: the
steps below skip and the summary names the run that passed. The key
(scripts/ci/job_input_fingerprint.py) is the commit's full tree hash, this
workflow file's blob hash and the toolchain below; a missing toolchain value
gives no key. Not on a fork pull request, which could record a pass of its
own under any key.

## note-44

Above `fast-tier-cargo: Verify planner promotion evidence` in `.github/workflows/cmux-next.yml`.

needs a protected repository variable carrying an HQ receipt for this
exact planner policy after a complete 24-hour mirror window with a
measured zero false-skip rate.  A pull request cannot edit vars, so
its checkout cannot forge promotion evidence. Missing, stale, or
malformed evidence leaves this step false and the job runs in full.

## note-45

Above `fast-tier-cargo: Record this pass for the same inputs` in `.github/workflows/cmux-next.yml`.

A pass records itself for the next run on the same inputs: an artifact named after
the key, which every pull request and the base can list (scripts/ci/job_reuse.py
takes only passes of this repository's own runs). Never from a fork pull request.
An uncached (no_reuse) run records too.

## note-46

Above `swift-test: if` in `.github/workflows/cmux-next.yml`.

A pull request (same-repository or fork) runs it only with full-ci. On
every PR push it gave no signal: of 78 PR check runs (2026-11-02 to 11-05)
37 were cancelled (17 by the PR merging first, 10 by a newer push, 10 by a
re-run at the same head), 37 skipped, 4 failed and none passed. A
feat-cmux-next push skips it too (push CI is the app build only, see the
jobs comment), so a dispatch is where the Swift suites run: main's
cmux-next-tip-swift-suite-dispatch.yml runs them on the tip when Swift
changed (the base verdict), and gh workflow run runs them on any ref.

## note-47

Above `swift-test: timeout-minutes` in `.github/workflows/cmux-next.yml`.

A cold build of the package graph (CmuxNext plus its Shared and iOS test
dependencies) and the selected suites. Admission (up to 20 min), cache
restore (~7 min) and the build (~6 min) used most of 60 before a full
broad pass (~860 s on a slow mini) ran, so 90; the main-thread-heavy
suites' serial step (up to 60 min, out of the broad pass since #26809)
makes it 135.

## note-48

Above `swift-test: Require the GUI session on a mini` in `.github/workflows/cmux-next.yml`.

The GUI-tagged suites (.requiresGUISession, .requiresPasteboard; for
example SidebarLiveReorderTests) skip when the host has no display or
pasteboard. Every glaeda mini has both: in 153 swift-test jobs
(2026-10-04/05) all 11 minis behind the side label ran
SidebarLiveReorderTests and no GUI or pasteboard test skipped. On a
mini, CMUX_TEST_REQUIRE_GUI=1 turns a lost display into a failure
instead of a silent skip. Blacksmith and hosted labels
keep the skip: nothing has shown that they have a display session.
Not on a pull request: display tests gate no PR (Leo, 2026-10-31: "i dont like doing display
tests anymore"), so a PR's display suites skip, and a lost display never fails a PR job. Pushes
and nightlies keep the requirement as advisory coverage.

## note-49

Above `swift-test: Fingerprint this job's inputs` in `.github/workflows/cmux-next.yml`.

With vars.CI_NEXT_JOB_REUSE, a pass on the same inputs stands for this run: the
steps below skip and the summary names the run that passed. The key
(scripts/ci/job_input_fingerprint.py swift-test) is the commit's full tree hash, this
workflow file, the toolchain and the env flags below; a missing value gives no key. A run that
checks the generated files here (CMUX_NEXT_FOLD_GENERATED) also keys the base commit they are
compared against (generated_base), and records a pass only when they are fresh.
Any change to the tree, a base move included, changes the key. Not on a fork pull
request, which could record a pass of its own under any key.

## note-50

Above `swift-test: Script tests (bundle-server-helper)` in `.github/workflows/cmux-next.yml`.

macOS-only script behavior tests (PlistBuddy, plutil, lipo): the "Bundle
server helper" phase writes the server helper and agent plists without
the app's processed Info.plist, and release signing signs every
libexec helper and restamps the plists from the final bundle id; the
app personality check reads the bundle's Info.plist.

## note-51

Above `swift-test: Find the main-thread-heavy suites` in `.github/workflows/cmux-next.yml`.

The suites of the selected targets that drive the main thread for long
stretches (Core Animation frame commits, real WebKit downloads), read
from the test sources: the changed-suites pass and the broad pass skip
them and a step of their own runs them, each in a fresh process.

## note-52

Above `swift-test: SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH` in `.github/workflows/cmux-next.yml`.

One Swift Testing test at a time inside each shard process; the
shards themselves run side by side (swift-test-shards.py). A test's
time limit counts from its start, and Swift Testing otherwise starts
all ~5,900 at once (width 6 here before #26809). With 6 at once in
each of 3 shards, suites that pass alone at the base went red only
in shards: WorkspaceGroupPinLive, ClickedLinkFocus,
BrowserEngineStateRestore, RapidWorkspaceCreate,
WorkspaceHoverCardScroll, MarkdownTableWidthMemory (run
40896449485); at 1 at once all six passed (run 40906115871), and
the pass took 9.5 min against 8.1.

## note-53

Above `swift-test: Run control package tests and callback regressions` in `.github/workflows/cmux-next.yml`.

the build succeeded, even after a failed test step, so one red step
does not hide the others.
Some suites of this target hold the main thread on purpose (the
watchdog's stall and CPU tests, slow action spans, ControlLaneTests'
stalls, the work queue's floods); others check that a main-actor
request answers within its own deadline. Run together, a 2 to 5 s
hold made every request beside it answer `timeout`
(ActionRunCreatedTests, ActionBatchTests and BrowserTabMirrorTests
failed on every tip run, job 122086769190). The holders run after the
rest, one test at a time; the rest stays parallel. The suites that
check a production deadline itself (ActionRunCreatedTests' 2 s,
TerminalStartDeadlineTests' terminal start) run in that serial pass
too: the parallel pass still held the main actor past 2 s at its start
on loaded minis (jobs 122242957690, 122236716988, 122240111475).

## note-54

Above `swift-test: Record this pass for the same inputs` in `.github/workflows/cmux-next.yml`.

A pass records itself for the next run on the same inputs: an artifact named after
the key, which every pull request and the base can list (scripts/ci/job_reuse.py
takes only passes of this repository's own runs). Never from a fork pull request.
An uncached (no_reuse) run records too.

## note-55

Above `daemon-test` in `.github/workflows/cmux-next.yml`.

The live-daemon suites (daemon integration and branch tests, the mobile
live daemon and first launch) against this commit's own cmux-tui tree,
which the gate above waits for on Linux. Only the daemon tier runs it:
daemon, Rust core, FFI and control paths on a same-repository PR (a fork
PR with full-ci), and every push and dispatch.

## note-56

Above `daemon-test: Require the GUI session on a mini` in `.github/workflows/cmux-next.yml`.

The GUI-tagged suites (.requiresGUISession, .requiresPasteboard; for
example SidebarLiveReorderTests) skip when the host has no display or
pasteboard. Every glaeda mini has both: in 153 swift-test jobs
(2026-10-04/05) all 11 minis behind the side label ran
SidebarLiveReorderTests and no GUI or pasteboard test skipped. On a
mini, CMUX_TEST_REQUIRE_GUI=1 turns a lost display into a failure
instead of a silent skip. Blacksmith and hosted labels
keep the skip: nothing has shown that they have a display session.
Not on a pull request: display tests gate no PR (Leo, 2026-10-31: "i dont like doing display
tests anymore"), so a PR's display suites skip, and a lost display never fails a PR job. Pushes
and nightlies keep the requirement as advisory coverage.

## note-57

Above `daemon-test: Clean generated layout-reducer FFI lockfile` in `.github/workflows/cmux-next.yml`.

Building the package's reducer FFI can rewrite the isolated crate's
workspace lockfile. Put the checkout back immediately before
pin-cmux-tui validates it: the committed lockfile (#37324 tracks it)
is restored, and an untracked one is removed. Deleting a tracked
lockfile leaves the tree dirty, and pin-cmux-tui refuses that.

## note-58

Above `daemon-test: Regenerate stale files` in `.github/workflows/cmux-next.yml`.

A test helper that died on a signal leaves its crash report here
(scripts/cmux-next/swift-test-with-hang-sampler.sh): the crashed
thread names the test that trapped.
The generated files verdict of a push (the checks above), as generated-files gives it.
Only the generated paths are collected into the artifact.

## note-59

Above `daemon-test: # Same-tree mode: the result goes on the` in `.github/workflows/cmux-next.yml`.

Generated files are fresh: the action catalog, surfaces and inventory
(ActionSurfaceParityTests and its siblings) and the settings exports,
against a fresh export; the CI target graph and the defaults snapshot are
bot-only (#21946) and not checked. Its
own job, so a pull request that skips the package tests still cannot land
a stale export (feat-cmux-next went red at a925bd9 that way). When a file
is stale, the job regenerates it, uploads the regenerated files as the
cmux-next-generated-patch artifact and fails with the commands to run.

## note-60

Above `generated-files: Require the GUI session on a mini` in `.github/workflows/cmux-next.yml`.

The GUI-tagged suites (.requiresGUISession, .requiresPasteboard; for
example SidebarLiveReorderTests) skip when the host has no display or
pasteboard. Every glaeda mini has both: in 153 swift-test jobs
(2026-10-04/05) all 11 minis behind the side label ran
SidebarLiveReorderTests and no GUI or pasteboard test skipped. On a
mini, CMUX_TEST_REQUIRE_GUI=1 turns a lost display into a failure
instead of a silent skip. Blacksmith and hosted labels
keep the skip: nothing has shown that they have a display session.
Not on a pull request: display tests gate no PR (Leo, 2026-10-31: "i dont like doing display
tests anymore"), so a PR's display suites skip, and a lost display never fails a PR job. Pushes
and nightlies keep the requirement as advisory coverage.

## note-61

Above `generated-files: Fingerprint this job's inputs` in `.github/workflows/cmux-next.yml`.

With vars.CI_NEXT_JOB_REUSE, a pass on the same inputs stands for this run: the
steps below skip and the summary names the run that passed. The key
(scripts/ci/job_input_fingerprint.py generated-files) is the commit's full tree hash, this
workflow file, the toolchain and the env flags below; a missing value gives no key.
Any change to the tree, a base move included, changes the key. Not on a fork pull
request, which could record a pass of its own under any key.

## note-62

Above `generated-files: Check the settings exports` in `.github/workflows/cmux-next.yml`.

The settings exports (schemas/settings/settings-schema.json, docs/mdm)
are compared with a fresh export, never with a committed stamp of their
sources (Leo 2026-10-21: "just generate and don't commit"). The script
says when it exports and whose staleness a stale export is; the
daemon-test job's folded copy runs the same one.

## note-63

Above `generated-verdict` in `.github/workflows/cmux-next.yml`.

The generated files verdict of a run whose swift-test or daemon-test checked them on its own
package build (path_route's generated_host, CMUX_NEXT_FOLD_GENERATED): its own check, on Linux,
so a stale file is never a red swift or daemon test and a red test never hides a stale file.
A host that never gave a verdict (its build failed, it stopped early) fails this too.

## note-64

Above `release-compile-fast: if` in `.github/workflows/cmux-next.yml`.

On a gateway runner macos-placement saw idle this attempt it submits the fleet check; else it
runs on Linux and reads the fleet's own Release (-Onone) compile of this push (cmux-next/compile).
Only no verdict sends release-compile to a Mac (2026-11-02: a busy gateway queued it 2 h).

## note-65

Above `release-compile-fast-admission` in `.github/workflows/cmux-next.yml`.

the fast-check wrapper so unavailable fast checks cannot satisfy the gate.
It runs whenever the fast check ran and did not hand off to the Mac
fallback, and is green only on a pass: a fleet compile error stays red
under the gate name. The fallback takes over on verdict unavailable and
whenever the fast check finished without a verdict (refused at runner
setup, or its step died first), so exactly one job carries the gate name
for a push.
It requests promotion itself, once green: a request from the fast check
reached main before this job existed (main waits about 30 s for it), and a
rerun of only this gate never reruns a downstream request skipped earlier.

## note-66

Above `release-compile: Fingerprint this job's inputs` in `.github/workflows/cmux-next.yml`.

With vars.CI_NEXT_JOB_REUSE, a pass on the same inputs stands for this run: the
steps below skip and the summary names the run that passed. The key
(scripts/ci/job_input_fingerprint.py release-compile) is the commit's full tree hash, this
workflow file, the toolchain and the env flags below; a missing value gives no key.
Any change to the tree, a base move included, changes the key. Not on a fork pull
request, which could record a pass of its own under any key.

## note-67

Above `release-compile: Release compile` in `.github/workflows/cmux-next.yml`.

on cmux-lawrence's SSD) from the host's canonical root, read-only: only the trusted
writer fills it (scripts/cmux-next/release-compile-fleet-cas.sh). A node that does not
answer or a root another compile holds builds per runner as before, at once.
vars.CMUX_NEXT_RELEASE_FLEET_CAS=off turns it off.

## note-68

Above `release-compile: Fetch the Chromium engine` in `.github/workflows/cmux-next.yml`.

On a mini, the CEF glue (CEF's C++ wrapper, the CEFShim dylib and the
helper binary) is also compiled against the pinned Chromium engine
(scripts/cmux-next/cef-manifest.json), the way the app's Embed CEF
phase builds it, so a shim or manifest change the engine does not
accept fails here and not in the nightly. ensure-cef.sh fills the
mini's kept host cache (scripts/cmux-next/cef-cache-root.sh) from the private R2
bucket with the read-only key, which only this step receives and only
in same-repository runs, as in ci-macos.yml's admission; later runs
read the cache. A runner's own ~/.secrets file is never a source.
Blacksmith runs skip both steps: they keep no cache, so each run would
pay the download and the wrapper compile. So the check is advisory: a
re-run (Blacksmith) or a fork pull request does not repeat it.

## note-69

Above `release-compile: Request nightly-next promotion after this gate` in `.github/workflows/cmux-next.yml`.

A pass records itself for the next run on the same inputs: an artifact named after
the key, which every pull request and the base can list (scripts/ci/job_reuse.py
takes only passes of this repository's own runs). Never from a fork pull request.
An uncached (no_reuse) run records too. On a mini, only a run whose CEF shim compile
and Objective-C contract check ran records: a pass that skipped them does not stand
for a run that would have checked them.
A rerun of only this gate does not rerun a downstream job that was
skipped in the original attempt. Request here as well as in the small
downstream helper so a newly green rerun always reaches main.

## note-70

Above `swift-exports-cache` in `.github/workflows/cmux-next.yml`.

Caches the Swift exports of a green feat-cmux-next push under their source
key (scripts/cmux-next/swift-exports-key.py), so a job that only reads them
(the web bundles read the settings schema) can restore them with
swift-exports-cache.sh install instead of a Mac build (cx-vn5). A push runs
every tier, so on success the committed exports are the ones the Swift
tests checked.

## note-71

Above `request-nightly-next: Request a nightly-next continuation for an accepted pending build` in `.github/workflows/cmux-next.yml`.

GitHub runs `schedule` only from main's workflow, so this green compile
is the periodic tick that publishes an earlier nightly-next build Apple
accepted after its run stopped waiting (cx-f58x). It builds nothing and
submits nothing (scripts/cmux-next/continue-nightly-next.sh, tested by
scripts/cmux-next/tests/continue-nightly-next.test.sh).

## note-72

Above `cmux-scheme-compile: timeout-minutes` in `.github/workflows/cmux-next.yml`.

Debug arm64 xcodebuild of the cmux app scheme: the app host and every
local package it links (CmuxControlSocket, CmuxCore, ...), which the
CmuxNext jobs above never compile. A main merge once left
CmuxControlSocket extending deleted types and only fleet dev builds
failed. On a mini the DerivedData is kept per runner, so a run compiles
what changed; Blacksmith builds it cold. A change inside the CmuxNext
package skips it: the Release compile builds CmuxNextApp and all it links.

## note-73

Above `cmux-scheme-compile: Decide the fleet build's REF capture` in `.github/workflows/cmux-next.yml`.

A feat-cmux-next push's DEV Release app is dev-landing-compile's (one producer of the
run's cmux-next-dev-daily-unsigned-<sha>); this job builds it on a push only while
vars.CMUX_NEXT_DEV_LANDING_COMPILE is 0.
The fleet whole-app build plans from the rules of one real Mac build of the same shape
(its REF). With CMUX_NEXT_HYBRID_REF_CAPTURE=1 this compile records them, on a mini only,
when the inputs that change build lines (scripts/cmux-next/hybrid_ref_capture.py key)
have no complete capture yet; most landings share a key and skip it.
tests/test_cmux_next_hybrid_ref_capture.py keeps HYBRID_REF_SETTINGS equal to the compile's.

## note-74

Above `cmux-scheme-compile: Look up the DEV Release app compiled on the same inputs` in `.github/workflows/cmux-next.yml`.

(scripts/ci/dev_release_product_reuse.py): the key is job_input_fingerprint.py
dev-release-product (the tree minus docs, tests and other products, this workflow, Xcode,
the SDK and the cmux-tui tree), never a branch or commit. A hit downloads the app another
feat-cmux-next push or DEV run recorded under it and checks its SHA-256; a dev_daily run then
skips the steps below that only feed xcodebuild. A miss, or any error, compiles as before.
The key is the tree this job checked out and builds (the pushed or dispatched commit's).
Signing and publishing still run at this exact SHA (cmux-next-dev-daily.yml). Only this
workflow on feat-cmux-next reuses: never nightly or stable builds (hq#3967).

## note-75

Above `cmux-scheme-compile: Source key of the web bundles` in `.github/workflows/cmux-next.yml`.

bundles" phase refuses an app built without them, and this job's app is
the dogfood artifact. The Linux web-bundles job builds them once per
source key (web-bundle-key.py --source) and stores them under it; this
job installs that tree when it finds it and builds them itself, with bun
and node, only when it does not. Restored or built, they are the same
bytes: the key hashes every input and the pinned bun, and the build runs
on node on both (build-web-bundles.sh).
A mini reuses its workspace: start from no restored tree, so nothing a
previous job restored there can be installed with this key's bundles.

## note-76

Above `cmux-scheme-compile: Key the DEV compile cache (Blacksmith)` in `.github/workflows/cmux-next.yml`.

A current feat-cmux-next push also produces the Release app consumed by
cmux-next-dev-daily.yml. Keep this separate from the Debug dogfood
product: the daily channel has its own stable identity and must never
replace the existing PR artifact.
A Blacksmith VM keeps no cache between jobs, so its DEV compile's Xcode compilation cache
rides Blacksmith's own actions/cache, served next to the runner, as classic's nightly does
(Leo, 2026-10-26: "just give them the cache"). The newest entry under the key's prefix
restores; a mini keeps its cache on disk and skips these (scripts/cmux-next/dev-vm-cas-key.sh).

## note-77

Above `cmux-scheme-compile: Crash ends the app` in `.github/workflows/cmux-next.yml`.

A crash ends the app, never freezes it (2026-10-20 NIGHTLY freezes): with
Sentry on, an uncaught exception must end the process within 8 s and a
crash path that blocks must end within the crash deadline. The step
does not fail this job; the crash-ends-app job reports it.

## note-78

Above `cmux-scheme-compile: Package the trusted cmux-next dogfood artifact` in `.github/workflows/cmux-next.yml`.

The default-branch publisher consumes the exact app produced by this
job.  Keep the upload limited to same-repository member PRs carrying
the existing dev-build label; the publisher repeats this trust check
before it writes the immutable R2 object or comments on the PR.

## note-79

Above `cmux-scheme-compile: Capture the fleet build's REF` in `.github/workflows/cmux-next.yml`.

Last, so nothing in this job waits for it; bounded so it cannot reach the job's limit or hold
the push compile slot long (a capture is a few minutes, about once a day). Only a host-mode build (one tree and DerivedData
per host, the paths every mini shares) is captured, from the snapshot compile-dev-release.sh
cloned while it held the host lock (another build may own the host tree by now). The packs go to the build fleet's
private store; the manifest artifact names their sizes and sha256 only.

## note-80

Above `crash-ends-app: # Same-tree mode: the result goes on the` in `.github/workflows/cmux-next.yml`.

superseded push skips its Mac jobs, so a burst of merges is checked once,
at its newest commit). When a check job fails, this comments on each pull
request merged since that job last passed on a push, so the owning lane
fixes forward (scripts/ci/cmux_next_push_attribution.py). It reads the
Actions and pulls APIs; no branch code runs.

## note-81

Above `compile-status: PR` in `.github/workflows/cmux-next.yml`.

The pull request this head belongs to (empty on a push). A head whose run the controller never
saw has no check; a read that names its pull request has the controller queue one
(cmuxterm-hq#5571), instead of this step waiting 40 minutes for a check that never comes.
