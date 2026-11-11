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

On a push the check runs with `--stale-grace 7200`: an FFI commit's release
can only be built from that pushed commit, so the pin is behind the sources
after every FFI push until `app-ffi-release.yml` publishes and pins it. A pin
behind for less than two hours passes with a note; one behind for longer
fails, because then the release or the re-pin did not happen. Before, every
FFI commit left the tip red for 30 to 240 minutes (2026-11-11).

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
recipe version, or a mint or post error is failure. The results service down is no verdict
and hands off (note-82, note-83). The wait blocks on the endpoint
(`wait=N` returns at a terminal state, else at its deadline) under one overall deadline of
40 min from the job's start, each read hard-bounded by `timeout` to what is left; a missing result (404) is
read again 30 s later, inside that bound. The terminal post comes before the
App token's hour ends (it is minted just before the wait).

A refused status post (`post()`, the same function in compile-status and compile-status-handoff) prints GitHub's
answer (`HTTP 403: {"message":...}`) and waits out a rate limit: a 403 or 429 that says so waits its Retry-After or
primary reset, at least 60 s and twice as long each try (a retry inside a secondary limit extends it), up to 600 s;
a 5xx or no answer tries again in 10 s; any other refusal (a bad token, no permission) is final at once. The pending
post only shows the wait, so it gets 30 s and a refusal is a warning: on 2026-11-11 from 02:38Z a ten-minute 403 rate
limit on cmux-bot failed this job on #40351, #40942, #41007 and the base push at the pending post, before any compile
was read. A terminal post that still fails leaves the job's own `cmux-next/compile is not a pass for SHA (STATE)`
line: no verdict for base_red_excuse.py (`NO_VERDICT`) for every state but `fail`, which stays a compile red.
`test_every_cmux_next_compile_post_waits_out_a_rate_limit` fails on a job that posts cmux-next/compile any other way.

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

## note-82

Above `compile-status: the results service down` and `FALLBACK` in `.github/workflows/cmux-next.yml`, and
release-compile-fast's read loop.

The results service is a cache, not a dependency. With the build controller down, its proxy answers every read
with a 52x/530 (the origin is down). compile-status read it with `curl --retry-all-errors` bounded only by its
40-minute deadline, so it retried the 530 for 40 minutes and then posted "No compile result for this head in 40
minutes" on every pull request (cmux#40600, run 42850259745). Now it reads the way release-compile-fast does: two
probes 30 s apart (`PROBE_GAP`), and no connection (000) or a 52x/530 on both is the service down at once. During the
wait no read retries inside curl. One shared deadline bounds it: `ok_at`, taken before the first probe and moved only by
a usable answer (a 200, or a 404: no result yet), plus `BAD_BOUND` (5 minutes), and the overall wait's deadline. Each
read gets `--max-time` and `timeout` of what is left of the nearer of the two (its long poll `wait=` asks for 30 s less),
so a stalled response (the connection open, no answer) cannot hold a read past the bound, and a 404 is read again 30 s
later (`READ_GAP`, also cut to what is left). When either deadline runs out with the last answer unusable (a 52x/530,
a 403, a 5xx, a read that timed out: HTTP 000), the service is down, also when the overall wait is shorter than the
bound. release-compile-fast's read uses the same loop, so a service that goes down after its probes hands its gate to
the Mac fallback in 5 minutes, not 20.

The service down is no verdict, and compile-status hands it to the fallback Release compile where one runs for the
head (`FALLBACK`): a feat-cmux-next push that is still the branch head (release-compile-fast, which reads the same
service, says unavailable and release-compile runs on a Mac, or its gateway route gives its own verdict), and a
same-repository pull request labelled `full-ci` or one path_route sends to the Mac Release compile (`mac_release`).
It leaves cmux-next/compile pending, naming the handoff, and ends green; compile-status-handoff posts the verdict
(note-83). Every other pull request runs no Release compile but this one, so nothing in the run can stand in: it
posts state `error` ("no fallback compile runs here; re-run this job"), never a failure that reads as a compile
failure and never a success, and the job's red line is a no-verdict line (`(results service down, ...)`), which
autoland re-runs once as infrastructure. The fleet's app compile (app-compile-fleet) gives the same answer for
the same outage.

`tests/test_ci_cmux_next_compile_status.py` serves 530 from a local HTTP server to the real step and real curl.
Its `UnboundedRetryDetector` fails on any `curl --retry-all-errors` in this workflow without a fixed bound, and on
one that reads our own service (a cmux.com host) with a bound over 5 minutes.

## note-83

Above `compile-status-handoff` in `.github/workflows/cmux-next.yml`.

Runs only when compile-status handed off (its `handoff` output names the outage) and waits on the fallback with
`needs`, so nothing polls. It posts cmux-next/compile from the fallback's own result: release-compile-fast's pass or
fail (a gateway's fleet compile), else release-compile's success or failure. Success is a real Release compile of
the head; a failure says "the Release compile (fallback) failed" and links the run, and the job is red. When neither
ran (a pull request whose app-compile-fleet gave a verdict, so release-compile skipped; a push superseded on the way;
a cancelled Mac job) it posts `error`, asks for a re-run of all jobs (a re-run of failed jobs alone would rerun only
this job), and ends with scripts/ci/needs_verdict.py's `no verdict: ` line and exit 3, never the PR's own red.

## note-84

Above `[no-verdict]` in compile-status in `.github/workflows/cmux-next.yml`.

Every cmux-next/compile description that is no verdict (unavailable, a result for another head, no result by the
deadline, the results service down with no fallback, and compile-status-handoff's no fallback ran) starts with the
marker `[no-verdict]`. scripts/ci/base_red_excuse.py keys on it (COMPILE_STATUS_NO_VERDICT_MARKER): such a status is
ignored when another compile passed at the head, and refused with "re-run it" otherwise, never compared with the base
as a compile red. The classifier still matches the older prose, so statuses posted before the marker read the same.
A new no-verdict description needs only the marker; a real compile failure must never carry it.

## note-85

Above `pr-quiet-period: runs-on` in `.github/workflows/cmux-next.yml`.

A fork pull request's sleep takes the fixed 2 vCPU label like every fork route (no pool read).

## note-86

Above `pr-quiet-period: continue-on-error` in `.github/workflows/cmux-next.yml`.

A failed or timed-out wait never holds the checks: every job after it runs on !cancelled().

## note-87

Above `push-head-preflight: if` in `.github/workflows/cmux-next.yml`.

It starts at once: the Mac jobs wait for the pull request quiet period through macos-placement.

## note-88

Above `path_route: timeout-minutes` in `.github/workflows/cmux-next.yml`.

Above the probe steps' own limits, so a slow probe fails open (below)
instead of cancelling the job and skipping every compile and test job.

## note-89

Above `path_route: actions` in `.github/workflows/cmux-next.yml`.

This job executes the checked-out revision's routing and probe scripts,
including on same-repository pull requests. It may inspect Actions and
source, but only trusted default-branch controls may mutate either.

## note-90

Above `path_route: mac_release` in `.github/workflows/cmux-next.yml`.

A same-repository pull request runs the Mac Release compile only when this is true: it changes
an input only that xcodebuild sees (cmux_next_route.MAC_RELEASE_INPUTS).

## note-91

Above `path_route: fast_tier` in `.github/workflows/cmux-next.yml`.

The Mac fast tier's package build and suites (cmux_next_route.py fast_tier): false for a
pull request whose change none of them reads (a daemon-only Rust change, an app-host file).

## note-92

Above `path_route: tree_state` in `.github/workflows/cmux-next.yml`.

ready, deferred, superseded or failed; empty when no tree tier runs.

## note-93

Above `path_route: tree_fetch_key` in `.github/workflows/cmux-next.yml`.

A pull request that changes no cmux-tui path and whose own tree is not
ready: the published tree its tree jobs fetch (CMUX_TUI_TREE_KEY).

## note-94

Above `path_route: fetch-depth` in `.github/workflows/cmux-next.yml`.

The merge commit and its first parent (the base).

## note-95

Above `path_route: BASE_TIER_COALESCE` in `.github/workflows/cmux-next.yml`.

'0' turns the coalescing off: every feat-cmux-next push runs its base Mac tier again.

## note-96

Above `path_route: DEV_LANDING_COMPILE` in `.github/workflows/cmux-next.yml`.

'0': the push's scheme compile is also the DEV landing build (cmux-scheme-compile's DEV
Release step), so a push keeps it.

## note-97

Above `path_route: EVENT_LABELS` in `.github/workflows/cmux-next.yml`.

The labels at the push. A re-run keeps that event, so it reads them
live: adding full-ci or dev-build and re-running routes on them.

## note-98

Above `path_route: CMUX_TUI_TREE_RUN_FETCH_SECONDS` in `.github/workflows/cmux-next.yml`.

The active-run commit fetches share this budget (pin-cmux-tui.sh
active_publisher_for_key); an unread run reads as unknown.

## note-99

Above `path_route: CMUX_TUI_TREE_BASE_FALLBACK` in `.github/workflows/cmux-next.yml`.

DEV is a cutting-edge app channel: if this head's daemon tree is
still publishing, build the exact app head against the newest
published compatible tree instead of waiting on nightly's tree.

## note-100

Above `path_route: CMUX_TUI_TREE_PUBLISHER_WAIT_SECONDS` in `.github/workflows/cmux-next.yml`.

No PR merge-tree publisher exists. A PR looks once for an already
published tree or trusted publisher; a cold own tree is skipped.

## note-101

Above `path_route: Write the tree wait marker` in `.github/workflows/cmux-next.yml`.

What a trusted publication needs to start this run's tree jobs later.
A cold PR tree has no publisher, so it leaves no marker. An active
trusted run still gets one and may later start the tree jobs.

## note-102

Above `path_route: if` in `.github/workflows/cmux-next.yml`.

A DEV daily run waits for its own tree (job dev-daily-tree-wait): a
same-tree run would start only while the tip is still its SHA.

## note-103

Above `path_route: Probe the same-tree cmux-tui after the marker` in `.github/workflows/cmux-next.yml`.

Looked at again after the marker is up: a publish that lands later
sees the marker, and one that landed before this look is seen here.

## note-104

Above `path_route: timeout-minutes` in `.github/workflows/cmux-next.yml`.

Fails open like the first probe: its tree_state stands.

## note-105

Above `path_route: CMUX_TUI_TREE_PUBLISHER_SHA` in `.github/workflows/cmux-next.yml`.

A scheduled DEV run owns its exact SHA. A cold tree with no active
publisher fails closed; this checked-out revision never starts one.

## note-106

Above `path_route: CMUX_TUI_TREE_PUBLISHER_WAIT_SECONDS` in `.github/workflows/cmux-next.yml`.

The first probe already inspected the trusted publisher.

## note-107

Above `dev-daily-tree-wait: actions` in `.github/workflows/cmux-next.yml`.

The selected revision may inspect a publisher, never start one.

## note-108

Above `macos-placement: timeout-minutes` in `.github/workflows/cmux-next.yml`.

Checkout (1m), three bounded token mints (3m), placement (2m),
marker upload (1m), plus time for runner setup and action cleanup.

## note-109

Above `macos-placement: retry_runner` in `.github/workflows/cmux-next.yml`.

The overflow label only while it has a free slot, else empty (the owned
label below). Read from free_retry_runner, which a placement script
predating the free-slot rule never writes.

## note-110

Above `macos-placement: deferred_runner` in `.github/workflows/cmux-next.yml`.

Preserve the existing queue only when the cascade has no admissible target.

## note-111

Above `macos-placement: fast_runner` in `.github/workflows/cmux-next.yml`.

vars.CI_FAST_LANE_RUNNER while one of its runners is idle, else empty
(side_lane_placement.fast_route()): the fast tier never queues on it.

## note-112

Above `macos-placement: fresh_runner` in `.github/workflows/cmux-next.yml`.

The DEV compile slot and the feed compiles its idle runners take (side_lane_placement.fresh_route()).

## note-113

Above `macos-placement: gui_runner` in `.github/workflows/cmux-next.yml`.

GUI suites have a separate label. The generic side label is also
carried by headless AWS workers for compile-only capacity.

## note-114

Above `macos-placement: gui_overflow` in `.github/workflows/cmux-next.yml`.

The Blacksmith macOS label the GUI jobs take while no owned GUI runner has room (a queue deeper than
the pool, side_lane_placement.role_room()), and on the rescue's full re-run; empty otherwise.

## note-115

Above `macos-placement: session_lane_runner` in `.github/workflows/cmux-next.yml`.

SESSION_LANE (vars.CI_SESSION_LANE_RUNNER) while it has room (side_lane_placement.role_room()), else empty:
generated files take the variable on this attempt only then.

## note-116

Above `macos-placement: Mint the cmux-bot runner-read token` in `.github/workflows/cmux-next.yml`.

The second identity for the same runner reads: when the routing App's read is refused (403s
from 22:47Z on 2026-10-26 sent every DEV compile to an owned queue), the placement reads again
with cmux-bot (organization self-hosted runners: read). A failed mint leaves it empty.

## note-117

Above `macos-placement: Mint the glaeda read token` in `.github/workflows/cmux-next.yml`.

Reads go through the manaflow-glaeda-route App's own budget, not the GITHUB_TOKEN
budget every workflow shares (it ran out on 2026-10-25 and the nightly publish
failed). No key (a fork) or a failed mint leaves it empty: GITHUB_TOKEN reads.

## note-118

Above `macos-placement: CI_FLEET_GATES` in `.github/workflows/cmux-next.yml`.

Glaeda's authoritative per-label gate reading; this avoids a second API request.

## note-119

Above `macos-placement: PROMOTE_LABEL` in `.github/workflows/cmux-next.yml`.

Attempt 1 of a feat-cmux-next push prefers the dedicated cmux NEXT
nightly runner; a busy or unavailable runner uses Blacksmith overflow.

## note-120

Above `macos-placement: FAST_LABEL` in `.github/workflows/cmux-next.yml`.

The fast tier's reserved label, taken only while one of its runners is idle.

## note-121

Above `macos-placement: SESSION_LANE` in `.github/workflows/cmux-next.yml`.

Generated files' own session lane, weighed like the gui and session routes (session_lane_runner).
Fork branch first: a fork never reads the variable, and a label that is not glaeda-* places no lane.

## note-122

Above `macos-placement: GATEWAY_JOBS` in `.github/workflows/cmux-next.yml`.

The gateway jobs this run starts (their own `if`s), each needing an idle runner.

## note-123

Above `macos-placement: GUI_LAST_RESORT` in `.github/workflows/cmux-next.yml`.

The GUI jobs' last resort when the placement names neither a GUI route nor a GUI overflow (the shell
below). Fork branch first, as every runs-on here: a fork never names a Blacksmith label.

## note-124

Above `macos-placement: Mark a run on the minis` in `.github/workflows/cmux-next.yml`.

when every macOS job took its fallback, and on a push: the push Mac
jobs' branch groups bound that queue, and the rescue would cancel a
running push run once a newer push exists.

## note-125

Above `macos-placement: Upload the owned-pool watch marker` in `.github/workflows/cmux-next.yml`.

(retry_runner is empty), so the rescue's cancel and re-run would only
send the run to the back of that queue: run 39615562861 went round
twice on 2026-10-21. The refusals marker has the sweeper re-run what a
mini refuses and leave a long queue alone.

## note-126

Above `portable-placement: if` in `.github/workflows/cmux-next.yml`.

It starts at once and places only Linux-portable jobs (checks, path_route), which start at once too,
so the runners it finds idle are still idle when the jobs it places start. The PR quiet period
holds only the Mac jobs (macos-placement).

## note-127

Above `portable-placement: actions` in `.github/workflows/cmux-next.yml`.

The queue janitor's pool snapshot (nightly jobs waiting on a pool).

## note-128

Above `portable-placement: placed_attempt` in `.github/workflows/cmux-next.yml`.

A re-run of failed jobs carries this job's outputs from an earlier attempt; a job takes them
only in the attempt that placed it, so a stale reading never sends it to a busy mini.

## note-129

Above `portable-placement: Drop stale submodule checkouts (self-hosted reused workspace)` in `.github/workflows/cmux-next.yml`.

A mini or fleet Linux host reuses its workspace: drop the submodule checkouts a previous job
left there (a no-op on Blacksmith, which starts with none).

## note-130

Above `portable-placement: Place the portable jobs` in `.github/workflows/cmux-next.yml`.

The fresh registration census already carries the trusted queue snapshot.
No private App token is needed: missing or stale state keeps the overflow route.

## note-131

Above `portable-placement: FLEET_LINUX` in `.github/workflows/cmux-next.yml`.

Fork branch first: a fork never reads the runner variables (and its job is skipped); ubuntu-24.04 places nothing.

## note-132

Above `checks: fetch-depth` in `.github/workflows/cmux-next.yml`.

The merge commit and its first parent: the god-file checks compare a
pull request against its base.

## note-133

Above `checks: Drop stale submodule checkouts (self-hosted reused workspace)` in `.github/workflows/cmux-next.yml`.

A mini or fleet Linux host reuses its workspace: drop the submodule checkouts a previous job
left there (a no-op on Blacksmith, which starts with none).

## note-134

Above `checks: God files and types (Swift)` in `.github/workflows/cmux-next.yml`.

job once, naming each red check. Checkout stays fatal: with no tree,
the checks have nothing to read.

## note-135

Above `checks: run` in `.github/workflows/cmux-next.yml`.

A pull request fails only on what it grew (its merge commit's first
parent is the base), so a god file already on the base never blocks
it. A push checks every file.

## note-136

Above `checks: run` in `.github/workflows/cmux-next.yml`.

A pull request fails only on what it grew (its merge commit's first
parent is the base), so a god file already on the base never blocks
it. A push checks every file.

## note-137

Above `checks: CmuxNextApp size cap` in `.github/workflows/cmux-next.yml`.

shrink, new features go in their own target (code-quality.md SW14).

## note-138

Above `checks: No new SwiftUI (macOS UI is AppKit)` in `.github/workflows/cmux-next.yml`.

Blocking (not a warn-only style check): the allowlist only shrinks, so a
pull request compares with its merge commit's first parent and a push
with the commit before it (plans/cmux-next/no-swiftui-DESIGN.md).

## note-139

Above `checks: Default cursor (no pointing hand in app UI)` in `.github/workflows/cmux-next.yml`.

The user (2026-10-30): "change all pointers back to cursor-default". App UI shows the
arrow; only web page and terminal content may show the pointing hand (allowlist).

## note-140

Above `checks: One web view factory` in `.github/workflows/cmux-next.yml`.

Every web view goes through the engine decision (browser.defaultEngine,
browser.siteEngines): PageWebView for cmux pages, BrowserTab for tabs.

## note-141

Above `checks: Tests inject their notification center` in `.github/workflows/cmux-next.yml`.

observer in the test process on the posting thread (#18771's signal 5).

## note-142

Above `checks: Scrollbars thin, one style` in `.github/workflows/cmux-next.yml`.

SCROLLBARS-THIN: no forced scroller style, hidden indicators or
custom web scrollbars outside the one shared style (SystemScrollers.swift,
webviews/src/scrollers.ts): thin, shown only while scrolling.

## note-143

Above `checks: Motion tokens` in `.github/workflows/cmux-next.yml`.

so ui.animationSpeed and Reduce Motion reach every animation.

## note-144

Above `checks: Overlays are glass, never solid` in `.github/workflows/cmux-next.yml`.

Glass, never solid (Leo 2026-10-21: "STOP DOING SOLID. WE HAVE GLASS, SO JUST USE GLASS."):
popovers, tooltips, hover cards, menus and sidebar cards paint no solid fill unless
check-overlay-glass.py lists why (ccde782cb51 turned them solid unnoticed).

## note-145

Above `checks: Motion scale` in `.github/workflows/cmux-next.yml`.

TypeScript copies (Leo 2026-10-20: one token file both sides read).

## note-146

Above `checks: Motion and colour tokens` in `.github/workflows/cmux-next.yml`.

No new raw animation duration or raw colour outside the tokens, everywhere the other motion and
design-token checks do not read (shrink-only baseline: motion-tokens-baseline.tsv), and the
animation-token coverage figure (motion-coverage.py) for the nightly.

## note-147

Above `checks: Surface roles` in `.github/workflows/cmux-next.yml`.

copies match it (Glass, never opaque: one token set for every popover, menu, card, toast and sheet).

## note-148

Above `checks: Menu metrics` in `.github/workflows/cmux-next.yml`.

The one menu row grid (schemas/menu-metrics/menu-metrics.json): its Swift and CSS copies, and no
menu with its own paddings (Leo 2026-10-21: one left alignment across every menu).

## note-149

Above `checks: Protected-folder copies` in `.github/workflows/cmux-next.yml`.

protected-folder list (cmux-tui/crates/acpmux/data/protected-folders.json).

## note-150

Above `checks: Settings source copies` in `.github/workflows/cmux-next.yml`.

The hand-edited settings sources in schemas/settings (retired keys so
far, cx-d5b5d) and their generated Swift copies; the daemon embeds the JSON.

## note-151

Above `checks: Phone lane field allowlist` in `.github/workflows/cmux-next.yml`.

schema and the lane's command allowlist (DaemonLanePolicy+Fields.generated.swift).

## note-152

Above `checks: Backdrop art export` in `.github/workflows/cmux-next.yml`.

The backdrop art list (ids, titles, image and thumbnail URLs, Shuffle Daily) exported
from the CmuxNextDesign Swift to plans/cmux-next/backdrop-art.json for the GPUI app.

## note-153

Above `checks: Bundled terminfo` in `.github/workflows/cmux-next.yml`.

carries ghostty-next's capabilities and cmux's 256-color 8-15 patch.
Its own step, so the summary names it when it is red.

## note-154

Above `checks: Package conventions lint` in `.github/workflows/cmux-next.yml`.

The repo-wide package conventions (namespace types, free functions,
singletons, ...). test-ios.yml runs it only for pull requests, merge
groups and dispatches; this step covers direct feat-cmux-next pushes.

## note-155

Above `checks: Browser chrome icons` in `.github/workflows/cmux-next.yml`.

The browser chrome draws Chromium's own icons (design/icons/chromium): the
generated batch is current and no browser control uses an SF Symbol or a
non-Chromium pack icon.

## note-156

Above `checks: App Store review rules (cmux-next-ios intents, Info.plist)` in `.github/workflows/cmux-next.yml`.

names in App Intents text, 90683 purpose strings, ...), on the
cmux-next-ios sources. The INTERNAL builder runs it again on the built app.

## note-157

Above `checks: No fleet host names in gallery fixtures` in `.github/workflows/cmux-next.yml`.

machines "studio-mac" or "build-box", never a fleet host (the capture privacy check
refuses a still that shows one, and WorkspaceHoverCardGallery's "air-blue" did).

## note-158

Above `checks: Kill switches are declared, tied to a PR and unexpired` in `.github/workflows/cmux-next.yml`.

owner and expiry, and goes red past its expiry until the killSwitch("pr-N") call, the
old path and the entry are removed; flags.json may turn off only declared switches.

## note-159

Above `checks: Tier routing` in `.github/workflows/cmux-next.yml`.

The tier routing on the committed target graph: a UI change selects its
own test targets, a daemon change the live-daemon suites, an unknown
path every tier.

## note-160

Above `checks: Package dependency lists sorted` in `.github/workflows/cmux-next.yml`.

The CmuxNextAppTests dependencies are one sorted entry per line, so two
pull requests adding different modules merge cleanly; the long lines they
all appended to conflicted on nearly every open pull request.

## note-161

Above `checks: Web bundle key inputs` in `.github/workflows/cmux-next.yml`.

The web bundle source key covers every file outside webviews/ that a bundle
imports, and the publish and routing path lists name each one (cx-wtsf3).

## note-162

Above `checks: Web update pointer` in `.github/workflows/cmux-next.yml`.

The signed web update pointer (plans/cmux-next/web-ota.md): verifies only under a listed
key, refuses a changed payload, and never moves back.

## note-163

Above `checks: Base-red classifier (per test)` in `.github/workflows/cmux-next.yml`.

run is never the base's (scripts/ci/test_reds.py, after cmux#26346 landed with its own
signal 6 behind a job-level base red).

## note-164

Above `checks: DEV update and classic import scripts` in `.github/workflows/cmux-next.yml`.

update keeps sessions and reopens the app) and the classic session import.

## note-165

Above `checks: Routing replay (router changes)` in `.github/workflows/cmux-next.yml`.

through the base router (the merge commit's HEAD^1) and its own: a tier the new router
adds, or drops without naming a fast tier, fails (scripts/ci/cmux_next_route_replay.py).

## note-166

Above `checks: Daemon capabilities export is fresh` in `.github/workflows/cmux-next.yml`.

DaemonEndpoint.swift, without a build: check-daemon-capabilities.sh
reads the JSON only inside an app build, so a Swift-only change to the
lists (67b13e24e84d) broke every tagged build first.

## note-167

Above `checks: App capability references are listed` in `.github/workflows/cmux-next.yml`.

Every capability the app references and the daemon source defines is
in DaemonCapability.required/.optional, without a build: the app build
runs this check first, so #21322 (four unlisted capabilities) broke
every tagged build before any PR check saw it.

## note-168

Above `checks: Capability texts never say update the app` in `.github/workflows/cmux-next.yml`.

A capability error is a version skew: it names the matching CLI or one
exact command, never "update the app" (plans/cmux-next/version-skew.md).

## note-169

Above `checks: Pushed commits add no violations` in `.github/workflows/cmux-next.yml`.

The pre-push gate again (scripts/cmux-next/prepush-gate.py, same pinned tools): on a push,
each pushed commit against its parent, so a commit pushed with --no-verify that adds a
violation is named; on a pull request, what the PR adds over its base (HEAD^1).

## note-170

Above `checks: BASH_ENV` in `.github/workflows/cmux-next.yml`.

The check steps above continue on error, so this step decides the job: it must not source the
checkout's scripts/ci/api_call_log/env.sh (the workflow's BASH_ENV), which their code can rewrite.

## note-171

Above `web-bundles: environment` in `.github/workflows/cmux-next.yml`.

Only a feat-cmux-next run enters next-cache-writer (deployment branch
feat-cmux-next only), and only its push publishes the bundles to NEXT's
R2 bucket; a pull request holds no credential and saves only to its
GitHub cache.

## note-172

Above `web-bundles: ref` in `.github/workflows/cmux-next.yml`.

Same-tree mode compiles the commit the tree was probed for (cmux-scheme-compile).

## note-173

Above `web-bundles: Drop stale submodule checkouts (self-hosted reused workspace)` in `.github/workflows/cmux-next.yml`.

runs-on can resolve to vars.LINUX_RUNNER, which may name a self-hosted
host that reuses its workspace; drop the submodule checkouts a previous
job left there (a no-op on Blacksmith, which starts with none).

## note-174

Above `web-bundles: Give this job its own bun` in `.github/workflows/cmux-next.yml`.

The minis share ~/.bun with workflows that install another bun; this
job runs on its own copy of the pinned one (private-bun.sh).

## note-175

Above `web-bundles: Setup Node` in `.github/workflows/cmux-next.yml`.

The webviews app's `vp build` must run on node (build-web-bundles.sh).

## note-176

Above `web-bundles: Cache the webviews Bun package cache` in `.github/workflows/cmux-next.yml`.

A miss spends most of its time in `bun install` with an empty package cache (about
60 of 104 s, run 40360791277). ci-web.yml's webviews jobs keep the same cache.

## note-177

Above `same-tree-cmux-tui: if` in `.github/workflows/cmux-next.yml`.

A superseded push reports nothing (its newer head is tested); a pull
request's cold tree is named in path_route's summary, skipped here.

A same-tree run dispatched with `same_tree_state=failed` reads the tree's
publish record (its `completion.json` on R2, keyed by the tree key its
reason names) before it reports red: a tree published since dispatches the
ready tree jobs and marks the stale statuses pending. A re-run keeps the
dispatch inputs, so before this a re-run repeated the old verdict forever
(cmux#40449, run 43009515785). A red it does report leaves a `reported`
tree wait marker, so the key's next publication re-dispatches every tier it
reported (`scripts/ci/cmux_next_same_tree_failed.py`).

## note-178

Above `swift-canary-fleet: if` in `.github/workflows/cmux-next.yml`.

With macos-placement's gateway judgement in this attempt (gateway_attempt) it runs only on an
idle gateway runner (gateway_runner); with none idle the Mac canary takes the cascade instead.

## note-179

Above `app-compile-placement: timeout-minutes` in `.github/workflows/cmux-next.yml`.

Checkout (1m), two bounded token mints (2m), the read (2m), plus runner setup.

## note-180

Above `app-compile-placement: Check out the trusted placement` in `.github/workflows/cmux-next.yml`.

The placement code from the base branch, as macos-placement's.

## note-181

Above `app-compile-fleet: Compile-check the app at the pull request's head on the build fleet` in `.github/workflows/cmux-next.yml`.

The gateway checks nothing out: the fleet fetches the commit itself.

## note-182

Above `swift-canary: if` in `.github/workflows/cmux-next.yml`.

Same-repository PRs and dispatches run it; a fork PR only with full-ci.
Base pushes remain the Release backstop.

## note-183

Above `swift-canary: cancel-in-progress` in `.github/workflows/cmux-next.yml`.

A newer PR push or manual rerun supersedes an older canary. This keeps
the queue focused on the current head instead of replaying stale
typechecks.

## note-184

Above `swift-canary: Discard the workspace repository after a failed checkout` in `.github/workflows/cmux-next.yml`.

As in swift test: a partial clone left in this reused workspace fetches
a missing blob mid-step, unretried. Retry once from a fresh repository.

## note-185

Above `swift-canary: Keep Swift package builds on this owned Mac` in `.github/workflows/cmux-next.yml`.

Checkout removes .build. Link the owned Mac's kept build after Xcode
selection so its fingerprint uses the compiler that runs this job.

## note-186

Above `fast-tier-rerun-placement: timeout-minutes` in `.github/workflows/cmux-next.yml`.

Checkout (1m), two bounded token mints (2m), the reads (2m), plus runner setup.

## note-187

Above `fast-tier-rerun-placement: actions` in `.github/workflows/cmux-next.yml`.

This attempt's jobs: whether the fast tier runs again.

## note-188

Above `fast-tier-rerun-placement: Check out the trusted placement` in `.github/workflows/cmux-next.yml`.

The placement code from the base branch, as macos-placement's.

## note-189

Above `fast-tier-rerun-placement: Place the fast tier's re-run` in `.github/workflows/cmux-next.yml`.

Fails open: an unread status, a failed read or a base script that predates the re-run placement
writes nothing, and the tier keeps its route.

## note-190

Above `fast-tier-fleet: runs-on` in `.github/workflows/cmux-next.yml`.

This attempt's re-run reading first (fast-tier-rerun-placement), else macos-placement's.

## note-191

Above `fast-tier-fleet: timeout-minutes` in `.github/workflows/cmux-next.yml`.

Longer than the client's queue (1200 s) plus run (1500 s) timeouts and the
report, so the client, not the job timeout, ends a slow step.

## note-192

Above `fast-tier-fleet: REF` in `.github/workflows/cmux-next.yml`.

github.sha: a pull request's merge commit, the tree fast-tier itself checks out (as
swift-canary-fleet), so a head that breaks against the current base is still caught.

## note-193

Above `fast-tier-fleet: HOME_RENDER_SUITES` in `.github/workflows/cmux-next.yml`.

fast-tier.json's swift entries, by package (FastTierFleetClient keeps them equal).

## note-194

Above `fast-tier-handback-placement: timeout-minutes` in `.github/workflows/cmux-next.yml`.

Checkout (1m), three bounded token mints (3m), the reads (2m), plus runner setup.

## note-195

Above `fast-tier-handback-placement: Check out the trusted placement` in `.github/workflows/cmux-next.yml`.

The placement code from the base branch, as macos-placement's.

## note-196

Above `fast-tier: environment` in `.github/workflows/cmux-next.yml`.

The cache saves name the R2 write credentials, which live in the ci-cache-writer
environment (main only; tests/test_ci_pull_request_caches_are_read_only.py). This job
never runs on main, so it still enters no environment: the line changes nothing at run time.

## note-197

Above `fast-tier: CMUX_FAST_TIER_FLEET` in `.github/workflows/cmux-next.yml`.

'report' when fast-tier-fleet ran with a verdict (or none) to report: the steps below then only
report it. A `queued` hand-back runs them in full.

## note-198

Above `fast-tier: Report the build fleet's fast tier verdict` in `.github/workflows/cmux-next.yml`.

The build fleet's verdict, under this job's name: fail and no verdict both fail it.

## note-199

Above `fast-tier: Give this job its own acpmux home` in `.github/workflows/cmux-next.yml`.

own, never the runner's ~/.acpmux, the mini's own daemon
(tests/test_ci_acpmux_job_home.py).

## note-200

Above `fast-tier: clean` in `.github/workflows/cmux-next.yml`.

A reused mini keeps ignored SwiftPM/Cargo/Zig outputs warm. The
default clean=true walks and deletes those trees before checkout;
clean untracked source explicitly below while preserving caches.

## note-201

Above `fast-tier: Discard the workspace repository after a failed checkout` in `.github/workflows/cmux-next.yml`.

As in swift test: a partial clone left in this reused workspace fetches
a missing blob mid-step, unretried. Retry once from a fresh repository.

## note-202

Above `fast-tier: Drop stale submodule checkouts (self-hosted reused workspace)` in `.github/workflows/cmux-next.yml`.

The Swift entries need no submodule (cmux-tui and its ghostty-next build
moved to fast-tier-cargo), so drop whatever a previous job left.

## note-203

Above `fast-tier: Replay the seed's input times` in `.github/workflows/cmux-next.yml`.

A fresh checkout stamps every source with the checkout time, which SwiftPM
reads as "changed". Give each file whose content matches the
seed's the time the seed built it from, so only what changed rebuilds.

## note-204

Above `fast-tier: Stop this job's acpmux daemons and remove its home` in `.github/workflows/cmux-next.yml`.

Also after a failure or a cancel: end the daemon of this job's home and
its agents (shutdown never starts one), then delete the home.

## note-205

Above `fast-tier-cargo` in `.github/workflows/cmux-next.yml`.

The fast tier's cargo and portable script entries: cmux-tui-core, the
layout reducer and performance completeness, run beside the Mac job, so
the Mac runs only Swift. Same gating, flake policy and quarantine list as
fast-tier; its own check name, receipt and concurrency group.

## note-206

Above `fast-tier-cargo: runs-on` in `.github/workflows/cmux-next.yml`.

As cmux-tui.yml's Linux test job: a fork keeps the public or 4-vCPU lane.

## note-207

Above `fast-tier-cargo: env` in `.github/workflows/cmux-next.yml`.

cmux-tui-core's ghostty-vt-sys builds libghostty-vt from the ghostty-next gitlink with zig,
as in cmux-tui.yml (an empty CMUX_GHOSTTY_SRC overrides a runner-level one).

## note-208

Above `fast-tier-cargo: Install Linux build dependencies` in `.github/workflows/cmux-next.yml`.

clang (bindgen's libclang), Zig and Rust come before the reuse key, which
names their versions.

## note-209

Above `fast-tier-cargo: Look for a trusted planner pass` in `.github/workflows/cmux-next.yml`.

24-hour window with zero false skips. Its producer is a trusted push on
feat-cmux-next; pull-request artifacts are evidence, never reusable passes.
CI_REBUILD_MIRROR=0 keeps the old whole-tree mode available as a kill switch.

## note-210

Above `fast-tier-cargo: Cache cargo build` in `.github/workflows/cmux-next.yml`.

Only a feat-cmux-next push saves this build cache; a pull request reads the base
branch's. (The pass record at the end of the job is a separate artifact.)

## note-211

Above `fast-tier-cargo: Fetch the ghostty-next Zig packages (cached, deadlined, retried)` in `.github/workflows/cmux-next.yml`.

ghostty-vt-sys's build.rs runs zig, which downloads the packages itself, once and
unretried: a mid-stream read error failed the job (pkg/highway ReadFailed). Fetch
them first, each attempt under a deadline and retried.

## note-212

Above `fast-tier-cargo: Record rebuild mirror outcome` in `.github/workflows/cmux-next.yml`.

Observe the candidate and the full run together. Before promotion no
candidate skips; after promotion only a trusted push pass can skip.

## note-213

Above `swift-test: cancel-in-progress` in `.github/workflows/cmux-next.yml`.

Report-only PR attempts are superseded by a newer push or rerun.

## note-214

Above `swift-test: environment` in `.github/workflows/cmux-next.yml`.

Same-repository PR tests use the generic picker route (or its Blacksmith overflow), so display labels never gate them.

## note-215

Above `swift-test: generated_files` in `.github/workflows/cmux-next.yml`.

The folded generated files verdict (generated-verdict reads it): fresh, stale, catalog or empty. A
reused pass of a folded run was recorded only with the generated files fresh.

## note-216

Above `swift-test: CMUX_NEXT_RUNNER` in `.github/workflows/cmux-next.yml`.

This job's label (its runs-on): a glaeda-* label means a mini.

## note-217

Above `swift-test: CMUX_CI_REQUIRED_MACOS_SDK_MAJOR` in `.github/workflows/cmux-next.yml`.

The package deploys to macOS 26, so the test runner needs a macOS 26
host and SDK.

## note-218

Above `swift-test: CMUX_NEXT_FOLD_GENERATED` in `.github/workflows/cmux-next.yml`.

The generated files are checked here, on this job's package build, when path routing
picks this job (generated_host): no generated-files job builds the same package and tests.

## note-219

Above `swift-test: Give this job its own acpmux home` in `.github/workflows/cmux-next.yml`.

This job's tests can start acpmux daemons: they get a home of the job's
own, never the runner's ~/.acpmux, the mini's own daemon
(tests/test_ci_acpmux_job_home.py).

## note-220

Above `swift-test: Discard the workspace repository after a failed checkout` in `.github/workflows/cmux-next.yml`.

A blob-filtered checkout by another job leaves a partial clone in this
reused workspace, and a missing blob is fetched from GitHub mid-step,
unretried. Retry once from a fresh repository; a second failure fails.

## note-221

Above `swift-test: Drop stale submodule checkouts (self-hosted reused workspace)` in `.github/workflows/cmux-next.yml`.

A mini reuses its workspace: drop the submodule checkouts a previous
job left (scripts/ci/reset-stale-submodules.sh), as on a fresh checkout.

## note-222

Above `swift-test: Mint the cmux-bot artifact read token` in `.github/workflows/cmux-next.yml`.

off the repository token's hourly budget; a pull request run, or a failed mint,
keeps the workflow token (scripts/ci/job_reuse.py).

## note-223

Above `swift-test: Keep Swift package builds on this owned Mac` in `.github/workflows/cmux-next.yml`.

selection so its fingerprint uses the compiler that runs this job.

## note-224

Above `swift-test: Set up pinned cmux-tui Rust (sidebar layout reducer)` in `.github/workflows/cmux-next.yml`.

(fast-tier.json "sidebar layout reducer") on every feat-cmux-next pull
request and push, so this Mac job runs them only on the events of its own
that fast-tier-cargo does not take: a dispatch or a main push (2026-10-26).

## note-225

Above `swift-test: Setup Bun` in `.github/workflows/cmux-next.yml`.

Activity) and the tests read them: build them from the
sources (cx-vn5) with the bun webviews/package.json pins.

## note-226

Above `swift-test: Give this job its own bun` in `.github/workflows/cmux-next.yml`.

The minis share ~/.bun with workflows that install another bun; this
job runs on its own copy of the pinned one (private-bun.sh).

## note-227

Above `swift-test: Setup Node` in `.github/workflows/cmux-next.yml`.

The webviews app's `vp build` must run on node: on bun it emits
different bytes (build-web-bundles.sh).

## note-228

Above `swift-test: Source key of the web bundles` in `.github/workflows/cmux-next.yml`.

The Linux web-bundles job builds the bundles once per source key and caches them; a
hit installs them here instead of building, and a miss builds them in the next step.

## note-229

Above `swift-test: Restore the web bundles from R2` in `.github/workflows/cmux-next.yml`.

R2 first (feat-cmux-next's bundles, published by the web-bundles job of
its pushes; no credential), then this run's GitHub cache entry.

## note-230

Above `swift-test: Check generated action catalog, surfaces and inventory` in `.github/workflows/cmux-next.yml`.

The generated files checks (CMUX_NEXT_FOLD_GENERATED), on the package and tests built above
and before the catalogs are compiled into the resource bundles, as the generated-files job
runs them. generated-verdict gives their verdict (this job's generated_files output).

## note-231

Above `swift-test: Run package tests (changed suites first, then selected targets)` in `.github/workflows/cmux-next.yml`.

its stacks; each test step timeout stops it holding the runner regardless.
Control tests use tight request deadlines and run in their own process so
they do not compete with the other MainActor-isolated suites.

## note-232

Above `swift-test: Run CloudBringBack cases in fresh processes` in `.github/workflows/cmux-next.yml`.

AppKit/registry state. Run each case in a fresh process so a prior
round trip cannot starve the next case's 60-second action deadline.

## note-233

Above `swift-test: Run the commit-boundary audit in its own process` in `.github/workflows/cmux-next.yml`.

it runs in its own process: another suite's after-commit observer
(a pending AfterFrameCommit, a view's observer not yet released) is
that suite's state, not AppKit's or Core Animation's.

## note-234

Above `swift-test: Run CLI parity tests` in `.github/workflows/cmux-next.yml`.

app/catalog setup can occupy the main actor longer than their real request
deadlines, so they run alone and one test at a time.

## note-235

Above `swift-test: Run state-resource regressions` in `.github/workflows/cmux-next.yml`.

The state-resource event round trips against the real daemon need their
own process: unrelated suites can delay callbacks beyond these tests'
existing deadlines. Every test still runs.

## note-236

Above `swift-test: Give the generated files verdict` in `.github/workflows/cmux-next.yml`.

The folded verdict, for generated-verdict: never this job's own result, so a stale file
does not turn `cmux-next swift test` red, and a red `cmux-next swift test` does not hide a stale file.

## note-237

Above `swift-test: CATALOG` in `.github/workflows/cmux-next.yml`.

failure when the action checks fail with fresh exports too (judge-action-exports.sh): not stale.

## note-238

Above `swift-test: Stop this job's acpmux daemons and remove its home` in `.github/workflows/cmux-next.yml`.

its agents (shutdown never starts one), then delete the home.

## note-239

Above `swift-test: Upload the test helper's crash reports` in `.github/workflows/cmux-next.yml`.

(scripts/cmux-next/swift-test-with-hang-sampler.sh): the crashed
thread names the test that trapped.

## note-240

Above `daemon-test: if` in `.github/workflows/cmux-next.yml`.

This run's own tier on a published tree (path routing's probe), or
same-tree mode after the artifacts workflow published it.

## note-241

Above `daemon-test: permissions` in `.github/workflows/cmux-next.yml`.

actions: read lets the same-tree cmux-tui fetch read the artifacts runs.

## note-242

Above `daemon-test: statuses` in `.github/workflows/cmux-next.yml`.

statuses: write reports a same-tree mode result on the tested commit.

## note-243

Above `daemon-test: generated_files` in `.github/workflows/cmux-next.yml`.

The folded generated files verdict (generated-verdict reads it): fresh, stale, catalog or empty.

## note-244

Above `daemon-test: CMUX_TUI_TREE_KEY` in `.github/workflows/cmux-next.yml`.

A pull request that changes no cmux-tui path runs on the newest
published tree when its own is not ready (path routing's probe).

## note-245

Above `daemon-test: CMUX_NEXT_FOLD_GENERATED` in `.github/workflows/cmux-next.yml`.

The generated files are checked here, on this job's package build, when path routing
picks this job (generated_host): a push it runs on, or a pull request swift-test does
not build. No generated-files job builds the same package and tests.

## note-246

Above `daemon-test: Give this job its own acpmux home` in `.github/workflows/cmux-next.yml`.

This job's tests can start acpmux daemons: they get a home of the job's
own, never the runner's ~/.acpmux, the mini's own daemon
(tests/test_ci_acpmux_job_home.py).

## note-247

Above `daemon-test: ref` in `.github/workflows/cmux-next.yml`.

Same-tree mode tests the commit the tree was probed for.

## note-248

Above `daemon-test: Discard the workspace repository after a failed checkout` in `.github/workflows/cmux-next.yml`.

A blob-filtered checkout by another job leaves a partial clone in this
reused workspace, and a missing blob is fetched from GitHub mid-step,
unretried. Retry once from a fresh repository; a second failure fails.

## note-249

Above `daemon-test: ref` in `.github/workflows/cmux-next.yml`.

Same-tree mode tests the commit the tree was probed for.

## note-250

Above `daemon-test: Drop stale submodule checkouts (self-hosted reused workspace)` in `.github/workflows/cmux-next.yml`.

A mini reuses its workspace: drop the submodule checkouts a previous
job left (scripts/ci/reset-stale-submodules.sh), as on a fresh checkout.

## note-251

Above `daemon-test: Keep Swift package builds on this owned Mac` in `.github/workflows/cmux-next.yml`.

Checkout removes .build. Link the owned Mac's kept build after Xcode
selection so its fingerprint uses the compiler that runs this job.

## note-252

Above `daemon-test: Setup Bun` in `.github/workflows/cmux-next.yml`.

The package's resources include the web bundles (agent pane, pages,
Activity) and the tests read them: build them from the
sources (cx-vn5) with the bun webviews/package.json pins.

## note-253

Above `daemon-test: Give this job its own bun` in `.github/workflows/cmux-next.yml`.

The minis share ~/.bun with workflows that install another bun; this
job runs on its own copy of the pinned one (private-bun.sh).

## note-254

Above `daemon-test: Setup Node` in `.github/workflows/cmux-next.yml`.

The webviews app's `vp build` must run on node: on bun it emits
different bytes (build-web-bundles.sh).

## note-255

Above `daemon-test: Source key of the web bundles` in `.github/workflows/cmux-next.yml`.

The Linux web-bundles job builds the bundles once per source key and caches them; a
hit installs them here instead of building, and a miss builds them in the next step.

## note-256

Above `daemon-test: Restore the web bundles from R2` in `.github/workflows/cmux-next.yml`.

R2 first (feat-cmux-next's bundles, published by the web-bundles job of
its pushes; no credential), then this run's GitHub cache entry.

## note-257

Above `daemon-test: Check generated action catalog, surfaces and inventory` in `.github/workflows/cmux-next.yml`.

The generated files checks (CMUX_NEXT_FOLD_GENERATED), on the package and tests built above
and before the catalogs are compiled into the resource bundles, as the generated-files job
runs them. generated-verdict gives their verdict (this job's generated_files output).

## note-258

Above `daemon-test: Pack the exports for the base autofix` in `.github/workflows/cmux-next.yml`.

The base autofix's exports, on a push or base tier run whose generated files this job checks
(the generated-files job's step of the same name, which that run skips).

## note-259

Above `daemon-test: CMUX_TUI_TREE_WAIT_SECONDS` in `.github/workflows/cmux-next.yml`.

Published before this job starts (probe or same-tree mode): a download.

## note-260

Above `daemon-test: CMUX_TUI_TREE_PUBLISHER_SHA` in `.github/workflows/cmux-next.yml`.

Push and dispatch runs fail fast when the artifacts runs for this
commit were cancelled or superseded (pin-cmux-tui.sh --help).

## note-261

Above `daemon-test: Give the generated files verdict` in `.github/workflows/cmux-next.yml`.

The folded verdict, for generated-verdict: never this job's own result, so a stale file
does not turn `cmux-next daemon tests` red, and a red `cmux-next daemon tests` does not hide a stale file.

## note-262

Above `daemon-test: CATALOG` in `.github/workflows/cmux-next.yml`.

failure when the action checks fail with fresh exports too (judge-action-exports.sh): not stale.

## note-263

Above `daemon-test: Stop this job's acpmux daemons and remove its home` in `.github/workflows/cmux-next.yml`.

its agents (shutdown never starts one), then delete the home.

## note-264

Above `daemon-test: Report the same-tree result on the tested commit` in `.github/workflows/cmux-next.yml`.

Same-tree mode: the result goes on the commit the run was for (a push,
or the pull request head), whichever ref the dispatch ran on.

## note-265

Above `generated-files: if` in `.github/workflows/cmux-next.yml`.

Only where path routing picks it (generated_host): a run that swift-test or daemon-test
builds the package in checks its generated files there (CMUX_NEXT_FOLD_GENERATED), and
generated-verdict gives that verdict.

## note-266

Above `generated-files: concurrency` in `.github/workflows/cmux-next.yml`.

Bind pushes to their exact source head. A stalled old head therefore
cannot occupy the one branch-wide pending slot for every newer head.

## note-267

Above `generated-files: Give this job its own acpmux home` in `.github/workflows/cmux-next.yml`.

This job's tests can start acpmux daemons: they get a home of the job's
own, never the runner's ~/.acpmux, the mini's own daemon
(tests/test_ci_acpmux_job_home.py).

## note-268

Above `generated-files: Discard the workspace repository after a failed checkout` in `.github/workflows/cmux-next.yml`.

A blob-filtered checkout by another job leaves a partial clone in this
reused workspace, and a missing blob is fetched from GitHub mid-step,
unretried. Retry once from a fresh repository; a second failure fails.

## note-269

Above `generated-files: Drop stale submodule checkouts (self-hosted reused workspace)` in `.github/workflows/cmux-next.yml`.

A mini reuses its workspace: drop the submodule checkouts a previous
job left (scripts/ci/reset-stale-submodules.sh), as on a fresh checkout.

## note-270

Above `generated-files: Mint the cmux-bot artifact read token` in `.github/workflows/cmux-next.yml`.

off the repository token's hourly budget; a pull request run, or a failed mint,
keeps the workflow token (scripts/ci/job_reuse.py).

## note-271

Above `generated-files: Keep Swift package builds on this owned Mac` in `.github/workflows/cmux-next.yml`.

selection so its fingerprint uses the compiler that runs this job.

## note-272

Above `generated-files: Setup Bun` in `.github/workflows/cmux-next.yml`.

The package's resources include the web bundles (agent pane, pages,
Activity) and the tests read them: build them from the
sources (cx-vn5) with the bun webviews/package.json pins.

## note-273

Above `generated-files: Give this job its own bun` in `.github/workflows/cmux-next.yml`.

The minis share ~/.bun with workflows that install another bun; this
job runs on its own copy of the pinned one (private-bun.sh).

## note-274

Above `generated-files: Setup Node` in `.github/workflows/cmux-next.yml`.

The webviews app's `vp build` must run on node: on bun it emits
different bytes (build-web-bundles.sh).

## note-275

Above `generated-files: Source key of the web bundles` in `.github/workflows/cmux-next.yml`.

The Linux web-bundles job builds the bundles once per source key and caches them; a
hit installs them here instead of building, and a miss builds them in the next step.

## note-276

Above `generated-files: Restore the web bundles from R2` in `.github/workflows/cmux-next.yml`.

R2 first (feat-cmux-next's bundles, published by the web-bundles job of
its pushes; no credential), then this run's GitHub cache entry.

## note-277

Above `generated-files: Regenerate stale files` in `.github/workflows/cmux-next.yml`.

Only the generated paths are collected into the artifact.

## note-278

Above `generated-files: Stop this job's acpmux daemons and remove its home` in `.github/workflows/cmux-next.yml`.

its agents (shutdown never starts one), then delete the home.

## note-279

Above `generated-files: Record this pass for the same inputs` in `.github/workflows/cmux-next.yml`.

the key, which every pull request and the base can list (scripts/ci/job_reuse.py
takes only passes of this repository's own runs). Never from a fork pull request.
An uncached (no_reuse) run records too.

## note-280

Above `release-compile-fast` in `.github/workflows/cmux-next.yml`.

source without occupying a Mac runner.
Keep the fast-check wrapper's name distinct from the admission gate below:
an unavailable wrapper is a successful job but is not a Release compile.

## note-281

Above `release-compile-fast: Run the fast fleet compile check` in `.github/workflows/cmux-next.yml`.

A compile failure reds this step, not the job; the admission job reds verdict=fail under the
gate name. No verdict (refused, killed, died first): release-compile takes over.

## note-282

Above `release-compile-fast: GATEWAY` in `.github/workflows/cmux-next.yml`.

Set when this job took an idle gateway runner; empty on the Linux route.

## note-283

Above `release-compile-fast: RESULTS` in `.github/workflows/cmux-next.yml`.

The build fleet's compile results (compile-status reads the same endpoint, unauthenticated).

## note-284

Above `release-compile-fast-admission: timeout-minutes` in `.github/workflows/cmux-next.yml`.

The request fetches feat-cmux-next's recent history to find the newest
commit with the published tree (the --tree-ready search).

## note-285

Above `release-compile: timeout-minutes` in `.github/workflows/cmux-next.yml`.

One-architecture Release (-O, whole-module) xcodebuild of CmuxNextApp
with the nightly's Xcode. Debug `swift build` and Xcode 27 accept code
that this rejects; without this job such code fails only the nightly.

## note-286

Above `release-compile: CMUX_NEXT_RUNNER` in `.github/workflows/cmux-next.yml`.

This job's label (its runs-on): a glaeda-* label means a mini.

## note-287

Above `release-compile: Discard the workspace repository after a failed checkout` in `.github/workflows/cmux-next.yml`.

A blob-filtered checkout by another job leaves a partial clone in this
reused workspace, and a missing blob is fetched from GitHub mid-step,
unretried. Retry once from a fresh repository; a second failure fails.

## note-288

Above `release-compile: Drop stale submodule checkouts (self-hosted reused workspace)` in `.github/workflows/cmux-next.yml`.

A mini reuses its workspace: drop the submodule checkouts a previous
job left (scripts/ci/reset-stale-submodules.sh), as on a fresh checkout.

## note-289

Above `release-compile: Mint the cmux-bot artifact read token` in `.github/workflows/cmux-next.yml`.

off the repository token's hourly budget; a pull request run, or a failed mint,
keeps the workflow token (scripts/ci/job_reuse.py).

## note-290

Above `release-compile: Warn on missing Release bundle notices` in `.github/workflows/cmux-next.yml`.

remains authoritative, but this names an unmapped file during review.

## note-291

Above `release-compile: Chromium Objective-C contract against the pinned engine` in `.github/workflows/cmux-next.yml`.

The pinned engine's Objective-C selectors for NSApp and its delegate
against the reviewed contract (scripts/cmux-next/chromium-objc-contract.json):
an engine that can send cmux an unreviewed selector fails here, before
it ships ("unrecognized selector", 2026-10-20).

## note-292

Above `swift-exports-cache: if` in `.github/workflows/cmux-next.yml`.

generated-files skips a push whose generated files daemon-test checks (CMUX_NEXT_FOLD_GENERATED);
generated-verdict gives that verdict.
!cancelled() and each need's result: the implicit success() reads every ancestor, and pr-quiet-period skips on a push.

## note-293

Above `request-nightly-next: Drop stale submodule checkouts (self-hosted reused workspace)` in `.github/workflows/cmux-next.yml`.

A mini reuses its workspace: drop the submodule checkouts a previous
job left (scripts/ci/reset-stale-submodules.sh), as on a fresh checkout.

## note-294

Above `cmux-scheme-compile: if` in `.github/workflows/cmux-next.yml`.

This run's own tier on a published tree (path routing's probe), or
same-tree mode after the artifacts workflow published it.

## note-295

Above `cmux-scheme-compile: permissions` in `.github/workflows/cmux-next.yml`.

actions: read lets the same-tree cmux-tui wait read the artifacts runs.

## note-296

Above `cmux-scheme-compile: statuses` in `.github/workflows/cmux-next.yml`.

statuses: write reports a same-tree mode result on the tested commit.

## note-297

Above `cmux-scheme-compile: BASH_ENV` in `.github/workflows/cmux-next.yml`.

scripts/install-rust-ci.sh appends to a set BASH_ENV; keep it unset here (scripts/ci/api_call_log/env.sh).

## note-298

Above `cmux-scheme-compile: CMUX_NEXT_RUNNER` in `.github/workflows/cmux-next.yml`.

This job's label (its runs-on): a glaeda-* label means a mini.

## note-299

Above `cmux-scheme-compile: CMUX_TUI_TREE_KEY` in `.github/workflows/cmux-next.yml`.

A pull request that changes no cmux-tui path runs on the newest
published tree when its own is not ready (path routing's probe).

## note-300

Above `cmux-scheme-compile: Require the requested DEV daily commit` in `.github/workflows/cmux-next.yml`.

A dev_daily run (direct or same-tree) builds only the SHA the
dispatcher asked for. A merge that moved feat-cmux-next first must
fail here: an empty success would read as that tip being published.

## note-301

Above `cmux-scheme-compile: ref` in `.github/workflows/cmux-next.yml`.

Same-tree mode tests the commit the tree was probed for.

## note-302

Above `cmux-scheme-compile: Discard the workspace repository after a failed checkout` in `.github/workflows/cmux-next.yml`.

A blob-filtered checkout by another job leaves a partial clone in this
reused workspace, and a missing blob is fetched from GitHub mid-step,
unretried. Retry once from a fresh repository; a second failure fails.

## note-303

Above `cmux-scheme-compile: ref` in `.github/workflows/cmux-next.yml`.

Same-tree mode tests the commit the tree was probed for.

## note-304

Above `cmux-scheme-compile: Drop stale submodule checkouts (self-hosted reused workspace)` in `.github/workflows/cmux-next.yml`.

A mini reuses its workspace: drop the submodule checkouts a previous
job left (scripts/ci/reset-stale-submodules.sh), as on a fresh checkout.

## note-305

Above `cmux-scheme-compile: if` in `.github/workflows/cmux-next.yml`.

Before the product lookup: a key with no capture compiles instead of reusing a product
(a reused product compiles nothing, so there would be no build to capture).

## note-306

Above `cmux-scheme-compile: timeout-minutes` in `.github/workflows/cmux-next.yml`.

The lookup waits out a rate limit for at most 10 minutes (hybrid_ref_capture.py have).

## note-307

Above `cmux-scheme-compile: HYBRID_REF_SETTINGS` in `.github/workflows/cmux-next.yml`.

The compile step's build-line settings, one NAME=VALUE a line (not as env: only the
compile step may carry them).

## note-308

Above `cmux-scheme-compile: SKIP_REASON` in `.github/workflows/cmux-next.yml`.

format(): an unset variable is null, and null == '0' is true (both coerce to the number 0).

## note-309

Above `cmux-scheme-compile: SWIFT_COMPILATION_MODE` in `.github/workflows/cmux-next.yml`.

A repository variable the compile step reads changes the product but not this file: key it.

## note-310

Above `cmux-scheme-compile: Fetch the same-tree cmux-tui` in `.github/workflows/cmux-next.yml`.

and runs check-daemon-capabilities.sh on it (Debug builds).

## note-311

Above `cmux-scheme-compile: CMUX_TUI_TREE_WAIT_SECONDS` in `.github/workflows/cmux-next.yml`.

See the package test job above. The helper compares the merge tree
with its first parent and waits for the base artifact when equal.
Published before this job starts (probe or same-tree mode): a download.

## note-312

Above `cmux-scheme-compile: CMUX_TUI_TREE_PUBLISHER_SHA` in `.github/workflows/cmux-next.yml`.

Push and dispatch runs fail fast when the artifacts runs for this
commit were cancelled or superseded (pin-cmux-tui.sh --help).

## note-313

Above `cmux-scheme-compile: Install Go for the embedded tailnet archive` in `.github/workflows/cmux-next.yml`.

The same-tree fetch above also brought this tree's acpmux (built once
with the cmux-tui binaries, cmuxterm-hq#1279). A tree published before
the tree build carried acpmux has none, and this compiles it.

## note-314

Above `cmux-scheme-compile: Restore the web bundles from R2` in `.github/workflows/cmux-next.yml`.

its pushes; no credential), then this run's GitHub cache entry.

## note-315

Above `cmux-scheme-compile: Install the restored web bundles` in `.github/workflows/cmux-next.yml`.

--from checks the tree is complete and that its generated inspector page
is the committed one, then installs and stamps it. A refusal builds below.

## note-316

Above `cmux-scheme-compile: Give this job its own bun` in `.github/workflows/cmux-next.yml`.

The minis share ~/.bun with workflows that install another bun; this
job runs on its own copy of the pinned one (private-bun.sh).

## note-317

Above `cmux-scheme-compile: Setup Node` in `.github/workflows/cmux-next.yml`.

The webviews app's `vp build` must run on node: on bun it emits
different bytes (build-web-bundles.sh).

## note-318

Above `cmux-scheme-compile: CMUX_NEXT_DEV_VM_CACHE` in `.github/workflows/cmux-next.yml`.

A miss is a restore that succeeded (singlefile fills the line); a failed restore
compiles as before, whole-module with no cache.

## note-319

Above `cmux-scheme-compile: if` in `.github/workflows/cmux-next.yml`.

Only a vm-mode (singlefile) build's cache: a whole-module one would replay nothing.

## note-320

Above `cmux-scheme-compile: Record this host's cache for the next landing's placement` in `.github/workflows/cmux-next.yml`.

A host build moved this host's cache: the record the next landing's placement reads.

## note-321

Above `cmux-scheme-compile: if` in `.github/workflows/cmux-next.yml`.

A same-tree dispatch compiles inputs.same_tree_sha, not its run's head_sha (the record's commit).

## note-322

Above `cmux-scheme-compile: Record the DEV Release app under its input key` in `.github/workflows/cmux-next.yml`.

The record a later run on the same inputs looks up (dev_release_product_reuse.py lookup):
this run's product artifact, its SHA-256 and where the bytes were compiled (provenance).

## note-323

Above `cmux-scheme-compile: SWIFT_MODE` in `.github/workflows/cmux-next.yml`.

Reporting only (the key keeps the requested mode): what `auto` resolved to, the reused source's on a hit.

## note-324

Above `cmux-scheme-compile: if` in `.github/workflows/cmux-next.yml`.

Keep packaging independent of any earlier step's failure. The
app-producing compile is the admission boundary; unrelated checks
and tests are separate jobs and must not suppress this artifact.

## note-325

Above `cmux-scheme-compile: HYBRID_REF_SETTINGS` in `.github/workflows/cmux-next.yml`.

The compile step's build-line settings, one NAME=VALUE a line (not as env: only the
compile step may carry them).

## note-326

Above `crash-ends-app` in `.github/workflows/cmux-next.yml`.

The crash gate runs in cmux-scheme-compile on the app that job built. This
job is its check: red when a crash froze the app instead of ending it.
A push's compile that a newer push replaced while it waited for its
concurrency group is no red here: the newer push's run carries the verdict
(scripts/ci/needs_verdict.py SUPERSEDED_RULE).

## note-327

Above `crash-ends-app: Report the same-tree result on the tested commit` in `.github/workflows/cmux-next.yml`.

Same-tree mode: the result goes on the commit the run was for (a push,
or the pull request head), whichever ref the dispatch ran on.

## note-328

Above `dev-landing-compile: environment` in `.github/workflows/cmux-next.yml`.

The fleet-shared compile cache (scripts/cmux-next/dev_cas_seed.py) is on once
vars.CMUX_NEXT_DEV_CAS_URL names its store. Its token lives in next-dev-cas, an
environment whose deployment branch is feat-cmux-next only; this job runs only on a
feat-cmux-next push.

## note-329

Above `dev-landing-compile: BASH_ENV` in `.github/workflows/cmux-next.yml`.

scripts/install-rust-ci.sh appends to a set BASH_ENV; keep it unset here (scripts/ci/api_call_log/env.sh).

## note-330

Above `dev-landing-compile: CMUX_NEXT_RUNNER` in `.github/workflows/cmux-next.yml`.

The placed label's first entry (a glaeda-* label means a mini).

## note-331

Above `dev-landing-compile: Look up the DEV Release app compiled on the same inputs` in `.github/workflows/cmux-next.yml`.

The same key and lookup as cmux-scheme-compile's (a DEV run that compiled these inputs first).

## note-332

Above `dev-landing-compile: CMUX_NEXT_DEV_CAS_URL` in `.github/workflows/cmux-next.yml`.

The shared compile cache: compile-dev-release.sh hands the tokens to the seed restore
alone and unsets them before the build.

## note-333

Above `dev-landing-compile: Publish the compile cache seed` in `.github/workflows/cmux-next.yml`.

for the next landings' seed restore (dev_cas_seed.py). Never fails the landing.

## note-334

Above `dev-landing-compile: SWIFT_MODE` in `.github/workflows/cmux-next.yml`.

Reporting only (the key keeps the requested mode): what `auto` resolved to, the reused source's on a hit.

## note-335

Above `dev-landing-compile: Report the landing compile` in `.github/workflows/cmux-next.yml`.

Where this landing compiled and how far its cache was: the host, the commit the cache
last held, the gap, and the overflow. A host build leaves the record the next
landing's placement reads (cmux-next-dev-cas-holder-<host>).

## note-336

Above `request-cmux-next-dev-publish: environment` in `.github/workflows/cmux-next.yml`.

The App key is a repository secret; this is the credential-free environment
macos-placement mints the same App's token under (test_supplychain_security.py).

## note-337

Above `request-cmux-next-dev-publish: timeout-minutes` in `.github/workflows/cmux-next.yml`.

The GITHUB_TOKEN fallback may wait up to an hour for the budget's reset.

## note-338

Above `request-cmux-next-dev-publish: Record source queue and handoff receipt` in `.github/workflows/cmux-next.yml`.

Evidence only: a refused read must never hold up the dispatch below.

## note-339

Above `request-cmux-next-dev-publish: Dispatch with GITHUB_TOKEN, waiting through a rate limit` in `.github/workflows/cmux-next.yml`.

for the budget's reset and tries again, at most 3 tries and an hour of
waiting in all (the bounded wait of scripts/ci/gh_budget_wait.sh, #25434);
a refused request did nothing on GitHub's side, so the retry is safe.

## note-340

Above `pr-red-checks` in `.github/workflows/cmux-next.yml`.

compared with the base's run: ci.yml and cmux-next-guards.yml call it after their own checks.

## note-341

Above `push-attribution: if` in `.github/workflows/cmux-next.yml`.

Also a same-tree mode run for a feat-cmux-next push: the tree jobs of a
push whose tree was published after its run probed it run there. And a
base tier run (or its same-tree run): the range since the base tier last
passed holds the landings it covers.

## note-342

Above `push-attribution: Fetch the branch's recent commits` in `.github/workflows/cmux-next.yml`.

The range and its pull requests come from first-parent history (commits only, no
trees), not the compare and commits/{sha}/pulls APIs; a failed fetch leaves the API path.

## note-343

Above `push-attribution: Mint the cmux-bot read token` in `.github/workflows/cmux-next.yml`.

The Actions reads (about 40 runs' jobs) use a cmux-bot token, off the repository
token's hourly budget; this job runs only for feat-cmux-next pushes and dispatches.
Comments stay on the workflow token. A failed mint leaves every read on it.

## note-344

Above `release-compile-revert: environment` in `.github/workflows/cmux-next.yml`.

The environment macos-placement already takes on a push for the same App key; push-only here.

## note-345

Above `release-compile-revert: uses` in `.github/workflows/cmux-next.yml`.

The newest tip, so the revert applies to what is there now.

## note-346

Above `overflow handoff` in compile-status in `.github/workflows/cmux-next.yml`.

With the results service down and no fallback compile in the run (note-82), a pull request's compile-status no longer
posts `error` and fails. On 2026-11-10 from 19:51Z that failed the job on every pull request (#38440, #40696, #40742),
and each one waited for a person. It now posts cmux-next/compile `pending`, starting with the marker `[overflow]`, and
ends green. The overflow compile takes the head from there: while the service is down, and for any head still pending
with `[overflow]` after it comes back, it compiles that exact head (recipe 2, `--app --release`) and posts
cmux-next/compile success or failure as cmux-bot, the same poster as here. It queues at its cap, dispatches a head
once, and once more only when that run gave no verdict. A pending status is never a pass, so the gate holds the pull
request until the verdict comes. A feat-cmux-next push with no fallback (superseded) still posts `[no-verdict]`
`error`, since the overflow compile takes only pull request heads.

`tests/test_ci_cmux_next_compile_status.py` `test_a_pull_request_with_no_fallback_hands_off_to_the_overflow_compile`
runs the real step against a 530.
