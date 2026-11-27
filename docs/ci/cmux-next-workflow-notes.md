# cmux-next.yml: the longer notes (frozen: a new note is its own file in [`docs/ci/cmux-next-workflow-notes/`](cmux-next-workflow-notes/README.md))

GitHub refuses a workflow file over 500 KB (512,000 bytes) before any job starts, so every pull request
and push loses the whole workflow (2026-11-10: #40348 took the file to 512,883 bytes). The longest
explanations live here; the workflow keeps a `# Why: ...#note-N` line where each stood.
`tests/test_ci_workflow_file_size.py` holds every workflow under the limit with room to spare.

## note-1

Above `macos-placement`'s step `Wait until the pull request has had no push for the quiet period` in
`.github/workflows/cmux-next.yml` (the `pr-quiet-period` job until 2026-11-21).

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
3 to 8 Linux runner-minutes before the newer push cancels its run (41% of runs).
Since 2026-11-21 the wait is macos-placement's first step, not a job of its own (cmuxterm-hq#16094: the job was
1.64% of pull request runner-minutes over 11-13..19 and never red; Leo, 2026-11-21: "id rather we simply cut
shit now and revisit later"). Only a run that places Mac jobs sleeps, on macos-placement's Linux pool runner, and
the routing before it counts toward the window; a fork pull request, or a run with vars.CI_PR_POOL_OWNED unset,
has no macos-placement and so no wait. The job it replaced slept on the linux_2 pool. Neither is
on hosted Ubuntu: the org runs at most 20 hosted jobs at once, and on 2026-11-07 its
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
the tier runs in full, with 60 minutes (note-39), where fast-tier-handback-placement's fresh reading sends it
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
record. Otherwise an idle nightly slot (NIGHTLY_LABEL, from vars.CI_DEV_COMPILE_NIGHTLY_RUNNER, default
glaeda-nightly-std-xcode-26.6, picked as nightly_build_runner.owned_route() picks the nightly's own): the
runner hook ranks the DEV daily compile nightly-tier, and Leo's rule is "Nightlies come first on the fleet".
Otherwise the shared DEV slot label at once: it never waits. Never the shared side label: GitHub
hands that label's queue out oldest first, so an idle side runner in the one listing is no place in line,
and the compile joins the tail behind every PR job there (run 44941204257, 2026-11-21: 76 min on
glaeda-side-std-xcode-26.6 behind about 130 jobs, then a capacity refusal; Leo's rule: "Nightlies come first
on the fleet"). With nothing owned idle it overflows to a moving Blacksmith macOS label, else waits on the DEV
slot, else prints no route and the compile keeps macos-placement's. It places every attempt, not only the
first: a re-run (the owned-pool rescue's after a refusal) is placed again instead of falling to the side
label's tail. A warm host compiles in about
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
This job posts with a cmux-bot token (statuses: write) minted from the repository secret.
Any other route that compiles the head (a Blacksmith job of this repository) posts the same
context with the same mapping.

The controller posts it too, on the same-repository pull request heads it compiles, as the
manaflow-checks App (the statuses: write App the pool's required checks already post from;
cmuxterm-hq `build-fleet/cmd/controller/compile_status_poster.go`), with the same mapping at
each receipt transition. Its receipt then says `"status_poster": "controller"`, and this job
ends as soon as it reads that on a queued or running receipt, instead of holding a runner
through the compile (77.7 runner-hours in 6 h on the pull request leg, 2026-11-22 17:00-23:00Z).
A pull request head's first read takes the receipt as it is (`wait=1`), so the mark is seen at
once; the recipe check runs first, so a marked receipt of another recipe is still a mismatch.
A receipt without it (a push head, or a
controller that does not post) is waited for and relayed as before. The landing gates trust
both posters (`scripts/ci/base_red_excuse.py` `COMPILE_STATUS_POSTERS`).

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
primary reset, at least 60 s and twice as long each try (a retry inside a secondary limit extends it), up to the
step's own end (`post_end`, 54 min after the step starts, inside the App token's hour; hq#11485: cmux#43659's success
post met the cmux-bot installation's spent pool with its reset past the old 600 s budget, stopped after one try, and
the passed check sat pending 2.5 h); a pending post's explicit budget still bounds its wait; a 5xx or no answer tries again in 10 s; any other refusal (a bad token, no permission) is final at once. The pending
post only shows the wait, so it gets 30 s and a refusal is a warning: on 2026-11-11 from 02:38Z a ten-minute 403 rate
limit on cmux-bot failed this job on #40351, #40942, #41007 and the base push at the pending post, before any compile
was read. A terminal post that still fails prints `NO_VERDICT: GitHub refused the cmux-next/compile verdict ...;
re-run this job, RUN_URL` (the status stays as last posted, so the line says what to do), then the job's own
`cmux-next/compile is not a pass for SHA (STATE)` line: no verdict for base_red_excuse.py (`NO_VERDICT`) for every state but `fail`, which stays a compile red.
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
waited 55 minutes for a runner). Its owned labels (runner, the side label, the gui and session
labels) are as stale, so from attempt 2 on a Mac job takes one only while this equals its own
run_attempt too; a carried reading, whoever re-ran the run, sends it to the moving Blacksmith label
(vars.MACOS_RUNNER_26, else RUNNER_POOLS.macos_26), as a push Release compile's fallback does.
cmux#38484's run 42728317341 (2026-11-10) kept `cmux app scheme compile (Debug)` on
glaeda-side-std-xcode-26.6 through three re-runs of failed jobs: 2 h, 15 h and 1 h 49 min queued
(tests/test_ci_next_macos_cascade.py CarriedPlacement). The placement runs on attempt 1 and on every
rescue bot attempt, placed afresh (next_macos_cascade.bot_rerun()); a person's re-run past attempt 1 carries
attempt 1's reading and never takes an owned label. Run 43716323834's attempt 5 (#43733, 2026-11-15) queued
on glaeda-side-std-xcode-26.6 while glaeda-gui-std-xcode-26.6 had nothing queued, because placement then ran only
up to the bot's attempt 3; fast-tier-handback-placement's
reading is gated on its own placed_attempt the same way.

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

## note-26

Above `checks: needs` in `.github/workflows/cmux-next.yml`.

On feat-cmux-next it runs in the base tier run on the tip (cmux_next_base_tier.py), at most once every 15
minutes, not on each push. Leo, 2026-11-21: "whatever we need to cut, we cut", and "maintaining a partial
semblance of checks. and we can infrequenrly have fuller checks". It ran on all 80 pushes in 21-24Z on
11-21: 739 runner-minutes, 9.2 a push. A pull request into feat-cmux-next skips it (unless labelled
full-ci), so the base tier run is still the base run a pull request's red is compared with. A red names
its commit range: the previous base tier run's tip to this one ("Previous checked tip" below), the range
"Pushed commits add no violations" sweeps and base_red_checks.py compares against.
vars.CMUX_NEXT_BASE_TIER_COALESCE = '0' puts it back on every push, with the base tier.
Earlier (Leo, 2026-10-19; cx-g34i had dropped it) each push ran it so a direct push's red showed on that push.

## note-27

Above `checks: Start the slow checks in the background` in `.github/workflows/cmux-next.yml`.

The slow independent checks run concurrently in the background, at most one per CPU, from here
on (one after another they took about 7 of the job's 8.4 min). Each of their steps below waits
for its own commands, prints their output and keeps its name, id and outcome. A `[step-id]`
line names the step the commands under it belong to; the longest commands start first.
Not here: "Pushed commits add no violations" deepens the clone and writes its step summary.

## note-27c

Above `checks: Start the slow checks in the background` in `.github/workflows/cmux-next.yml` (its deadline).

cmux#42669's checks job 132210422131 (cmuxs-mac-mini-6-glaeda-3, 2026-11-13) was cancelled at its
35 min cap inside "Tier routing": the step waited from 22:57:35 to 23:05:55 for its 7 background
commands, which had run since 22:38:10, and the cancel named none of them. The pool now gets a
deadline 5 min (POOL_TAIL_SECONDS) before the job's cap, counted from the event file the runner
writes at Set up job (the runner hook's wait for a host lock counts against the cap too). A command
still running at it stops (scripts/ci/timeout.sh), fails by name with "timed out at the pool
deadline", and the job reaches "Fail on any red check". Each wait prints, once a minute, which of
its commands are still running. The 5 min leave room for the steps after the waits (about 2.5 min
on Linux). That run's mini lacked GNU `timeout`, so the compile-status step tests' bounded reads
(`timeout "$left" curl`) failed at once and each read loop spun until its test's 60 s subprocess
bound; note-27b's preflight now stops such a runner in its first minute.

## note-27b

Above `checks: Prepare check Python (PyYAML) and timeout` in `.github/workflows/cmux-next.yml`.

portable-placement may put this job on a free mini, whose Homebrew python3 has no
PyYAML and whose PATH has no GNU `timeout`. On 2026-11-11 the job went red there
with `ModuleNotFoundError: No module named 'yaml'` (56 times) and `timeout: command
not found` (cmux13s-mac-mini-glaeda-5 job 130627140300, cmuxs-mac-mini-6-glaeda-3
job 130624833630), and passed on Blacksmith Linux at the same tree. The job brings
its own venv first on PATH wherever it lands, as cmux-next-guards.yml's tooling
tests do; tests/test_portable_jobs_bring_their_python.py keeps every mini-eligible
job that runs Python tests doing so.

A mini also has no node and no Homebrew coreutils, so the old `gtimeout` link never
fired there. On 2026-11-13 every mini-placed checks job seen failed on both (`node:
command not found`, exit 127; `timeout: command not found`): cmux10s, cmux11s,
cmux13s, cmux14 and cmuxs-mac-mini-6. The step now puts GNU `timeout` on PATH as
`timeout`, else `gtimeout`, else a shim to scripts/ci/timeout.sh (its perl
watchdog); installs node 24.22.1 with scripts/ci/ensure-setup-node.sh when there is
no node (tool cache, else nodejs.org, checksummed); and ends with a preflight on the
PATH the next steps get that fails at once naming each tool still missing.
tests/test_cmux_next_checks_workflow.py's ChecksBringNodeAndTimeoutToAMini runs the
step under a PATH without them.

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
19.8 minutes (#38181's data), so it gets 60 (it was 35; a 2026-11-24 sample of cancels at the cap
showed a dense tail of passes just past 35): a slow cold build still gives the verdict.

An app FFI re-pin (`ffi_repin`) changes the CCmuxAppFFI binary target, so every
CmuxNext module rebuilds cold before `HandlerCoverageTests` runs. With 20
minutes, #43935's tier hit the job limit on cmux23-glaeda-3 (2026-11-15) and
showed `cancelled`, not red. The re-pin merged, and every Debug launch then
stopped in `HandlerCoverage.verify` (three terminal-to-chat catalog rows without
handlers) until #44082. A re-pin gets 50 minutes. Its `Run the fast tier` step
has a 45-minute limit: a step past its limit fails the job, so a slow re-pin
build shows red with the step named, never `cancelled`. Other runs keep the job
limit (the step's 360 is never reached).

Other runs get 30, not 20. An owned mini holds one seed root per mini, so most fast-tier jobs take a shared
root, and a shared root often starts cold ("evicted", "roots busy"). A cold CmuxNext build-tests build is about
20 minutes of compiling, and the tests follow. Between 03:00 and 05:00Z on 2026-11-22, 18 of the job's 20
cancels stopped at the 20-minute limit (20.3 to 20.6 min). They were 4,100 runner-min/day, against a success
p50 of 6.4 min. Every log that was read showed a cold start and was 99% through compiling at the limit (job
137081242103: step 14646 of 14698). The cancelled runs were then re-run (attempts 2 to 5), each one cold
again, so none of them gave a verdict. With 30, a cold run finishes once and reports pass or fail.

Other runs get 60, not 30. On 2026-11-22, run 45002704947 (cmux#49316) was cancelled at 30 three times
(job 137149824562 on cmux18-glaeda-1, 08:35:54 to 09:05:06Z; job 137170836244 on cmux13s-mac-mini-glaeda-3,
10:05:56 to 10:36:24Z). Each started cold: the seed root was refused ("busy, unprovisioned or has no room") and
every shared root was busy, so the job skipped the R2 restore. `swift build --build-tests` for CmuxHomeRender
took 37 s. For CmuxNext it ran 28.5 min, reached step 13998 of 14000 (CmuxNextAppTests) and was cancelled
before any test started. With 60, a cold run gets past its last link and gives a verdict.

Other runs get 120, not 60. 60 was too close: on 2026-11-22, job 137256550516 (run 45037691864, cmux#49316 head
3a5c858edcfe, cmux9s-mac-mini-glaeda-5) passed in 58.0 of its 60 minutes (97%). It started cold ("evicted, 0.0
GiB kept", seed root refused). The hook gave it 3 cores and its shim passes `swift build --jobs 3`. CmuxNext
build-tests ran 16:06:32 to 16:57:59Z (51.5 min), and the 8 entries then passed in 40 s. #50336's 5-core
cold run took 32.7 min. The build time scales with the core grant, about 155 core-minutes. A 2-core cold
run is about 78 min of building plus 5 of setup, so it needs at least 83 min. 120 keeps that at 69% of the
cap and a 3-core run at 48%. A 1-unit grant (about 155 min) still cannot finish; that is a placement problem,
not something to cover with the cap.

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

Building the package's reducer FFI can rewrite its workspace's lockfile
(cmux-layout-reducer-ffi is a member of the app FFI workspace, so the lock is
cmux-tui/crates/cmux-app-ffi/Cargo.lock). Put the checkout back immediately before
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

It runs after compile-status, which already waits for the same fleet compile of this push. Before,
both jobs waited on it side by side, about 15 runner-min each per push (and on a gateway Mac with no
GNU `timeout`, the reader said `none` and the gateway compiled the head again). When compile-status
passed with no handoff, this job skips the gateway and reads that verdict on Linux in seconds; any
other compile-status outcome keeps the gateway or Linux choice above.
When compile-status read no result in its 40-min wait (its `state` output `none`), this job does
not wait again: the Linux reader hands to the Mac fallback at once and a gateway compiles without
reading first. The fallback then starts after one wait (compile-status's 40 min), not two in a row;
before this order it started after the fast check's own 20 min, a rare path (the fleet never recorded the push).

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

Was above `pr-quiet-period: runs-on` in `.github/workflows/cmux-next.yml`; that job is now macos-placement's
quiet period step (note-1), which takes macos-placement's runner. Kept for the history.

A fork pull request's sleep takes the fixed 2 vCPU label like every fork route (no pool read).

## note-86

Above the quiet period step's `continue-on-error` in `macos-placement`, `.github/workflows/cmux-next.yml`.

A failed or timed-out wait never holds the checks: the step continues on error, and macos-placement places the
Mac jobs after it.

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

The event's labels, used only when the live read fails. path_route reads
the pull request's labels live on every attempt and exports them as
`needs.path_route.outputs.labels` (`,a,b,`); every job reads that, not
`github.event.pull_request.labels`. On 2026-11-25 (#53099, cmux#56909) a
synchronize event delivered after full-ci was added carried no labels; it
shared the concurrency group, cancelled the labeled run, and deferred every
Mac tier. Adding full-ci or dev-build and re-running also routes on them.

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

A same-repository run reads the linux_16 pool (GCP first, then Blacksmith), not linux_8: linux_8 is led
by the Freestyle rung (#56349), and on Freestyle VMs this job mostly never got to its tests. Controller
timing records, 2026-11-25 18:44Z to 2026-11-26 08:49Z: of 653 runs on `fsr-*` runners 98 passed, 243 hit
the 30 min job timeout (GitHub reports a timed-out job as cancelled: 7,854 min, the "cancelled" half of the
job's minutes) and 277 failed in setup (Set up job, checkout averaging 578 s against 69 s, apt, zig: 4,817
min). On the GCP pool the same job passed 478 of 583 runs, median 15.5 min. 16 was already the overflow arm's size, so that
arm is gone (linux_sizes: size 16, no failover).

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

The key is the pinned toolchain and lockfiles (`hashFiles` of `cmux-tui/rust-toolchain.toml`,
`cmux-tui/Cargo.lock`, `.cargo/config.toml`), not rust-cache's environment hash, which also hashes every
toolchain `rustup toolchain list` shows. The base push saves on Blacksmith (hash `b69e319b`). The owned
Linux pool hosts each keep different leftover toolchains, so each computed its own hash (`db011040`,
`fabb63b8`, `0422658f`, `d8989acf`), found no cache and compiled cold for 10-14 minutes. In 03:00-05:00Z
on 2026-11-22, every pool-host run sampled found no cache and took 14.6-17.8 min or hit the 20-minute
limit. Every Blacksmith run sampled restored the cache and took 6.7-9.2 min. Of the job's 34 cancels in
those two hours, 11 were at the limit (2,775 runner-min/day). Both hosts build at
`/home/runner/work/cmux/cmux` with the pinned toolchain, and cargo's fingerprints check every reused
crate. acpmux tests made the same fix in #49482. `cmux-next-car-guards.yml` reads this cache with the
same key.

The same toggle is now on every `Swatinem/rust-cache` step (42 more in 27 workflows; `cloud-journey-prod.yml` runs main's copy on its schedule, so it is left for a main PR). The macOS-on-Linux build (`cmux-tui-build-package.yml`) showed it: after #49976 saved its first entry (key hash `2a69944b`, 2026-11-22 19:26Z), the next 4 sampled legs on pool runners computed `6ec71d0a`, `1ca27fd1`, `6ec71d0a` and `2a69944b`. The difference was `rustup toolchain list`: 1.95.0 alone, or with 1.98.1 and 1.100.0 left over. All 4 found no cache, and cargo took 20 min each. In the 11.5 h after the save, green `build aarch64-apple-darwin` legs averaged 33.3 min on pull requests and lanes (25.7 before) and 29.5 min on feat-cmux-next (29.7 before). The entry was evicted from the full store by 07:00Z on 11-23.

## note-210b

Above `fast-tier-cargo: environment`, `fast-tier-cargo: Key the cargo build in R2` and `Strip the workspace's own output before the R2 save` in `.github/workflows/cmux-next.yml`.

note-210 (#49838) gives pool hosts and Blacksmith one key; this note covers the store. The GitHub cache store sits at its 10 GB cap (22 entries, most of them 0.6-1.1 GB bun and playwright caches on
pull request refs), so the about 470 MB build a feat-cmux-next push saves there is evicted within minutes. A
Blacksmith runner reads Blacksmith's own store and hits; a cmux-runner-pool runner read "No cache found" and
compiled all ~495 crates: 650 s for the cargo step against 325 s on Blacksmith, the median job 14.7 min against
7.4 (controller timing feed, 2026-11-22 01:00-05:30Z). Once linux_8 began landing the job on the pool (01:24Z),
fast-tier-cargo went from 291 to 488 runner-hours a day.

Off Blacksmith the job now restores `cmux-tui/target` and the cargo registry from R2 (scripts/ci/r2-cache.sh,
public reads, no credentials, so pull requests read it too). The key is the cmux-tui lockfiles, toolchain file,
rustc and cargo versions, plus a hash of the workspace path (Blacksmith's `_work` and the pool's `work` paths
make different fingerprints); a lockfile change restores the newest entry under the same workspace prefix.
A feat-cmux-next push off Blacksmith that missed the exact key strips the workspace crates' own output
(scripts/ci/cargo_target_strip.py, what rust-cache's cleanup drops) and saves; r2-cache.sh skips a key that
exists. Retention is r2_cache_prune.py's default (30 days, pointers kept).

Only a feat-cmux-next run enters next-cache-writer (deployment branch feat-cmux-next only) and holds the R2
write credentials, for NEXT's own bucket cmux-ci-cache-next (as note-171); a pull request holds none
(tests/test_ci_pull_request_caches_are_read_only.py). Each restore is bounded at 4 minutes and each save at 6,
both continue-on-error, so a slow store costs the build at most that and never fails or outlasts the job's 20.

## note-210c

Above `build: Key the cargo build in R2`, `Strip the workspace's own output before the R2 save` and the `environment:` line of `build` in `.github/workflows/cmux-tui-build-package.yml`.

note-210b's R2 route for the three shipped build legs that run on pool hosts (aarch64-apple-darwin built on Linux, and both musl
targets). Their Swatinem/rust-cache entries lived in the full 10 GB GitHub store and were evicted within hours, so a leg spent
about 20 minutes in cargo. Off Blacksmith (which keeps rust-cache and the sticky disks) the leg now restores `cmux-tui/target` and the
cargo registry from R2 (scripts/ci/r2-cache.sh, public reads, no credentials), keyed by the leg, the lto mode, the lockfiles,
rustc and cargo versions, the cross toolchain and a hash of the workspace path. A feat-cmux-next build that missed the exact key
strips the workspace crates' own output (scripts/ci/cargo_target_strip.py, now also under `target/groups/N`) after staging and the
uploads, and saves. The build job holds the `next-cache-writer` environment on feat-cmux-next only; every other ref only reads.
The darwin cross-toolchain install moved above these steps so the key can name it. Evidence: docs/findings/2026-11-23-rust-cache-pool-keys.md (cmuxterm-hq#20570).

## note-211

Retired: `fast-tier-cargo` no longer fetches the ghostty-next Zig packages first.

The step was added because zig's own unretried download failed the job
(pkg/highway ReadFailed). ghostty-vt-sys's build.rs now seeds the packages it
needs from the mirror itself (`curl --retry 3 --retry-all-errors`) and runs zig
mirror-only in CI, and on a warm cargo cache build.rs does not run at all. The
step cost about 50 s per run even with every package already present.

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

Was above `daemon-test: statuses` in `.github/workflows/cmux-next.yml`.

Moved (STATUS_FROM_OUTSIDE, note-352): the same-tree status is posted by
`same-tree-status-daemon` and `same-tree-status-scheme`, outside the tested jobs.

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

Checkout removes .build. Lease a build root after Xcode selection so its fingerprint
uses this job's compiler (2026-11-25-daemon-test-seed-root.md in cmux-next-workflow-notes/).

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

Was above `daemon-test: Report the same-tree result on the tested commit`.

Moved (STATUS_FROM_OUTSIDE, note-352): the same-tree status is posted by
`same-tree-status-daemon` and `same-tree-status-scheme`, outside the tested jobs.

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

Was above `crash-ends-app: Report the same-tree result on the tested commit`.

Moved (STATUS_FROM_OUTSIDE, note-352): the same-tree status is posted by
`same-tree-status-daemon` and `same-tree-status-scheme`, outside the tested jobs.

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

It starts only when `checks` ran (not skipped). A call after a skipped `checks` has no red of its own to add, and cmux-next-guards.yml's call on every head already writes the `ran` line and clears an older head's red from all of that head's check runs. On 11-25 03Z..11Z, 1,387 runs paid this job about 1.3 min each (about 5.6k runner-min a day), almost all of them after a skipped `checks`.

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

## note-347

Above `release-compile-revert: Mint the cmux-bot read token` in `.github/workflows/cmux-next.yml`.

The Actions reads (the run's jobs, then up to the scanned runs' jobs) use a cmux-bot token, off
the repository token's hourly budget, as push attribution does (note-343). On 2026-11-13 from
05:14Z to 05:40Z the repository token's reads failed in this step on every base push (runs
43370687308 through 43372812335), so the job went red on its own read, not on a compile, and
named no culprit. A failed mint leaves every read on the workflow token; a refused read prints
gh's message and body (`gh_failure` in `scripts/ci/cmux_next_push_attribution.py`).

## note-348

Above `light_runner` in macos-placement's outputs and `LIGHT_SPILL_JOBS` in its place step in `.github/workflows/cmux-next.yml`.

A pull request's swift-canary, daemon-test and generated-files take an idle light side runner
(glaeda-side-light-xcode-26.6) when no idle std side runner took them, before the cascade
(side_lane_placement.light_spill_route(); Leo, 2026-11-11: "nobody seems to be doing stuff rn", with
the std minis at 95 to 100% CPU and the light minis at 21 of 92 capacity units). Only these three: they
build the same CmuxNext package seed the fast tier builds, which the 16 GB light minis already run, and
on a pull request they need no GUI session. The Release and app scheme compiles stay on std. Attempt 1
only, one job per idle light runner beyond its queue, never while a nightly or release job waits on the
light family, and nothing with an unread or stale pool snapshot. Each job's runs-on and its
CMUX_NEXT_RUNNER copy read `light_jobs` right after the fork clause.

Also above `LIGHT_FIT_JOBS`, beside `LIGHT_SPILL_JOBS`: the re-run's light move.

Leo, 2026-11-15: "you can decide on best routing for stuff". On 2026-11-15 from 01:10Z, 32 jobs on
glaeda-side-std-xcode-26.6 (generated files, the fast tier, the app scheme compile) stayed queued after light
side runners freed: note-348's spill places attempt 1 only, and GitHub never moves a queued job. The rescue on
main (owned_pool_rescue.light_wait()) now cancels such a pull request run and re-runs its placement once a job
it can move has waited LIGHT_MOVE_SECONDS on the std side label while the fleet gates show a light side runner
listening, and the bot's re-run (side_lane_placement.light_rerun_route()) gives each LIGHT_FIT_JOBS job no idle
std side runner took an idle light side runner. LIGHT_FIT_JOBS is the measured set in `.github/runners.json`
`light_fit` (runs and success rate on the 16 GiB light minis against the std minis). The fast tier,
daemon-test and generated-files runs-on read `light_jobs` on the attempt their placement ran
(`placed_attempt == run_attempt`), not only attempt 1, so the re-run takes the label it was given (#18147: a
re-run reused attempt 1's placement); a person's re-run carries attempt 1's placement and keeps its route.

## note-349

Above `checks: timeout-minutes` in `.github/workflows/cmux-next.yml`.

15 minutes fits Blacksmith 16 vCPU (about 7 min), not a mini: on a mini the job's 15 minutes also
pay the runner hook's admission wait, and its slow checks run about three times as long beside
the mini's other jobs. #42624, a data-only devbox image promotion, was placed on a mini on all
three of its heads and every run was cancelled by the timeout, never passing or failing, so
land-judge had no verdict to read: job 131984422217 (run 43454315926) and job 132002973791 (run
43459662812) were admitted at once and were still in their script tests at 15 minutes
(test_cmux_next_prepush_gate.py 693 and 720 s, 238 s on Blacksmith); job 132013731059 (run
43462746656) waited 8 min 5 s in the hook for the canonical root token (the hook costs `checks`
as a compile) and ran out in "UI font". A job the placement put on a mini gets 35 minutes; every
other route keeps 15.

## note-350

Above `macos-placement: CI_BLACKSMITH_MACOS` in `.github/workflows/cmux-next.yml`.

The off switch for Blacksmith macOS (Leo, 2026-11-11: "just stop using blacksmith temporarily"), HQ's
`HQ_BLACKSMITH_MACOS` pattern (cmuxterm-hq `docs/handbook/label-no-pool-lists.md`). Only the repository
variable `CI_BLACKSMITH_MACOS` set to `on` lets a Mac job take a Blacksmith macOS label. Unset, the placement
lists no job for a Blacksmith slot, overflow or retry label, and writes no GUI overflow
(`next_macos_cascade.blacksmith_on()`); `GUI_LAST_RESORT` is the owned GUI label; and every
`fromJSON(vars.RUNNER_POOLS).macos_26` and `.macos_26_large` read in a Mac job's runs-on is wrapped
`(vars.CI_BLACKSMITH_MACOS != 'on' && vars.CI_SIDE_LANE_RUNNER || <read>)`: the owned side lane while the switch
is off. The owned label comes from the variable, not a literal: tests/test_ci_self_hosted_guard.sh allows an owned
literal only after a fork branch, which swift-canary has none of, and tests/test_ci_repo_variable_defaults.py wants a
pool terminal. The variable's own fallback is declared in `.github/single-host-fallbacks.json`. The name carries no
`cmux` token: the self-hosted guard reads one as a fleet label. The DEV landing compile
(dispatch only, no pull request) keeps `dev_landing_place.py`'s own Blacksmith pick for now. Setting the variable
to `on` resumes Blacksmith macOS with no code change. A fork's pull request keeps its Blacksmith literal: it
gets no repository variables and never runs on an owned Mac.

On 2026-11-14 cmux#42922's daemon tests (run 43590543702, job 132454414807) sat queued on
`blacksmith-6vcpu-macos-26` with 0 of its 39 runners online: the rescue's attempt 3 carried attempt 1's
placement, so the runs-on fell through to `fromJSON(vars.RUNNER_POOLS).macos_26`.
`tests/test_ci_next_macos_cascade.py` `test_every_blacksmith_macos_job_is_behind_the_off_switch` refuses a
Mac job whose runs-on can name a Blacksmith macOS label while the switch is off.

The scoped value `pr-rescue` (hq#11523, 2026-11-15: `glaeda-side-std-xcode-26.6` had 76 jobs queued, the oldest
150 min, and no owned Mac was free) is Blacksmith macOS for this workflow's pull-request jobs only. Its
placement (`next_macos_cascade.pr_rescue()`, `rescue_open()`) opens the Blacksmith labels only when the event is
`pull_request`, `GITHUB_WORKFLOW_REF` is this file, and the owned route's oldest queued job has waited
`RESCUE_ROUTE_MINUTES` (45); the slots then go through the same cascade, `CAPACITY` and `MAX_PER_RUN` caps as `on`.
In runs-on, a placement-listed Blacksmith job reads `vars.CI_BLACKSMITH_MACOS != 'on' && vars.CI_BLACKSMITH_MACOS != 'pr-rescue'` (no fromJSON, so tests/runs_on_labels.py resolves it), and every
owned fallback reads `(vars.CI_BLACKSMITH_MACOS != 'pr-rescue' || github.run_attempt < 2 ||
github.event_name != 'pull_request' && (<not a bot's re-run of a pull request's dispatch>)) &&
vars.CI_BLACKSMITH_MACOS != 'on'`: a pull request's re-run (the bot's stall-move or
refusal rescue, or a person's re-run of failed jobs) takes Blacksmith macOS; attempt 1 stays owned. A bot's re-run
(`github-actions[bot]`, `cmux-bot[bot]`) of a dispatch that gates a pull request leaves too: event
`workflow_dispatch`, `same_tree_origin` empty or `pull_request`, and none of `dev_daily`, `tip_swift_suite`,
`tip_daemon_suite`, `base_tier` or `no_reuse` set, so its run name is the default `cmux-next · <sha>` that
main's `owned_pool_rescue.same_tree_pull_dispatch()` reads. Without it the stall move skipped every such run under
`pr-rescue`, its re-run rejoining the side lane: cmux#44529's scheme compile (run 43879624016, job 133341854319)
queued on `glaeda-side-std-xcode-26.6` from 13:50Z on 2026-11-16 (cmuxterm-hq#12109). The stall move admits such a
run only when its head's cmux-next.yml carries this clause. DEV daily, the tip suites, the base tier and a push's
same-tree run keep the side lane. Every other
workflow compares the variable with exactly `on`, so nightly, promote, signing and release read `pr-rescue` as
off; `BlacksmithPrRescue` in `tests/test_ci_next_macos_cascade.py` proves both. Unset or `on` behave as before.

The repository's generic `vars.MACOS_RUNNER_26` is a Blacksmith macOS read too, and it sat ahead of the switch: a
bot re-run past an attempt cap (`run_attempt <= 3`, #22565), or one carrying attempt 1's placement, took it. On
2026-11-14 cmux#42880's fast tier (run 43600399789, attempt 5) waited on `blacksmith-6vcpu-macos-26` with no runner
(cmuxterm-hq#10952). It is inside the wrap now, `(vars.CI_BLACKSMITH_MACOS != 'on' && vars.CI_SIDE_LANE_RUNNER ||
vars.MACOS_RUNNER_26 || <pool>)`, in cmux-next.yml (runs-on, `CMUX_NEXT_RUNNER`, `CMUX_NEXT_SIDE_ROUTE`),
cmux-next-batch.yml and cmux-next-terminal.yml's bot re-run fallback. `tests/test_ci_next_macos_cascade.py`
`RerunPastTheAttemptCap` evaluates every route of every workflow with an attempt cap at bot attempts 2 to 6, placement re-run or carried,
and refuses a Blacksmith macOS label for a route attempt 1 serves with an owned one.

## note-351

The same off-switch contract applies to every workflow, including auxiliary simulator and parity jobs. A new
macOS job must select an owned sim-first or side route before its Blacksmith overflow, and must not spell a
Blacksmith macOS label directly in `runs-on`. `BlacksmithMacosOffSwitch.test_every_blacksmith_macos_job_is_behind_the_off_switch`
scans every workflow file and evaluates each route expression; add a regression case when a new picker shape is
introduced so a direct label cannot return silently during a later attempt.

## note-352

Above `same-tree-status-daemon:` and `same-tree-status-scheme:` in `.github/workflows/cmux-next.yml`.

STATUS_FROM_OUTSIDE: a same-tree run's `(same-tree)` statuses are posted by a job of their own that runs
`if: always()` after the tested jobs, never by a step of the tested job. A step dies with its job's runner:
on 2026-11-15 run 43666282494 (cmux#43368 at 9cc846fc) lost its Mac runner ("The self-hosted runner lost
communication with the server"), no step ran, and the required `cmux-next daemon tests (same-tree)` never
posted. The scheme compile's post sat in `crash-ends-app`, whose `permissions: {}` refused every post and which
a DEV daily skips. `scripts/ci/cmux_next_same_tree_status.py` judges `toJSON(needs)` with needs_verdict.py's
rule and always posts one status with a reason: success, failure (the job and its first error annotation),
or error `no verdict: ...` (a lost runner, a cancel, a job skipped because one it needs was red, named). A
failed tree posts `same-tree cmux-tui unavailable: <reason>` unless same-tree-cmux-tui re-dispatched or
handed the tree over. A post GitHub refuses three times is the reporter's red. Pattern page: cmuxterm-hq
`docs/handbook/status-posted-by-the-job-it-reports.md`; detector:
`tests/test_cmux_next_same_tree_status_never_silent.py` `test_no_status_is_posted_from_inside_the_job_it_reports`.

SAME_TREE_STATUS_SPARE_TOKEN (hq#11150): each reporter also mints a cmux-bot App token (statuses: write) and
passes it as GH_TOKEN_SPARE. github.token shares one hourly budget with every workflow run in the repository; on
2026-11-15 ~750 queued runs had spent it, and run 43660624788's post got HTTP 403 three times over. The first
rate-limited call moves to the App token, which has its own budget. The App key is a repository secret, so the
reporters run in the secrets-only `ci-routing-agent` environment off pull_request events, like compile-status.

## note-353

Above `- docs/remote-agents-and-cloud.md` in `.github/workflows/cmux-next.yml`.

cmux-tui's help-contract tests include_str! this one (acpmux and
cmux-tui both check their help against it), so it is in the tree key
and a change to it has to rebuild and re-run them.

## note-354

Above `- Packages/macOS/**` in `.github/workflows/cmux-next.yml`.

Keep the workflow eligible for every cmux-next product and CI input.
The router still selects the exact tier; this list only decides whether
the workflow starts at all.

## note-355

Above `no_reuse:` in `.github/workflows/cmux-next.yml`.

The safety net under CI_NEXT_JOB_REUSE: a dispatch with no_reuse runs every job
in full, reusing no recorded pass (it still records its own). A nightly one on
feat-cmux-next re-checks what the day's reused results stood on.

## note-356

Above `CMUX_NEXT_STYLE_GUARDS: warn` in `.github/workflows/cmux-next.yml`.

Structural, style, size and drift guards (god files, size caps, package
conventions, motion tokens, type scale, scrollbars, icons, copy lints,
generated-doc drift) still run and print their findings, but only warn
(Leo, 2026-10-19: they failed pull requests for reasons unrelated to the
change). Correctness and safety checks still fail. Set to `fail` to make
the style guards block again.

## note-357

Above `CMUX_NEXT_SIDE_ROUTE: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26'` in `.github/workflows/cmux-next.yml`.

The label attempt 1's macOS jobs take when macos-placement finds an idle
owned runner for them: a glaeda-* label means a mini. Each macOS job's
runs-on, and its own CMUX_NEXT_RUNNER, restate it with the placement.

## note-358

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || githu` in `.github/workflows/cmux-next.yml`.

The run's router: a declared light job (.github/runners.json hosted_light_jobs), 30-50 s of work
(a depth-2 checkout, the path classifier, a read-only tree probe). A fresh placement observation
takes fleet Linux or an idle mini first; a hosted/paid route remains the fail-open fallback.

## note-359

Above `- name: Probe the same-tree cmux-tui` in `.github/workflows/cmux-next.yml`.

One look (and one short re-check of a missing run list), no wait.
Fails open: the tiers above are already routed, so a probe that errs or
passes its 2 minutes leaves tree_state empty (the tree jobs skip) and
every other routed job still runs (2026-10-27: per-run fetches of a
lane-branch push burst held this step past the job limit, and the
cancelled job skipped the Release compiles and swift test).

## note-360

Above `run: |` in `.github/workflows/cmux-next.yml`.

A pull request or push that does not grow the App's source passes even
over the cap: a pull request compares with its merge commit's first
parent, a push with the commit before it (fetched: checkout is depth 2).
A push with no before commit (a new branch) keeps the plain cap.

## note-361

Above `- name: Ghostty resources bundle` in `.github/workflows/cmux-next.yml`.

The app's Ghostty shell integration comes from ghostty-next (the
Ghostty of GhosttyNextKit and libghostty-vt): the bundle phase output
must equal its source tree.

## note-362

Above `CMUX_NEXT_TEST_HANG_SECONDS: "1500"` in `.github/workflows/cmux-next.yml`.

Whole-run limit per pass. The hang guard is the stall rule (no test
finished in CMUX_NEXT_TEST_STUCK_SECONDS, default 300), so a real
hang ends in ~5 min; this only caps a slow healthy pass (~860 s).
Both passes share one deadline below the step's 40 minutes. On a
6-vCPU overflow Mac the shards run one at a time (width 1): the
broad pass took 1,266-1,371 s over four runs and 1,725 s in run
41372093339, where the last shard (CmuxNextAppTests.Cloud, ~90 s
alone) started with 33 s left and was cut at its 60 s floor.

## note-363

Above `concurrency:` in `.github/workflows/cmux-next.yml`.

A push's Mac fallback waits only when the fleet compile check gives no verdict.
It is never cancelled once it runs; a newer push is filtered by the head
preflight before it can take a runner.

## note-364

Above `outputs:` in `.github/workflows/cmux-next.yml`.

The crash gate step's outcome, for the crash-ends-app job (that job is the red check, so a
crash freeze never fails the app-producing job the dogfood and daily publishers read).
No perf step runs here (Lawrence 2026-10-23: nothing perf-related blocks or slows a push or a
pull request): the launch-time budget and the perf counter gate run in the perf cron,
.github/workflows/cmux-next-perf-budgets.yml, on the bench host.

## note-365

Above `full:` (workflow_dispatch inputs) and in `path_route: Classify pull request paths` in
`.github/workflows/cmux-next.yml`.

A plain dispatch on a working branch (not feat-cmux-next or `next-batch/*`, not same-tree, not
the DEV daily, base tier or tip suites) skips the two heavy Mac compiles: `cmux app scheme
compile (Debug)` (scheme=false) and `cmux-next Release compile (Xcode 26)` (native=false). On a
dispatch, native drives only the Release compile: the build fleet's app compile runs on pull
requests only. Dispatch with `full=true` to run both. On 2026-11-15 about 14 lanes dispatched
the workflow on their branches, and each dispatch put a 5-unit scheme compile on
glaeda-side-std-xcode-26.6: 24 jobs queued there, the oldest 81 minutes (macos-pool-load,
10:35Z), and the NOW runner-starve alarm fired. Pushes, pull requests, nightly, DEV daily and
base tier runs are unchanged (tests/test_cmux_next_dispatch_heavy_compiles.py).

## note-366

Above `on.workflow_dispatch` in `.github/workflows/cmux-next.yml`.

Dispatch runs every tier on any ref of this repository
(gh workflow run cmux-next.yml --ref <branch>): feat-cmux-next, the
next-batch/* integration branches that scripts/ci/next_batch.py validates,
or a pull request's own branch. Only someone with write access can
dispatch, so it is as trusted as a push.

Same-tree mode (same_tree_sha set): scripts/ci/cmux_next_tree_notify.py
dispatches it from the cmux-tui artifacts workflow once a tree that a run
probed as unpublished is published (or failed). It runs only the tree jobs
(daemon tests, scheme compile) on same_tree_sha, or only reports the
failure, and posts their results as commit statuses on
same_tree_status_sha (the push, or the pull request head).

## note-367

Above `concurrency.group` in `.github/workflows/cmux-next.yml`.

Pushes and dispatches get a group of their own, as in the other side
lanes: when the owned-pool rescue re-runs an older push run, it must not
join a group where it would replace (cancel) the newest pending run.
The Mac jobs of a push (swift test, Release compile, generated files,
daemon tests, scheme compile) keep independent job groups: a started job
runs to the end and stale work is filtered before it takes a runner. Fast
checks still run on every push. Push runs upload no
owned-pool-watch marker, because the rescue cancels a push run with a newer
push run behind it, running jobs included; at 1 push a minute no tip
swift test completed (2026-10-07 00:20Z to 01:05Z).
A plain dispatch on a working branch (not feat-cmux-next, not next-batch/*,
not same-tree mode or the DEV daily) is grouped by its ref and a newer one
cancels it, like a pull request's push: a superseded dispatch does not hold
a mini in the queue.

## note-368

Above `jobs.path_route` in `.github/workflows/cmux-next.yml`.

Picks the tiers a pull request runs (scripts/ci/cmux_next_route.py; the
header above lists them). The diff is the merge commit against its first
parent, so commits that landed on the base after the branch point are not
counted as the pull request's own. Labels are read live, so labeling a
PR full-ci and re-running the workflow runs every tier, not only the
routed ones.
Pushes and dispatches run every tier.

The daemon and scheme tiers also need this commit's same-tree cmux-tui.
It is probed once here, never awaited (pin-cmux-tui.sh probe): published,
the tree jobs run in this run; still being built, this run leaves a
cmux-next-tree-wait-<key> marker and skips them, and a trusted publication
may dispatch this workflow's same-tree mode for it
(scripts/ci/cmux_next_tree_notify.py). A superseded push skips them. PRs
never create a synthetic pin ref: a cold PR tree is skipped with a named
reason, while trusted branch pushes still report an unavailable tree.

## note-369

Above `macos-placement.if` in `.github/workflows/cmux-next.yml`.

Attempt 1's macOS jobs stay on the owned side label while the fleet
drains. A bot retry runs placement again so it can use a newly free
owned GUI/session runner before falling back to Blacksmith: the rescue's
attempt 2, and its attempt 3 when a Mac job of attempt 2 waited
next_macos_cascade.OWNED_REPLACE_MINUTES on its owned label.
Every step fails open: a skipped or failed placement leaves
fallback_jobs empty, so the jobs keep the side label and the marker is
still uploaded. It runs only where attempt 1's Mac jobs may
take the side label (CMUX_NEXT_SIDE_ROUTE's owned branch): a fork, another
owner, owned pools off or a re-run starts no Linux runner for it, and the
Mac jobs (needs plus !cancelled()) take their route without it. A re-run
needs no marker of its own: its Mac jobs take the fallback, and the
rescue's watch of a side lane ends at attempt 3.
Same-tree mode runs it too: its owned-pool-watch marker lets the rescue
re-run a tree job that a mini refuses (no head to move on a dispatch).
A pull request the router sends to no Mac tier starts no Mac job (the
fast tier follows the route too), so it places nothing.

## note-370

Above `jobs.app-compile-fleet` in `.github/workflows/cmux-next.yml`.

A same-repository pull request's app compile, on the build fleet instead
of the Mac Release queue (2026-10-21: 76 of ~350 queued Mac jobs were
Release compiles). It compiles and links the app at the PR's head, the
commit the landing gate (require-cmux-guards) asks about, in about a
minute. A fleet compile error fails this job: the PR's own red. No verdict
(no client, the controller unreachable or timed out: any cmux-ci exit but
0 and 1, 69 included) fails this job too, because nothing compiled the
head: it went green on exit 69 with no compile at all (PR #26741's head
292b43ef, 2026-10-28, whose change runs no Mac Release compile). The
verdict output stays unavailable, so release-compile still runs on a Mac
where path_route's mac_release sends it. A full-ci PR, a fork, and every
push and dispatch keep the Mac Release compile; the base push compiles
Release after the merge, and push-attribution names the PR on a red.

## note-371

Above `app-compile-fleet.if` in `.github/workflows/cmux-next.yml`.

It runs on cmux-linux whether or not app-compile-placement saw a gateway runner idle: since note-557 its
runner only reads the verdict the controller posts, so a busy gateway is no reason to skip it. It used to
run only on an idle reading, and the skip sent the PR to the Mac Release compile: in the 24 h before
2026-11-25 ~02:00Z, 50 of 114 PR Release compiles (about 950 Mac minutes) were PRs whose only Mac
reason was this skip. release-compile still runs when this job gives no verdict (unavailable, or skipped
on a later attempt), and macos-placement still lists it in the cascade (CASCADE_RUNS) when no gateway was
idle, so that fallback takes a free slot rather than the queue PR #24155's compile sat in three times on 2026-10-26.
It does not wait for the PR quiet period: its runner only hands the head to the build fleet's
Linux compile, and the run's group cancels it on a newer push, as does its own group below.

## note-372

Above `jobs.fast-tier-rerun-placement` in `.github/workflows/cmux-next.yml`.

A person's re-run of the fast tier, placed again (side_lane_placement.rerun_fleet()). Re-running
failed jobs carries attempt 1's macos-placement and its outputs, so the tier took vars.MACOS_RUNNER_26
and fast-tier-fleet skipped the stale gateway reading: #38130's attempt 2 ran out its 20 minutes on the
same cold Blacksmith build as attempt 1. This job is skipped on attempt 1 and on the rescue's re-run
(macos-placement places those), so a person's re-run evaluates it again. It reads the runners now and,
while the fast tier runs again in this attempt and a gateway runner is idle for its client, lists the
tier for fast-tier-fleet with this attempt's gateway reading; otherwise the tier keeps its route. A
later re-run carries this job's reading too, which fast-tier-fleet then skips as an earlier attempt's.
With owned pools off (vars.CI_PR_POOL_OWNED), as for macos-placement, it places nothing.

## note-373

Above `jobs.swift-test` in `.github/workflows/cmux-next.yml`.

The CmuxNext test targets the change reaches: path_route's swift_filter
(an empty filter runs every target, as on a full-ci PR, a push or a dispatch). No
cmux-tui wait: the live-daemon suites skip unless the same-tree binary is
already published, and daemon-test runs them against it.
PR package/generated jobs read only this attempt's cascade allocations.
With missing or carried outputs, stay on the owned side pool: a repository's
generic MACOS_RUNNER_26 may name paid capacity with no bounded allocation.
The bot's attempt 4 leaves the side pool for the small overflow, like every
other cmux-next fleet fallback (run_attempt <= 3, #22565), only while Blacksmith
macOS is on: vars.MACOS_RUNNER_26 sits behind the switch too, so with it off a
re-run past the cap stays on the side lane (cmuxterm-hq#10952: attempt 5 waited
on blacksmith-6vcpu-macos-26 with no runner).
Keep the existing owned-pool switch: when disabled, retain its small overflow.

## note-374

Above the `Compute the fast-tier seed keys` step of `swift-test` in `.github/workflows/cmux-next.yml`.

Off the owned Macs, start from the build a feat-cmux-next push seeded for the fast tier
(cmux-next-fast-tier-seed.yml): the same `swift build --build-tests` of this package at a
recent base, at the same workspace path. With the seed's input times replayed, only what
this change touched compiles, so a daemon-only change compiles no Swift and goes straight
to the tests. The seed's resource bundles are dropped first (owned_spm_scratch.py
drop-bundles, as a kept build's are). Any miss builds as before.

## note-376

Above the `Run package test shards the broad pass spilled` step of `swift-test` in `.github/workflows/cmux-next.yml`.

The shards the broad pass had no time for. Each shard there started with the time left to
the pass's deadline, so one slow shard cut the next ones short: in run 41665450504 shard 13
took 867 s and shards 14 and 15 were killed at a 60 s limit, 0 of 447 finished tests red,
and a cut-short run is never a base red. A shard with under its floor left (450 s, the p90
of 28 measured shards; swift-test-shards.py SHARD_FLOOR_SECONDS) is spilled here and runs
with a deadline of its own. It runs after a red broad pass too, so its verdict is not lost.

## note-377

Above the `Run main-thread-heavy suites in their own process` step of `swift-test` in `.github/workflows/cmux-next.yml`.

Suites that hold the test process's main thread for minutes when they
share it (scripts/cmux-next/main-thread-heavy-suites.py says which),
run in their own process, one test at a time. Each Core Animation
commit lays out every window the process holds: in the shared pass
SidebarHugeGroupTests' oneGroup10k (about 1 s alone) and
SidebarLagTests held the main thread for 5 to 11+ minutes, and
RemoteVideoPageTests' WebKit downloads held it in a kernel call
(SandboxExtension::createHandle -> __mac_syscall) for 300+ s. Every
main-actor test beside them stalled or failed on timing, and the stuck
watchdog killed the run with hundreds of tests unfinished (#26809's
runs 40660100939, 40677563234 and 40683540650). Each suite gets a fresh
process: in one shared serial process the windows earlier gallery
suites left open made SidebarScrollCostTests' 500-row scroll take 300+
s and the stuck watchdog ended the step (run 40693598261). A hang or a
red here is this step's red, and every suite still runs. Each suite's
watchdog limits come from main-thread-heavy-suites.py --runs: 600 s for
the run and 300 s with no test finished, or above the suite's own
`.timeLimit` (ClassicUpgradeHugeSimulationTests: 15 min, so 1200 s and
1020 s; it took 412 s alone and one test was open 572 s in a shard).

## note-378

Above the `Compute the fast-tier seed keys` step of `daemon-test` in `.github/workflows/cmux-next.yml`.

Off the owned Macs, and in the mini's seed root on one (note-251), start from the build a feat-cmux-next push seeded for the fast tier
(cmux-next-fast-tier-seed.yml): the same `swift build --build-tests` of this package at a
recent base, at the same workspace path. With the seed's input times replayed, only what
this change touched compiles, so a daemon-only change compiles no Swift and goes straight
to the tests. The seed's resource bundles are dropped first (owned_spm_scratch.py
drop-bundles, as a kept build's are). Any miss builds as before.

## note-379

Above the `Compute the fast-tier seed keys` step of `generated-files` in `.github/workflows/cmux-next.yml`.

Off the owned Macs, start from the build a feat-cmux-next push seeded for the fast tier
(cmux-next-fast-tier-seed.yml): the same `swift build --build-tests` of this package at a
recent base, at the same workspace path. With the seed's input times replayed, only what
this change touched compiles, so a daemon-only change compiles no Swift and goes straight
to the tests. The seed's resource bundles are dropped first (owned_spm_scratch.py
drop-bundles, as a kept build's are). Any miss builds as before.

## note-380

Above the `Pack the exports for the base autofix` step of `generated-files` in `.github/workflows/cmux-next.yml`.

The base autofix's action and settings exports, made on this build instead of a second Mac
build of the same push (cmuxterm-hq#5424): every export regenerated, packed under this commit's
tree (scripts/cmux-next/base_autofix_pushed_exports.py), and uploaded for
cmux-next-base-autofix.yml's pushed-exports job. Pushes of feat-cmux-next and its base tier
dispatches (cmux-next-base-tier-kick.yml, which these checks move to) only, so a pack is only
ever this repository's merged code. It puts the checkout's exports back as they were, so
the steps below see what the checks left; a failure makes no pack (the autofix's Mac job then
regenerates them) and never fails this job. vars.CMUX_NEXT_BASE_EXPORTS_PACK=0 turns it off.

## note-381

Above `release-compile.runs-on` in `.github/workflows/cmux-next.yml`.

The fleet compile check is the primary gate. This Mac job is only the
compatible fallback when it has no verdict; on a push (attempt 1) it
takes an idle freshness slot first (macos-placement's fresh_runner, the
glaeda-dev-* label PR jobs never target), then a free fleet Mac, then
Blacksmith macOS. A busy or offline slot is skipped at placement, so it
never queues on the slot.
A same-repository PR takes the Blacksmith label macos-placement gave it
only when no idle mini took it (the cascade counts the idle minis first),
else the owned side label. Its runner output is the side label whether or
not a mini is free, so reading it first left a PR's compile queued on a
saturated side label with no path off it (cmux#26723, 2026-10-29).

## note-382

Above `env.CMUX_NEXT_COMPILATION_CACHE` in `.github/workflows/cmux-next.yml`.

The DEV app's warm state is the host's own content-addressed Xcode
compilation cache (no kept build products, no remote store:
scripts/cmux-next/lib/compilation-cache.sh), built per file with -O
(singlefile, Xcode's "Incremental") so a one-file change replays
every other file. auto (compile-dev-release.sh) compiles whole-module instead
when the build has no host cache to replay (lock busy, cache off, not a mini).
Repo variables switch each back: CMUX_NEXT_DEV_COMPILATION_CACHE=0,
CMUX_NEXT_DEV_SWIFT_COMPILATION_MODE=wholemodule (or singlefile, everywhere).

## note-383

Above `jobs.release-compile-revert` in `.github/workflows/cmux-next.yml`.

The base-break rule, automated: a feat-cmux-next push whose Mac Release compile failed in its
compile step (pull requests get the fleet compile at -Onone, so -O codegen and the final app link
are first compiled here) opens the revert of the one merge since the compile last passed,
within minutes. Several merges in the range, or a red older than the scanned runs, open
nothing (push attribution comments on each). The revert is pushed and opened by the
manaflow-glaeda-route App so its own CI runs; it lands through the normal review path.

## note-385

Above each owned-Mac `Keep Swift package builds on this owned Mac` step in `.github/workflows/cmux-next.yml`
(swift-canary, fast tier, swift-test, daemon-test, generated-files).

A mini's runner slots run as one user and share one SwiftPM cache (~/Library/Caches/org.swift.swiftpm). Two
slots that both miss a new binary artifact (a Sentry bump, a new GhosttyNextKit) download it at once, and
the second fails `swift build` with "failed downloading '<url>' ... artifacts/<name> already exists in file
system" (cmux#43892 daemon test, job 132938818634, cmux11s-mac-mini-glaeda-8, 2026-11-15). The step then
seeds that cache for CmuxNext's whole package graph with scripts/ci/swiftpm_prefetch_binary_artifacts.py:
a checksum-keyed store under one host lock, atomic renames into the cache, so SwiftPM only reads it. The
cache stays shared and warm. tests/test_ci_swiftpm_prefetch_shared_cache.py is the detector.

## note-386

Above `borrow_runner` in `jobs.macos-placement.outputs` and above `BORROW_JOBS` in its `Place the macOS jobs` step
of `.github/workflows/cmux-next.yml`.

Borrowing an idle pool beside a backed-up one (scripts/ci/side_lane_placement.py borrow_route()). On 2026-11-16
at 03:16Z macos-pool-load showed glaeda-std-xcode-26.6 48 queued and glaeda-side-std-xcode-26.6 44 (oldest 113
min) while glaeda-gui-std-xcode-26.6 had 0 queued, and the slowest PR verdicts ended on the Release compile. A
same-repo PR's Release compile that no idle side or light runner took takes the gui label (`borrow_runner`,
listed in `borrow_jobs`) only while the side route has a queue, the gui label has nothing queued, more idle
runners than the reserve (1) plus this run's own GUI jobs, and fewer than BORROW_CAP (2) gui runners already run a
borrowed job. The gui pool's own jobs keep first claim; a stale or unread reading borrows nothing. The job's
runs-on reads it only in the attempt the placement ran. The detector is
tests/test_ci_side_lane_placement.py::BorrowIdlePool.

## note-387

Above `GATEWAY_LABEL` in the `Place the macOS jobs` step of `.github/workflows/cmux-next.yml`.

The build-fleet compiles' gateway, taken (or a wider class of it) only while a runner is idle
(gateway_runner). With none idle, swift-canary-fleet does not run and swift-canary cascades. The PR's app
compile took its gateway before the quiet period ended (app-compile-placement); with none, its Mac Release
compile, which runs when app-compile-fleet gives no verdict, is in CASCADE_RUNS above.

## note-388

Above `PR_HEAD_SHA` in the `Classify pull request paths` step's env and above the
`cmux_next_base_merge_carry.py` call in its run, in `.github/workflows/cmux-next.yml`.

The base-merge carry. land-judge asks a pull request whose fast-gates green went stale to merge
feat-cmux-next in (update-branch), and only after every check at the older head H finished and passed; it
then lands the base merge M on its merged-tree checks alone (cmux-next/fast-gates on Linux,
cmux-next/compile on the build fleet, the web compile) and carries the rest from H (land-judge
merged_tree_hold). This workflow still ran every Mac tier again at M. On 2026-11-16 at 05:44Z, with
macos-pool-load at 134 queued on glaeda-std-xcode-26.6 and 126 on glaeda-side-std-xcode-26.6 (oldest 187
min), 18 of the 60 open cmux-next pull request runs were on base-merge heads and 13 more same-tree dispatches
tested their trees: Mac jobs no merge waited on, queued in front of pull requests that do wait on theirs. The
land loops take the update-branch step up to four rounds, so one PR could queue four copies of its Mac tiers.

After the router, a same-repository pull request run asks scripts/ci/cmux_next_base_merge_carry.py. When the
head is a merge of a feat-cmux-next commit into H, its tree is exactly git's clean merge of the two (no
resolved conflict, nothing slipped into the merge commit), H has a cmux-next pull_request run that concluded
success, and the PR has no `full-ci`, the fast tier, generated files, daemon tests, scheme compile, Swift test
and Swift canary outputs are set false (appended after the router's: the last value wins) and the summary names
H and its run. The native tier stays as routed. Anything unread is no carry. `CMUX_NEXT_BASE_MERGE_CARRY=0`
turns it off. tests/test_cmux_next_base_merge_carry.py is the detector.

## note-389

Above `base_tier:` in `.github/workflows/cmux-next.yml`.

cmux-next-base-tier-kick.yml (scripts/ci/cmux_next_base_tier.py): a feat-cmux-next push leaves
its base Mac tier (daemon tests, generated files, the Debug app scheme compile) to this run,
started at most once every 15 minutes on the tip (cmuxterm-hq#5424). Named
`cmux-next base tier · <sha>`, which the kick, push attribution and base_red_excuse.py read.

## note-391

Above `[[ "$GITHUB_REF" == refs/heads/feat-cmux-next ]] || {` in `.github/workflows/cmux-next.yml`.

The dispatcher (main's cmux-next-dev-daily-dispatch.yml) asks for
the feat-cmux-next tip it saw. A merge that lands before this run
starts moves github.sha: the run is superseded, not broken. Path
routing prints a notice, sets `superseded=true` and every tier false,
and exits 0, so no job builds and the run ends green; a failed exit
paged the incident desk as a feat-cmux-next base red (run
45753471212). The dispatcher counts a run only at the SHA it asked
for and publish needs an app-producer job to succeed, so a green
superseded run neither blocks nor stands in for the new tip, and the
next tick asks for it. No snapshot ref: creating a ref at a
feat-cmux-next commit needs the workflows permission (HTTP 403).

## note-392

Above `[[ "$GITHUB_REF" == refs/heads/feat-cmux-next ]] || {` in `.github/workflows/cmux-next.yml`.

main's cmux-next-tip-swift-suite-dispatch.yml, every few hours: a
feat-cmux-next push skips swift-test (push CI is the app build
only), so a Swift suite red on the base stayed invisible for a day
(2026-10-21). This run gives swift-test a verdict on the tip, the
base run scripts/ci/base_red_excuse.py compares a PR's reds with.
Only the Swift suite: no scheme, daemon, native or generated tier.
It tests the tip it starts on, whatever the dispatcher saw.

## note-393

Above `[[ "$GITHUB_REF" == refs/heads/feat-cmux-next ]] || {` in `.github/workflows/cmux-next.yml`.

main's tip suite dispatcher (its daemon suite): a feat-cmux-next push never gets
daemon-test (its same-tree run has origin push, and in a landing burst the tip moves
before the tree publishes), so the base had no daemon-test verdict for
scripts/ci/base_red_excuse.py to compare a pull request's daemon-test red with
(2026-10-30, #27692). Only the daemon tier. Its tree wait marker carries tip_suite, so
the same-tree run tests this exact commit even after the tip moves on.

## note-394

Above `FRESH_JOBS: ${{ (github.run_attempt == 1 || contains(fromJSON('["github-actions[bot]","cmu` in `.github/workflows/cmux-next.yml`.

The jobs a feed's freshness waits on: when the counts cannot be read (a 403 on the route token, a
stale snapshot) they take Blacksmith 6 vCPU, the last resort, instead of an owned queue nobody
measured (next_macos_cascade.unread_fresh_jobs()). A DEV daily's Release compile feeds the DEV
channel, a feat-cmux-next push's gates nightly-next.

## note-395

Above `gui="$(awk -F= '($1 == "gui_runner" || $1 == "gui_overflow") && substr($0, index($0, "=") ` in `.github/workflows/cmux-next.yml`.

An empty gui_runner is meaningful: no online runner carries the
GUI label, so preserve the picker/placement fallback instead of
synthesizing a label that may not exist in the fleet.
A placement that names neither a GUI route nor a GUI overflow (a
trusted base that predates the sized gui_overflow, or one whose
runner read failed closed) vouches for no owned GUI queue: the GUI
jobs take Blacksmith 6 vCPU, the last resort, as the synthesized
runner above sent them before, never the owned GUI queue unmeasured.

## note-396

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || needs.portable-` in `.github/workflows/cmux-next.yml`.

Fleet Linux, then a free mini (portable-placement), then Blacksmith 16 vCPU. The slow checks run
concurrently, one per CPU or per core of the job's share on a mini ("Start the slow checks in the background", scripts/ci/run-checks-concurrently.sh). While the overflow
switch has failed over it takes 8 vCPU, not 32 (.github/runners.json linux_sizes), hence 15 minutes.
The checks are Python and bash; none needs Linux.

## note-397

Above `if [[ "$EVENT_NAME" == push && "$BEFORE" =~ ^[0-9a-f]{40}$ && ! "$BEFORE" =~ ^0+$ && ${#fa` in `.github/workflows/cmux-next.yml`.

A push names which reds it added and which the previous tip already had, but every
red keeps the job red. Turning inherited reds into warnings (0150fc73e3e) made the
tip's checks job green while its checks were red: base_red_checks.py excused every red
while the previous tip was still pending, which on a branch with ~100 merges a day is
nearly always, so new reds landed unseen; and the PR-side comparisons
(pr_red_checks_comment.py, base_red_excuse.py, next-autoland) read the green tip as
"green on the base" and charged the base's reds to every open pull request
(2026-10-30: 252 of 660 open PRs red on four base reds, no autoland merge in 24 h).

## note-398

Above `- name: Hand the web bundles to this run's Mac jobs` in `.github/workflows/cmux-next.yml`.

The minis cannot read this cache: on Blacksmith it is Blacksmith's own
cache, which a self-hosted Mac never sees (2026-10-26: swift test rebuilt
the bundles on 14 of 25 sampled jobs, generated files on 12 of 44, 40 s
of Mac time each). So a run that does not publish them to R2 (every
event but a feat-cmux-next push) also hands them to its own Mac jobs as
an artifact named after the source key; a Mac job whose sources give
the same key installs it instead of building.

## note-399

Above `- name: Publish the web bundles to R2 (feat-cmux-next push)` in `.github/workflows/cmux-next.yml`.

The Mac jobs read the bundles from R2's CDN first: the minis download
them from there much faster than from the GitHub cache, and every
pull request whose web sources match feat-cmux-next's hits. The `any`
namespace is shared by every OS (the bundles are platform-independent).
A key that is already stored is not uploaded again. A DEV daily run does not publish:
its DEV Release compile reads this run's GitHub cache entry when R2 has no copy.

## note-400

Above `submit() {` in `.github/workflows/cmux-next.yml`.

submit N PACKAGE SUITES: one fleet step that builds PACKAGE once and runs SUITES at REF.
CMUX_SWIFT_PACKAGE_TEST_TIMEOUT_SECONDS=60 keeps the Mac fast tier's 60-second limit per entry
(package-test-lane.sh's suite default is 900 s); the build before the suites has no such limit.
--no-supersede: a newer head never takes this run's step, so the verdict stays this commit's.
--queue-timeout 1200: the light class's measured queue p90 (cmux-ci's warning: 746 s on
2026-11-08 12:07Z, 1314 s at 14:28Z), bounded at 20 minutes; past it the tier runs itself.

## note-401

Above `- name: Compute fast-tier cache keys` in `.github/workflows/cmux-next.yml`.

Owned minis keep their builds on their own SSD (above). Blacksmith overflow
restores the newest seed cmux-next-fast-tier-seed.yml saved from a
feat-cmux-next push to cmux-ci-cache-next, through its public URL: no
credential, and a pull request never writes. The swift directory comes by
prefix; the home directory by that seed's exact commit, so both come from
one seed and match the input-time manifest in the swift directory.

## note-402

Above `tree_path="$(../../../scripts/cmux-next/pin-cmux-tui.sh path 2>/dev/null)" || tree_path=""` in `.github/workflows/cmux-next.yml`.

The selected targets as several test processes at once, split by
target and suite prefix (scripts/cmux-next/swift-test-shards.py), as
many at a time as the runner's cores and memory hold. One process ran
them all before: ~6,300 tests queued on its one main thread and the
windows they left open piled up (3 -> 428), so throughput fell from
~2,000 to ~100 tests a minute and the pass hit its limit with 466
tests unfinished (#26809, run 40705037968).
The same-tree cmux-tui as it is when the broad pass starts, the same
for every shard. In the one shared process the base runs, the
live-daemon suites read the tree once, early, before any
CmuxNextDaemonTests suite could fetch it (RealBinary.sameTree), so
they ran only when the tree was already here (after the
changed-suites pass fetched it, say) and skipped otherwise. As
shards, those that started after a fetch ran them and the rest
skipped (run 40932106119: 87 skipped, 315 on the base). Resolved
once here, a missing tree is a path that is never a file: no shard
fetches it, and every live-daemon suite skips as on the base. The
daemon tests job fetches the tree and runs the daemon suites.

## note-403

Above `environment: ${{ github.event_name != 'pull_request' && 'ci-routing-agent' || '' }}` in `.github/workflows/cmux-next.yml`.

vars.CI_SESSION_LANE_RUNNER is generated files' own owned label (glaeda-session-light-xcode-26.6,
the light minis' session runner: a logged-in session, no console token). It is set only after
those runners are registered; while it is unset the route below is unchanged. The fork clause
stays first, so a fork pull request never reaches it. Same-repository PRs use the
generic side picker and its bounded overflow, never the console GUI label.

## note-404

Above `BLACKSMITH_CANDIDATE: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || github` in `.github/workflows/cmux-next.yml`.

With no owned runner idle the compile overflows to the Blacksmith macOS label whose queue moves
(dev_landing_place.blacksmith_overflow(), the nightly signer's pick), not the busy DEV slot.
The owner and fork branches only satisfy tests/test_ci_fork_runner_routing.py (this job runs only in
manaflow-ai on dispatch); blacksmith_overflow() drops 'macos-26' and keeps the Blacksmith labels.

## note-405

Above `if have="$(python3 -I scripts/cmux-next/hybrid_ref_capture.py have --key "$key" --repo "$G` in `.github/workflows/cmux-next.yml`.

Readable complete captures of the key (unexpired, under 13 days old: the store keeps the
packs 14 days). A rate limit is waited out; a lookup that still fails captures anyway and
fails this step, so the run shows it (40428066457 lost its capture to a silent rate limit).
compile=true skips the product reuse so there is a build to capture, unless a capture of
this key came out incomplete in the last day (then only a build that compiles anyway
captures, and a key that never captures whole cannot turn reuse off for every landing).

## note-406

Above `keep=()` in `.github/workflows/cmux-next.yml`.

The base Mac tier (daemon tests, generated files, the Debug app scheme compile) runs
at most once every 15 minutes on the tip, in the run cmux-next-base-tier-kick.yml
dispatches (cmuxterm-hq#5424). The Release compiles (nightly-next's input), the DEV
landing compile and the fast tier still run on this push.

The Swift canary (changed CmuxNext targets) is off on this push too: the scheduled tip Swift suite
(`tip_swift_suite`, about once an hour) runs every target on the tip and is the base verdict for it.

## note-407

Above `started="$(gh api --paginate "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/attempt` in `.github/workflows/cmux-next.yml`.

This job holds the push compile slot and has a 60 minute limit. The capture (8 minutes at
most) and its manifest upload (2) start only while the job, timed from its own start, is
under 40 minutes; with no jobs read the decide step's start stands in, and an unknown
start skips it. A skipped capture is taken by the next landing.

## note-408

Above `STACK_SLOT:` in `.github/workflows/cmux-next.yml`.

A same-repository pull request labelled `stack-blocker` (a base-red repair, or a PR a stack waits on) runs its Mac
jobs on the std minis' nightly slot, which no other PR job asks for, so it skips the side label's queue
(side_lane_placement.STACK_SLOT; glaeda's runner hook admits it there and ranks it right after nightly jobs). Attempt
1 only: a rescue re-run is placed as before. The label is read from the run's own payload, so adding it takes effect
on the PR's next push.

## note-409

Above `CMUX_FAST_TIER_OWNED_SEED:` in `.github/workflows/cmux-next.yml`.

On an owned mini the fast tier first holds the mini's seed root (owned_spm_scratch.py seed_lease):
/Users/runner/_work/cmux/cmux, the workspace path cmux-next-fast-tier-seed.yml builds the R2 base seed at on
Blacksmith. SwiftPM records absolute paths, so the seed is warm only there; at that path and the same Xcode
build an owned mini computes the seed's own key, restores it as Blacksmith does (note-401) and replays its
input times. One job per mini holds the root; another takes a shared root as before. The root qualifies above
glaeda's floor (seed_fits): the job's admitted growth covers the seed, which a cold build would write anyway,
so the light 228 GiB minis (32-48 GiB free), where the lease's floor + growth + root reserve never admitted a
root, take it too. 48 h to 2026-11-18: 3% of owned fast-tier jobs started warm and 170 of 812 were cancelled
past 1100 s (cmux#44271). `vars.CI_FAST_TIER_OWNED_SEED` = `0` switches it off: the tier takes
the shared roots as before. The root's parent must exist, belong to the mini's user and hold the marker
`.cmux-seed-root` (fleet setup); without
them the tier falls back. The marker keeps a runner that works at that path (the nightly-next builder) out.

## note-410

Above the generated-files job's `Keep Swift package builds on this owned Mac` step in `.github/workflows/cmux-next.yml`.

Generated files builds the same `swift build --build-tests` of CmuxNext as the fast tier (note-379), so on an
owned mini it takes the mini's seed root the same way (note-409): `owned_spm_scratch.py lease` with
`CMUX_FAST_TIER_OWNED_SEED`, the R2 base seed restored at the root and its input times replayed. It used
`link`, whose kept build sits at the slot's own workspace path: 24 h to 2026-11-21T12Z, 542 owned jobs at p50
38.6 min, and a job that found its kept 15.9 GiB build still compiled every one of ~15,200 steps (job
136633693044), because the kept build was another base's and SwiftPM's absolute paths tie it to one slot.
Every step that reads the build or writes the checkout (bun, web bundles, the build, the action and settings
checks, both export packs, the regenerate) runs in the root (the mirror holds `.git`, so the checks'
`git checkout HEAD^1` works there); the uploads read `$RUNNER_TEMP` and stay as they are. One job per mini
holds the root, fast tier or generated files; the other takes a shared root or `link` as before.
`vars.CI_FAST_TIER_OWNED_SEED` = `0` switches both off.

## note-411

Above `on:` in `.github/workflows/cmux-next.yml`.

Package tests and merge-gate checks for the cmux-next app package
(Packages/macOS/CmuxNext). `swift test` runs the package's Swift Testing
suites in-process; it never builds or launches a cmux DEV app. The checks
are the AGENT-BRIEF merge gate: god files, main-thread concurrency and the
string tables (the CmuxNext catalogs and InfoPlist).

A pull request runs only the tiers its change can break
(scripts/ci/cmux_next_route.py, docs/ci/cmux-next-tiers.md):
  checks     always (Linux)
  generated  generated action contracts, the CI target graph and the settings exports are fresh;
             a stale file gets a bot fix commit on a same-repository PR
  native     the Release compile, for Swift and app sources
  scheme     the Debug app scheme compile, for the app host, Xcode project,
             webviews and local packages
  swift      the CmuxNext test targets the SwiftPM target graph says the
             change reaches (Packages/macOS/CmuxNext/ci-target-graph.json)
  daemon     the same-tree cmux-tui and the live-daemon suites, for daemon,
             Rust core, FFI and control paths
A same-repository pull request runs every tier the router picks on its own
branch, with no label (#22303), except the two heavy app compiles (native and
scheme), which need full-ci again (2026-10-21: the Mac queue was ~350 jobs
deep), and the swift tier, which needs full-ci too (2026-11-05: of 78 PR
swift-test check runs, 37 were cancelled by a merge, a newer push or a re-run
and none passed; the tip suite dispatch gives the base its verdict); a MEMBER or OWNER dev-build PR keeps its scheme compile, and the
native tier compiles the PR's head on the build fleet instead
(app-compile-fleet; the Mac Release compile only when it gives no verdict, and only for a PR
that changes an input only that xcodebuild sees: path_route's mac_release,
cmux_next_route.MAC_RELEASE_INPUTS). A fork pull
request runs the fast tier and,
for a CmuxNext .swift change, the Release compile, and the other Mac tiers
only with the full-ci label, on its hosted fallback. full-ci also makes the router
pick every tier. A feat-cmux-next push runs the Mac compiles but not swift
test (see the jobs comment below); a red push run names the pull requests in
its range.

## note-412

Above `types: [opened, synchronize, reopened, ready_for_review, labeled, unlabeled]` in `.github/workflows/cmux-next.yml`.

labeled/unlabeled: adding full-ci re-runs the tiers a feat-cmux-next pull request skips without it
(scripts/ci/affected_jobs.py PR_SKIP_IF); any other label event skips every job in a group of its own
(tests/test_ci_label_events_skip_full_ci.py).
ready_for_review: a draft head runs only the Linux tiers (scripts/ci/head_tier.py); marking it ready
runs the rest on the same head.

## note-413

Above `- "!plans/cmux-next/**/*.md"` in `.github/workflows/cmux-next.yml`.

A plan doc no Swift target names reaches no tier (cmux_next_route.py unread_doc), so a pull request of
only those starts no run. The ones a target names, or a generated one, are put back by name;
tests/test_ci_docs_only_prs.py routes every plan doc this leaves out and fails on one that reaches a tier.

## note-414

Above `- web/data/model-catalog/**` in `.github/workflows/cmux-next.yml`.

Files outside webviews/ that webviews sources import (web-bundle-key.py --inputs;
tests/test_web_bundle_key_inputs.sh keeps this list complete).

## note-415

Above `- scripts/ci/**` in `.github/workflows/cmux-next.yml`.

What the checks tier's tests import, run or read outside the paths above (tests/test_ci_workflow_paths_cover_inputs.py).
Pull-request only, like the lines above. The router's CI_ONLY lists the ones no build reads (checks tier alone);
the GhosttyKit download, the reload and release-strip scripts and .gitattributes still start the Mac tiers.

## note-416

Above `- .github/workflows/nightly.yml` in `.github/workflows/cmux-next.yml`.

A nightly repair must earn this exact commit's Release compile before
promotion can carry it to nightly-next. Otherwise a workflow-only fix
(such as #21144) waits for an unrelated app change to become eligible.

## note-417

Above `- .github/workflows/cmux-tui-build-package.yml` in `.github/workflows/cmux-next.yml`.

The rest of the tree key's build recipe (scripts/cmux-next/cmux-tui-tree-inputs.txt): a base push that
changes only one runs the daemon tests (scripts/ci/affected-jobs.json daemon-test; affected_jobs.py check).

## note-418

Above `- .github/actions/**` in `.github/workflows/cmux-next.yml`.

The rest of the pull_request list (#21504's product and CI inputs). A pull request into
feat-cmux-next skips the checks job (scripts/ci/affected-jobs.json
pull_request_skip), so the push that lands it must start on every path the pull request does.

## note-419

Above `tip_daemon_suite:` in `.github/workflows/cmux-next.yml`.

main's cmux-next-tip-swift-suite-dispatch.yml (its daemon suite): a feat-cmux-next push never
gets daemon-test, so this run is the base verdict scripts/ci/base_red_excuse.py compares a pull
request's daemon-test red with. A same-tree run it waits on carries it too (its run name).

## note-421

Above `blacksmith_12_jobs: ${{ steps.place.outputs.blacksmith_12_jobs }}` in `.github/workflows/cmux-next.yml`.

The jobs no idle mini took that Blacksmith has a free slot for now, 12
vCPU first and then 6, and the Blacksmith label the bot's overflow
attempt takes (scripts/ci/next_macos_cascade.py).

## note-422

Above `fresh_stalled: ${{ steps.place.outputs.fresh_stalled }}` in `.github/workflows/cmux-next.yml`.

The Blacksmith labels a feed's compile counts as full (next_macos_cascade.fresh_stalled()): a feat-cmux-next
push's Release compile never falls back to one of them.

## note-423

Above `grant_runner: ${{ steps.grant.outputs.grant_runner }}` in `.github/workflows/cmux-next.yml`.

CI v2 scheduler grants (scripts/ci/mac_grants.py, scripts/ci/mac-grants.json): the jobs named there
take grant_runner, which the controller grants and sizes, ahead of every pool route.

## note-424

Above `session_spill_runner: ${{ steps.place.outputs.session_spill_runner }}` in `.github/workflows/cmux-next.yml`.

A PR's daemon tests and generated files with no idle side runner: the session label while its queue
is shorter than the side route's (side_lane_placement.session_spill()).

## note-425

Above `- name: Restore the shared pool snapshot` in `.github/workflows/cmux-next.yml`.

The janitor's pool snapshot as a feat-cmux-next push job last read it (this ref's newest entry, else the
base or default branch's): the placement step reuses a copy read under 5 minutes ago instead of two
GITHUB_TOKEN artifact calls, from the hour the promote gates share (scripts/ci/pr_runner_pool.py
kept_snapshot_path). The key below is never saved, so the newest `cmux-pool-snapshot-` entry restores.
The Actions cache is not the REST API.

## note-426

Above `FIRST_JOBS: ${{ github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next' && github.r` in `.github/workflows/cmux-next.yml`.

A feat-cmux-next push's Release compile gates the nightly-next request, so the cascade
places it ahead of the run's other jobs (next_macos_cascade.FIRST_JOBS).

## note-427

Above `- name: Scheduler grants for named Mac jobs` in `.github/workflows/cmux-next.yml`.

Only a feat-cmux-next push job that read the API saves a new entry, keyed by when it read (pr_runner_pool
writes the marker then); pull requests and lane branches restore the base branch's newest one.
The trusted base's switch; a base without the script grants nothing.

## note-429

Above `- name: Check whether this job read the pool snapshot` in `.github/workflows/cmux-next.yml`.

Only a feat-cmux-next push job that read the API saves a new entry, keyed by when it read (pr_runner_pool
writes the marker then); pull requests and lane branches restore the base branch's newest one.

## note-430

Above `if: ${{ ((!cancelled() && inputs.dev_daily != true && inputs.base_tier != true && inputs.same_tree_s` in `.github/workflows/cmux-next.yml`.

Tier A of the merged pull request replay (scripts/ci/affected-jobs.json pull_request_skip): a pull request
into feat-cmux-next skips it unless labeled full-ci; the feat-cmux-next push runs it.

## note-431

Above `- name: UI text says only what you can act on` in `.github/workflows/cmux-next.yml`.

Leo, 2026-11-16: "this needs to shut up / most of our s*** probably needs to shut up / and stop
writing so much s***". Every visible string has a word budget by kind; the allowlist only shrinks.

## note-432

Above `- name: Containers concentric with their buttons` in `.github/workflows/cmux-next.yml`.

A container that holds buttons rounds from them (Lawrence 2026-11-15: "all dialogs needs concentric padding
with buttons inside"): Metrics.buttonContainer(padding:), calc(var(--ds-radius-control) + padding).

## note-433

Above `- name: Buttons change only their fill when pressed` in `.github/workflows/cmux-next.yml`.

A held button changes its background and nothing else (Lawrence 2026-11-15): no bold, size, scale,
offset, dimming or icon change on :active, a held frame or a SwiftUI press (design/pressed-state.md).

## note-434

Above `- name: Type scale` in `.github/workflows/cmux-next.yml`.

The one type scale (schemas/type-scale/type-scale.json): its CSS and Swift copies, and no new raw
font sizes or off-scale weights in the app's Swift (fails the checks; the webviews ratchet runs in react-apps-check).

## note-435

Above `- name: Perf source guard (no window capture or CATransaction.flush)` in `.github/workflows/cmux-next.yml`.

The perf gate's source guard without an app (I5: a theme change captures no window and
forces no commit): a source scan of seconds, so it stays here while the perf gate itself runs
only in the perf cron (cmux-next-perf-budgets.yml); two hits once landed by direct push
(36c5b4217488, 715f623c97e1).

## note-436

Above `- name: Upload the reported tree wait marker` in `.github/workflows/cmux-next.yml`.

The record of this run's red, keyed by its tree: the key's next publication re-dispatches every tier
it reported (cmux_next_tree_notify.py), whatever became of the marker that started this run.

## note-440

Above `SIDE_LABEL: ${{ github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name` in `.github/workflows/cmux-next.yml`.

The owned side label itself: CMUX_NEXT_SIDE_ROUTE names Blacksmith on a person's re-run. A fork's
pull request never gets it (it never reaches this job either: its fleet client does not run).

## note-442

Above `- name: Upload the fixit-compile patch` in `.github/workflows/cmux-next.yml`.

A build whose every error had a machine-applicable fix, and compiled with them: the patch, for the
cmuxterm-hq fixit-compile reconciler to push onto a lane/* branch as a fixup commit.

## note-443

Above `concurrency:` in `.github/workflows/cmux-next.yml`.

A push's Mac job waits for the same job of the running push run and is
never cancelled once it runs; a newer push replaces only the waiting one
(see the workflow concurrency comment).

## note-445

Above `timeout-minutes: 70` in `.github/workflows/cmux-next.yml`.

Runs from runner pickup, so it also counts the runner hook's wait for capacity units. Finished runs took 20-39 min
(2026-11-17, 12 h), and a units wait of 19 min cancelled cmux#44505's mid-compile at 40. 60, plus the PR
autofix pack step's 10.

## note-446

Above `- name: Check the settings exports` in `.github/workflows/cmux-next.yml`.

The CI target graph is bot-only (scripts/cmux-next/generated_outputs.py,
#21946): it is stale on every event between a merge that adds a target
and the base autofix's commit, so no event checks it here.

## note-447

Above `runs_on: ${{ steps.place.outputs.runs_on }}` in `.github/workflows/cmux-next.yml`.

JSON for cmux-scheme-compile's runs-on (a pinned runner is [its pool label, glaeda-runner-<name>]),
and that list's first label for the job's CMUX_NEXT_RUNNER copy; both empty keep the job's route.

## note-448

Above `CMUX_NEXT_BROWSER_DATA_IMPORT: full` in `.github/workflows/cmux-next.yml`.

The DEV app is the tip app (Leo, 2026-10-24), so it builds the
browser-data import as published nightly-next builds do (nightly.yml
NIGHTLY_NEXT_BROWSER_DATA_IMPORT; Apple accepted it in run 42176643049,
cx-f58x). `compiled-out` builds it out again; this step runs no proof
that could hold the DEV zip (#25050).

## note-449

In the `Place the macOS jobs` step's script in `.github/workflows/cmux-next.yml`, above `if [ "$GITHUB_RUN_ATTEMPT" != 1 ] && ! grep -q '^def rerun_main' scripts/ci/side_lane_placement.py; `.

The rescue's re-run (any bot attempt from 2) is placed only by a trusted script that knows it
(side_lane_placement.rerun_main()): an older one writes owned routes a re-run must not
take, so the step writes nothing, the route every re-run had before.

## note-450

In the `Companion workflows` step's script in `.github/workflows/cmux-next.yml`, above `python3 scripts/ci/github_token_budget_lint.py`.

Warn-only, exit 0 always: a ::warning for each step that calls the API with the repository
GITHUB_TOKEN (1,000 requests an hour, shared by every workflow) and has no line in
.github/github-token-budget.json.

## note-451

In the `Report the unavailable same-tree cmux-tui` step's script in `.github/workflows/cmux-next.yml`, above `marker="$RUNNER_TEMP/cmux-next-tree-wait/marker.json"`.

The tree's publish record, read now: a re-run of this run (same inputs) after a later
publication dispatches the ready tree jobs instead of repeating the old verdict. Not
published: it writes this run's marker (reported), uploaded below for the key's next publish.

## note-452

In the `Compile-check CmuxNext on the build fleet` step's script in `.github/workflows/cmux-next.yml`, above `for target in $SWIFT_CANARY_TARGETS; do`.

Production targets of Packages/macOS/CmuxNext that the app
executable does not link (ci-target-graph.json: not reachable from
CmuxNextApp). The app check cannot vouch for them.

## note-453

In the `Run the fast tier's Swift suites on the build fleet` step's script in `.github/workflows/cmux-next.yml`, above `if [[ "$status" == 0 && "$state" == "done" && "$code" == 0 ]]; then`.

The controller's record decides: a pass is a step done at REF with exit 0 (and a client
that exited 0); a step that ended with a nonzero exit is a fail whatever the client said;
anything else (no worker, a queue or run timeout, a newer head, a cancel) is no verdict.

## note-454

In the `Regenerate stale files` step's script in `.github/workflows/cmux-next.yml`, above `python3 scripts/ci/defaults_guard.py snapshot`.

A stale settings export was already written into the checkout by the
check above.
The defaults snapshot reads the action and settings exports, so it
follows whichever of them was regenerated.

## note-457

In the `Run the fast fleet compile check` step's script in `.github/workflows/cmux-next.yml`, above `for probe in 1 2; do`.

The results service is a cache, not a dependency: an origin down on two reads 30 s apart
(no connection, or the edge's 52x/530) hands the gate to the Mac fallback now, not after
retrying the 530 for the whole deadline (20 min with the controller down, 2026-11-10).

## note-458

In the `Run the fast fleet compile check` step's script in `.github/workflows/cmux-next.yml`, above `if ! "$client" compile-check --help 2>/dev/null | grep -q -- '--release'; then`.

Release admission must type-check Release-only conditionals. The
private fleet client rolls this profile out independently; until a
runner has it, use the Mac Release fallback instead of silently
admitting on a Debug compile under the Release gate name.

## note-459

In the `Compile the cmux NEXT DEV Release app` step's script in `.github/workflows/cmux-next.yml`, above `archive="$RUNNER_TEMP/cmux-next-dev-daily-unsigned-${DEV_DAILY_SHA}.app.zip"`.

With the cache on, a mini builds from one fixed tree and DerivedData per host under a
host lock, so the cache's path-holding keys match across its runner instances; a busy
lock or a failed setup builds per runner at once (compile-dev-release.sh).

## note-460

In the `Wait for the fleet Release compile and publish cmux-next/compile` step's script in `.github/workflows/cmux-next.yml`, above `deadline=$((SECONDS + ${WAIT_SECONDS:-2400}))`.

One deadline for the pending post and the wait (40 min); the terminal post comes after it
(at most POST_BUDGET 600 s plus one 40 s try), so the step (56 min) and the App token (60 min) outlast both.

## note-461

In the `Wait for the fleet Release compile and publish cmux-next/compile` and `Publish the fallback's verdict as cmux-next/compile` steps' post() in `.github/workflows/cmux-next.yml`, above `cap=$until; [[ -z "${4:-}" ]] && (( ${post_end:-0} > until )) && cap=$post_end`.

A spent pool's x-ratelimit-reset (up to an hour away) is waited for until the step's own end (post_end),
not POST_BUDGET: cmux#43659's passed compile stayed pending 2.5 h after one refused try. An explicit
budget (the pending post's) still bounds every wait.

## note-462

In the `Wait for the fleet Release compile and publish cmux-next/compile` and `Publish the fallback's verdict as cmux-next/compile` steps' post() in `.github/workflows/cmux-next.yml`, above `pause="" limited=""`.

A GitHub rate limit (a 403 or 429 that says so) waits as asked, at least LIMIT_GAP and twice as long each
time: a retry inside a secondary limit extends it. A 5xx or no answer: again in POST_GAP. Anything else
(a bad token, a missing permission) is final at once.

## note-463

In the `Wait for the fleet Release compile and publish cmux-next/compile` step's script in `.github/workflows/cmux-next.yml`, above `post pending "The Release compile (-Onone) of this head is running" "$RUN_URL" "${PENDING_BUDGET:-30`.

A terminal post that GitHub still refuses leaves the job's own ::error line below (no verdict, NO_VERDICT).
The pending status only shows the wait: a refused one is a warning, and the verdict below still posts or reds.

## note-464

Above `checks: Connection notices` in `.github/workflows/cmux-next.yml` (its link lives in `scripts/cmux-next/check-connection-notices.sh`: the workflow file is near GitHub's size limit).

A connection state the person can do nothing about (reconnecting, retrying, restoring, handshaking, "Getting
access", offline, disconnected) shows nothing until it has lasted the shared bound, unless it carries one action
(Leo, 2026-11-14: "i also want all our connectivity stuff to shut the fuck up and load faster/percievably load
faster / whatever it takes / desktop gui, ios, remote, cloud, etc"). check-connection-notices.py finds the units of
the web pages, the Mac app and the iOS apps that draw one with no time gate and no action; the bound is
schemas/notice-timing/notice-timing.json (10 s), copied as CONNECTION_QUIET_MS / useConnectionQuiet,
NoticeTiming.connectionQuiet and QuietStatusGate.threshold. The offenders on the base when it landed are rows of
connection-notices-allowlist.tsv, which only shrinks: `--base HEAD^1` (the base tip on a pull request, the previous
tip on a push) refuses a row the base lacks (a unit fixed in place does not free its row for a namesake). Every run, with or
without `--base`, judges every unlisted offender and fails a row whose unit no longer offends, whatever file the
change touched: whether a unit offends depends on files it does not live in (a strings map, a string table). Its own tests run in the same background check.

The same step then prints `--input-block`: each place a view is disabled, loses hit testing or is grayed out on a
link condition (connecting, reconnecting, reattaching, resuming, offline, disconnected, not attached, the hub not
ready), on the web pages, the Mac app and the iOS apps (Leo, 2026-11-24, back in the iOS app after minutes in
another app: "the entire thing is somehow grayed out and I can't interact with anything at all"). It is a report:
it exits 0 whatever it finds, and the findings are the work queue for the lanes that make input accepted while the
link comes back. A blocking rule for it needs Leo's own word.

The cmux-next workflow does not run on a change that touches only the phone app, so `cmux-next-ios-kit.yml`'s
kit-tests job runs the same check over the whole tree (no `--base`: every unlisted offender and every stale row
fails; a new row is caught by the cmux-next run that any change to the list triggers). The legacy `ios/` app is not
read: no workflow that runs the check covers it.

## note-465

Above `- webviews/**` in `.github/workflows/cmux-next.yml`.

acpmux embeds the production pane: its binaries' tree key holds all of webviews/
and private-bun.sh (scripts/cmux-next/cmux-tui-tree-inputs.txt).

## note-466

Above `- scripts/ci/base_red_checks.py` in `.github/workflows/cmux-next.yml`.

The push-only base-red classifier in the checks job (push only, never a
pull request; the parity guard lists it in PUSH_ONLY_PATTERNS).

## note-467

Above `- webviews/**` in `.github/workflows/cmux-next.yml`.

acpmux embeds the production pane: its binaries' tree key holds all of webviews/
and private-bun.sh (scripts/cmux-next/cmux-tui-tree-inputs.txt).

## note-468

Above `BASH_ENV: '$({ w="${GITHUB_WORKSPACE:-/nonexistent}/scripts/ci/api_call_log/env.` in `.github/workflows/cmux-next.yml`.

Temporary REST budget attribution: one gh-call line per GitHub API call (scripts/ci/api_call_log/env.sh, fetched at a fixed commit when the checkout has no copy).

## note-469

Above `- uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2` in `.github/workflows/cmux-next.yml`.

Blobless and narrow: the router reads the CI scripts, the test registry, the Swift sources of the
CmuxNext targets, the Package.swift files, cmux-tui's crates and the two other Cargo workspaces its
crate graph follows, and the Xcode project; it reads names and trees from git for the rest. A full
depth-2 checkout of the whole tree took 50-57 s of this job's p50 102 s (2026-11-21). A blob outside
these paths reads as NeedsFullTree and routes every tier (fail-open), never fewer.

## note-470

Above `- name: Fetch the base copies of the changed files` in `.github/workflows/cmux-next.yml`.

The crate graph also reads the base's copy of each changed file, which a blobless checkout lacks.
One batched fetch of just those blobs (git diff prefetches both sides) replaces one round trip each.

## note-471

Above `route="$(awk -F= '$1 == "runner" { value=substr($0, index($0, "=") + 1) } END { ` in `.github/workflows/cmux-next.yml`.

The trusted checkout may still be on a base branch that predates
the route output. Keep the same owned-pool fallback for that
transition and for an API read that fails closed.

## note-472

Above `set +e` in `.github/workflows/cmux-next.yml`.

The switch is read at the base branch tip: a PR's base.sha is fixed when it opens or syncs, so a
flip would otherwise reach only PRs updated after it. A failed fetch falls back to the base.sha copy.

## note-473

Above `- name: Previous checked tip` in `.github/workflows/cmux-next.yml`.

A base tier run checks every commit since the previous base tier run's tip, as a push checked its own
(docs/ci/cmux-next-workflow-notes.md#note-26). Unreadable: no previous tip, as on a push with no before.

## note-474

Above `[script-tests]` in `.github/workflows/cmux-next.yml`.

The longest commands first (the prepush gate suite, then the two pin waits), so a pool as narrow as
the job's share (CMUX_CI_CPU_BUDGET on a mini) does not start them last.

## note-475

Above `python3 scripts/cmux-next/tests/test_hot_apply.py` in `.github/workflows/cmux-next.yml`.

hot-apply.py's plan, apply and rollback (about four minutes, so it starts early). It ran nowhere
before and broke unseen (#43815).

## note-476

Above `python3 -I tests/test_payload_advisories.py` in `.github/workflows/cmux-next.yml`.

The payload advisory guard (cmux-next-payload-advisories.yml) fails a pin inside a published upstream advisory, and every fetched third-party release is watched.

## note-477

Above `python3 scripts/cmux-next/tests/run-script-tests.py` in `.github/workflows/cmux-next.yml`.

Every scripts/cmux-next test_*.py no other line runs, found by glob (a new one runs with no edit here); each passes on Linux or skips naming the Mac it needs.

## note-478

Above `no_verdict() {  # reason` in `.github/workflows/cmux-next.yml`.

No verdict is never a pass: the job fails and says why, and release-compile (a Mac)
takes over only where path_route's mac_release sends it.

## note-479

Above `ref_re='"ref": *"([^"]*)"(.*)'` in `.github/workflows/cmux-next.yml`.

judge N PACKAGE: print the step's log, then its verdict from its exit and the
controller's record of the step, which must name REF as the commit it tested.

## note-480

Above `placed_attempt: ${{ github.run_attempt }}` in `.github/workflows/cmux-next.yml`.

The attempt this reading is from: a re-run of failed jobs carries it, and the fast tier then
reads none of its labels (docs/ci/cmux-next-workflow-notes.md#note-19).

## note-481

Above `- name: Fail on stale generated files` in `.github/workflows/cmux-next.yml`.

Stale files the PR autofix regenerates from this pull request's own changes and pushes as a commit pass as
"autofixed" (scripts/cmux-next/generated-autofixable.sh); that commit's run checks them strictly, and an
autofixed run records no pass.

## note-482

Above `if [[ -z "$GATEWAY" ]]; then` in `.github/workflows/cmux-next.yml`.

No idle gateway: read the fleet's compile of this push, fail closed (only this sha, repo,
recipe 2, release-onone). Pass and fail are verdicts; else the Mac fallback runs.

## note-483

Above `concurrency:` in `.github/workflows/cmux-next.yml`.

A started push compile has a per-run group and is never cancelled by a
newer push. Superseded pushes are skipped by the job condition above.

## note-484

Above `derived_data="${CMUX_NEXT_RELEASE_DERIVED_DATA:-$(scripts/cmux-next/release-deri` in `.github/workflows/cmux-next.yml`.

The compile's DerivedData: the canonical root's on a fleet-cache build (until another
compile takes the root), else this runner's.

## note-485

Above `echo "started=$(date +%s)" >> "$GITHUB_OUTPUT"` in `.github/workflows/cmux-next.yml`.

This step runs early in the job (before the lookup's waits): the capture step's fallback
for the job's start when its own jobs read fails (a rate limit that outlasts this lookup).

## note-486

Above `printf 'key=%s\ncapture=true\ncompile=true\n' "$key" >> "$GITHUB_OUTPUT"` in `.github/workflows/cmux-next.yml`.

Unknown: capture, and compile so there is a build to capture (a lookup that fails for
10 minutes is rare; a lost capture costs the fleet build its REF).

## note-487

Above `if [[ -d "$derived_data" ]] && (( $(du -sg "$derived_data" | cut -f1) > 12 )); t` in `.github/workflows/cmux-next.yml`.

Nothing on the mini reclaims this cache (glaeda-disk keeps it), so cap
it: a cold build leaves about 5 GiB; past 12 GiB start over.

## note-488

Above `- Packages/Shared/**` in `.github/workflows/cmux-next.yml`.

Local packages CmuxNext depends on and files its tests read
(ci-target-graph.json `packages` and `reads`).

## note-489

Above `- webviews/src/**` in `.github/workflows/cmux-next.yml`.

The web bundles' sources (build output since cx-vn5; the package tests
read the built pages; cmux_next_route.py BUNDLE_INPUTS).

## note-490

Above `- CLI/**` in `.github/workflows/cmux-next.yml`.

No tracked file is here: these start the run whose check-no-swift-cli.sh
step fails when a main sync brings the Swift CLI back.

## note-491

Above `- scripts/cmux-next/state-roots-baseline.tsv` in `.github/workflows/cmux-next.yml`.

Pull-request inputs that pushes must watch too (the parity guard,
tests/test_ci_workflow_path_filter_parity.py).

## note-492

Above `- scripts/ghosttykit-checksums.txt` in `.github/workflows/cmux-next.yml`.

The rest of NATIVE_SCRIPT_INPUTS: files the app build or its packaging reads, which the pull request
paths above already name.

## note-493

Above `- Packages/macOS/**` in `.github/workflows/cmux-next.yml`.

Base pushes still run the full side workflow for every package input;
only pull requests use the focused package routing below.

## note-494

Above `- Packages/Shared/**` in `.github/workflows/cmux-next.yml`.

Local packages CmuxNext depends on and files its tests read
(ci-target-graph.json `packages` and `reads`).

## note-495

Above `- webviews/src/**` in `.github/workflows/cmux-next.yml`.

The web bundles' sources (build output since cx-vn5; the package tests
read the built pages; cmux_next_route.py BUNDLE_INPUTS).

## note-496

Above `- CLI/**` in `.github/workflows/cmux-next.yml`.

No tracked file is here: these start the run whose check-no-swift-cli.sh
step fails when a main sync brings the Swift CLI back.

## note-497

Above `CI_CACHE_R2_PUBLIC_URL: ${{ vars.CI_CACHE_R2_PUBLIC_URL || 'https://ci-cache.cmu` in `.github/workflows/cmux-next.yml`.

HQ's public cache edge serves read-only restores from every runner; writes
use the controller-owned R2 credentials in the seed steps below.

## note-498

Above `- name: Companion workflows` in `.github/workflows/cmux-next.yml`.

The companion workflows' structure: generated-files catch-up and the
next-batch landing queue.

## note-499

Above `if [[ -x "$acpmux_bin" && ( -z "${CMUX_TUI_TREE_KEY:-}" ||` in `.github/workflows/cmux-next.yml`.

A pull request on a fallback tree (CMUX_TUI_TREE_KEY, an older
published tree) compiles this checkout's acpmux instead.

## note-500

Above `scripts/cmux-next/check-app-personalities.sh "$(find "$derived_data/Build/Produc` in `.github/workflows/cmux-next.yml`.

The app links C++, iroh-ffi and CCmuxAppFFI; compact unwind holds
three personality routines (decision 2026-10-05).

## note-501

Above `archive="$RUNNER_TEMP/cmux-next-dev-daily-unsigned-${DEV_DAILY_SHA}.app.zip"` in `.github/workflows/cmux-next.yml`.

The lookup checked these bytes against their record; the run that compiled them ran the
checks below on them.

## note-502

Above `fast_tier_cargo: ${{ steps.route.outputs.fast_tier_cargo }}` in `.github/workflows/cmux-next.yml`.

Whether a pull request reaches fast-tier-cargo (scripts/ci/fast_tier_cargo_route.py); empty otherwise.

## note-503

Above `command -v node >/dev/null || scripts/ci/ensure-setup-node.sh 24.22.1 \` in `.github/workflows/cmux-next.yml`.

node: a mini has none; the web jobs' pinned one, from the tool cache or nodejs.org (checksummed).

## note-504

Above `PATH="$(awk '{ line[NR] = $0 } END { for (i = NR; i > 0; i--) printf "%s:", line` in `.github/workflows/cmux-next.yml`.

Preflight, on the PATH the next steps get: name each missing tool and stop here, not 10 minutes in.

## note-505

Above `JOB_TIMEOUT_MINUTES: ${{ github.repository_owner == 'manaflow-ai' && needs.porta` in `.github/workflows/cmux-next.yml`.

The job's own cap (the same expression as its timeout-minutes; tests/test_run_checks_concurrently.py).

## note-506

Above `python3 -I scripts/cmux-next/check-main-actor-work.py --root "$GITHUB_WORKSPACE"` in `.github/workflows/cmux-next.yml`.

Heavy and blocking work on the main actor, ratcheted (plans/cmux-next/main-thread-guarantee-DESIGN.md).

## note-507

Above `python3 -I scripts/cmux-next/tests/test_hot_verify_ci.py` in `.github/workflows/cmux-next.yml`.

The hot-verify workflow's plan verdict, step packing, out.tar staging and PR comment (hot-verify-ci.py).

## note-508

Above `python3 -I tests/test_git_history.py` in `.github/workflows/cmux-next.yml`.

Parallel history tests share one fetch under a lock; a git lock is a retry (tests/git_history.py).

## note-509

Above `- name: Buttons round as tabs` in `.github/workflows/cmux-next.yml`.

Every button rounds as a tab (Lawrence 2026-11-12): Metrics.buttonCornerRadius, var(--ds-radius-control).

## note-510

Above `word=none` in `.github/workflows/cmux-next.yml`.

One compile per head: the tip check's verdict for this exact head, when it has one; "none" compiles here.

## note-511

Above `word=none` in `.github/workflows/cmux-next.yml`.

One compile per head: the tip check's verdict for this exact head, when it has one; "none" compiles here.

## note-512

Above `- name: Mint the glaeda read token` in `.github/workflows/cmux-next.yml`.

Blacksmith's health (the pool snapshot's declared outages and dead labels), as macos-placement reads it.

## note-513

Above `FIXIT_COMPILE_HEAD_SHA: ${{ github.event.pull_request.head.sha }}` in `.github/workflows/cmux-next.yml`.

fixit-compile (scripts/ci/oops/fixit_compile.py, ci-oops 0a) wraps the cargo build: the head its patch is for.

## note-514

Above `AUTOFIXED_OK: ${{ github.event_name == 'pull_request' && github.event.pull_reque` in `.github/workflows/cmux-next.yml`.

Stale files the PR autofix regenerates and pushes are "autofixed", not red (generated-autofixable.sh).

## note-515

Above `AUTOFIXED_OK: ${{ github.event_name == 'pull_request' && github.event.pull_reque` in `.github/workflows/cmux-next.yml`.

Stale files the PR autofix regenerates and pushes are "autofixed", not red (generated-autofixable.sh).

## note-516

Above `- name: Pack the exports for the PR autofix` in `.github/workflows/cmux-next.yml`.

The PR autofix's Mac exports on this build of the same merge commit (base_autofix_pushed_exports.py pr-lookup).

## note-517

Above `end=$(( deadline < ok_at + ${BAD_BOUND:-300} ? deadline : ok_at + ${BAD_BOUND:-3` in `.github/workflows/cmux-next.yml`.

The shared deadline: each read gets only what is left of the wait and of the bound for a usable answer.

## note-518

Above `word=none` in `.github/workflows/cmux-next.yml`.

One compile per head: the tip check's verdict for this exact head, when it has one; "none" compiles here.

## note-519

Above `state: ${{ steps.wait.outputs.state }}` in `.github/workflows/cmux-next.yml`.

What the wait read (pass, fail, unavailable, ...; none: no result in the wait). release-compile-fast reads it.

## note-520

Above `end=$(( deadline < ok_at + ${BAD_BOUND:-300} ? deadline : ok_at + ${BAD_BOUND:-3` in `.github/workflows/cmux-next.yml`.

The shared deadline: each read gets only what is left of the wait and of the bound for a usable answer.

## note-521

Above `[[ -z "$down" && -n "$last" ]] && down="$last for $((SECONDS - ok_at)) s"` in `.github/workflows/cmux-next.yml`.

No usable answer when the wait or the bound ran out (a stalled read, a 530, no connection): the service down.

## note-522

Above `[[ -z "$post_said" ]] || echo "::error title=Compile check::NO_VERDICT: GitHub r` in `.github/workflows/cmux-next.yml`.

NO_VERDICT: a verdict GitHub never took leaves the status as last posted (pending); say so and how to fix.

## note-523

Above `- THIRD_PARTY_LICENSES.md` in `.github/workflows/cmux-next.yml`.

An app resource the Xcode project copies (cmux_next_route.py NATIVE_SCRIPT_INPUTS).

## note-524

Above `- scripts/ci/check-screen-share-identity.sh` in `.github/workflows/cmux-next.yml`.

sign-cmux-bundle.sh and ensure-cef.sh read these (cmux_next_route.py NATIVE_SCRIPT_INPUTS).

## note-525

Above `- scripts/cmux-next/generated-autofixable.sh` in `.github/workflows/cmux-next.yml`.

The daemon-test generated-files verdict reads these when the PR autofix may repair a stale export.

## note-526

Above `- scripts/cmux-next/generated-autofixable.sh` in `.github/workflows/cmux-next.yml`.

The daemon-test generated-files verdict reads these when the PR autofix may repair a stale export.

## note-527

Above `- THIRD_PARTY_LICENSES.md` in `.github/workflows/cmux-next.yml`.

An app resource the Xcode project copies (cmux_next_route.py NATIVE_SCRIPT_INPUTS).

## note-528

Above `- scripts/ci/check-screen-share-identity.sh` in `.github/workflows/cmux-next.yml`.

sign-cmux-bundle.sh and ensure-cef.sh read these (cmux_next_route.py NATIVE_SCRIPT_INPUTS).

## note-529

Above `actions: read` in `.github/workflows/cmux-next.yml`.

The queue janitor's pool snapshot, Blacksmith's queued jobs (next_macos_cascade.py).

## note-530

Above `- name: Check out the trusted placement` in `.github/workflows/cmux-next.yml`.

The placement code from the base branch, as ci-macos.yml's admission-placement uses it.

## note-531

Above `if [ -z "$route" ] && [[ "$SIDE_LABEL" == glaeda-side-* ]] && [ "$GITHUB_RUN_ATT` in `.github/workflows/cmux-next.yml`.

The rescue's re-run writes no owned route (side_lane_placement.rerun_main()).

## note-533

Above `if ! command -v timeout >/dev/null; then` in `.github/workflows/cmux-next.yml`.

timeout: GNU timeout, else Homebrew's gtimeout, else scripts/ci/timeout.sh's perl watchdog.

## note-534

Above `printf '#!%s\nPATH="${PATH:+$PATH:}%s" exec %q %q "$@"\n' "$(command -v bash)" "` in `.github/workflows/cmux-next.yml`.

Absolute bash, perl's folder on PATH: a test may run it under a PATH of a few symlinks.

## note-535

Above `python3 tests/test_cmux_next_prepush_main_twin.py` in `.github/workflows/cmux-next.yml`.

A production journey workflow change needs its main twin (#43870); it ran nowhere before.

## note-536

Above `python3 -I tests/test_known_red.py` in `.github/workflows/cmux-next.yml`.

A skip against an issue fails from its checked-in date on (tests/known_red.py).

## note-537

Above `FAST_TIER_STATUS="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID` in `.github/workflows/cmux-next.yml`.

The fast tier's status in this attempt: `completed` when its earlier result is carried.

## note-538

Above `finish() {` in `.github/workflows/cmux-next.yml`.

finish VERDICT: the job's output, its summary and its exit. Only pass exits 0.

## note-539

Above `step=queued; why="$2: step $id still queued after the client's queue wait (clien` in `.github/workflows/cmux-next.yml`.

The client stopped waiting for the queue; the step keeps its place and runs later.

## note-540

Above `CMUX_FAST_CACHE_WORKSPACE: ${{ steps.spm-root.outputs.root || github.workspace }` in `.github/workflows/cmux-next.yml`.

The seed's key holds the path it was built at: the seed root on an owned mini.

## note-541

Above `verdict=` in `.github/workflows/cmux-next.yml`.

The build failed or the checks never ran: no verdict, which generated-verdict fails.

## note-542

Above `verdict=` in `.github/workflows/cmux-next.yml`.

The build failed or the checks never ran: no verdict, which generated-verdict fails.

## note-543

Above `CMUX_FAST_CACHE_WORKSPACE: ${{ steps.spm-root.outputs.root || github.workspace }}` in `.github/workflows/cmux-next.yml`.

The seed's key holds the path it was built at: the seed root on an owned mini. The script hashes
CMUX_FAST_CACHE_WORKSPACE (else GITHUB_WORKSPACE), never its ROOT argument, so a name of our own
keyed the runner's checkout path and no restore ever matched (0 of 2026-11-22's generated-files
runs on the minis restored the seed: every build cold).

## note-544

Above `base="$RUNNER_TEMP/pr-autofix-base"` in `.github/workflows/cmux-next.yml`.

The base's scripts, as the PR autofix's Mac job runs them; HEAD^1 is the base, HEAD^2 the head.

## note-545

Above `[[ "$CMUX_NEXT_RUNNER" == glaeda-* || "${CMUX_NEXT_DEV_VM_CACHE:-}" == 1 ]] || e` in `.github/workflows/cmux-next.yml`.

A mini keeps the cache between jobs; a Blacksmith VM got it from actions/cache above.

## note-546

Above `- name: Save the DEV compile cache (Blacksmith)` in `.github/workflows/cmux-next.yml`.

The compile already pruned it to its bound (or dropped it past 6 GiB: lib/compilation-cache.sh).

## note-547

Above `post_end=$((SECONDS + ${POST_END_SECONDS:-3240}))` in `.github/workflows/cmux-next.yml`.

post()'s rate-limit waits end here: the step's 56 min less a last try, inside the token's hour.

## note-548

Above `post_end=$((SECONDS + ${POST_END_SECONDS:-3240}))` in `.github/workflows/cmux-next.yml`.

post()'s rate-limit waits end here: the step's 56 min less a last try, inside the token's hour.

## note-549

Above `case "$FAST/$MAC" in` in `.github/workflows/cmux-next.yml`.

The fast check's own verdict (a gateway's fleet compile) first, else the Mac Release compile.

## note-550

Above `[[ "$state" != error ]] || { echo "::error::no verdict: cmux-next/compile for $S` in `.github/workflows/cmux-next.yml`.

The needs_verdict rule's words: a fallback's red is a red, nothing ran is no verdict (exit 3).

## note-551

Above `if [[ "$word" == superseded && -z "${PR:-}" ]]; then` in `.github/workflows/cmux-next.yml`.

A feat-cmux-next push whose tip the controller will not check, because a newer push tip is checked
instead (cmuxterm-hq cmux_next_tip_debounce.go), skips its fleet compile and the Mac canary, as a push
the preflight already found superseded does. The branch head is read again first; a head that has not
moved, or one that cannot be read, compiles as before. 2026-11-22 05-09Z: 120 pushes, 97 push-tip checks
(432 machine-min), 91 of them inside the 10-minute window, each queued by its own push run's read.

## note-552

Above `CMUX_LAN_CACHE_TIMEOUT: "480"` in `.github/workflows/cmux-next.yml`.

A base seed restore waits at most 8 minutes for the LAN cache host, then downloads the seed itself.
lan_cache_fetch.py's own bound is 5,420 s, longer than the 60-minute jobs that restore a seed. On
2026-11-22 a stalled cache host held fast-tier seed restores 14 minutes before the broker gave up
("LAN cache host unavailable (...: stalled)"), and the direct download then took 9 more: restores of
1,289-1,600 s, in jobs cancelled at the 60-minute limit while still building CmuxNext. A healthy host
serves the 3.6 GB seed in about 40 s, or 343 s when it first fills it from the bucket (wait 304 s).

## note-553

Above `jobs:` in `.github/workflows/cmux-next.yml`.

The macOS jobs run as a side lane, like relay-tls.yml and reload-build.yml: Trusted runs (a same-repository
pull request, a push or a dispatch) stay on vars.CI_SIDE_LANE_RUNNER, the minis' glaeda-side-* label, while
owned pools are on (CI_PR_POOL_OWNED is 1). Fork pull requests keep their fallback. Manual reruns stay
minis-first. The rescue re-admits a queued run after the five-minute queue alarm: placement first uses a free
owned GUI/session Mac, then the workflow's Blacksmith macOS route. macos-placement records idle side runners
with the main picker's idle_placement() and publishes free role labels for the bot retry, so a job does not
keep a shared concurrency slot on a busy Blacksmith label indefinitely. When a job takes the side label,
macos-placement uploads the owned-pool-watch marker: ci-owned-pool-rescue.yml's sweeper on main adopts the run
(owned_pool_rescue.SIDE_WORKFLOW_PATHS) and re-runs a job a mini leaves queued or refuses. Bot attempt 2 and
later drop the stale placement output and re-admits it through the same fast-checks/owned-Mac/Blacksmith
order; a person's re-run stays on the side label.

## note-554

Above `SUPERSEDED_GATE` and `superseded="" head_read=""` in compile-status, and above `if [[ "$state" == superseded ]]` in
release-compile-fast, in `.github/workflows/cmux-next.yml`.

A feat-cmux-next push the controller will not check (its receipt reads `"state": "superseded"`, a newer push tip
is checked instead: note-551, cmuxterm-hq cmux_next_tip_debounce.go) gets no compile result, ever. compile-status
did not take that state as final: it read it every 30 s for its whole 40 minutes, then posted
`[no-verdict] No compile result for this head in 40 minutes` and failed, and release-compile-fast then read it for
20 more minutes and handed the head to the Mac fallback. 2026-11-21 04Z..11-23 05Z: 159 failed compile-status jobs
on feat-cmux-next pushes, 5,774 runner-min (p50 40.1 min each), about 4 min per merged PR.

Now both read the branch head once (anonymous `git ls-remote`, no token) when the receipt says superseded and the run
has no pull request. A head that moved on ends the wait at once: compile-status posts cmux-next/compile `error`
`[no-verdict] [superseded] ...` (still no verdict to base_red_excuse.py's COMPILE_STATUS_NO_VERDICT) and ends green;
release-compile-fast ends green with verdict `superseded`, so neither the admission job nor the Mac Release compile
runs, as for a push the preflight found superseded. A head that has not moved, or that cannot be read, waits as
before. Nothing that compiles is skipped: the newer tip's check covers these commits, and a red there names them.
Undo: vars.CMUX_NEXT_SUPERSEDED_COMPILE_GATE = '0'.

## note-555

Above `macos-placement: CI_FAST_TIER_FLEET_SPILL` in `.github/workflows/cmux-next.yml`.

With Blacksmith macOS off, a FLEET_CLIENT_JOBS job (the fast tier) that no idle mini took is listed in
fleet_jobs, so its build-fleet client runs it on an idle gateway runner instead of waiting on the owned
label (next_macos_cascade.fleet_spill()). 2026-11-23 09-11Z the fast tier queued 46 to 65 min on
glaeda-side-std-xcode-26.6 before starting; at 11:33Z the label had 173 jobs queued (87 of them fast tier,
76 over 10 min), oldest 318 min, and all 31 of its slots busy, while placement logged idle gateway runners.
fleet_gateway() still keeps the job only with an idle gateway runner of its own, and a fleet verdict
`queued` hands it back, which with the switch off waits on the owned route rather than a Blacksmith label
no runner serves (side_lane_placement.handback()). `vars.CI_FAST_TIER_FLEET_SPILL` set to `0` turns the
spill off; unset or any other value leaves it on.

## note-556

Above the `if:` of `swift-canary-fleet`, `swift-canary`, `fast-tier-rerun-placement`, `fast-tier-fleet` and `fast-tier` in `.github/workflows/cmux-next.yml`.

CI v2 step 11 (Leo, 2026-11-24: "how about finishing up our borg/ci v2? did we finish all 27+ things?"): a
feat-cmux-next pull request runs the fast tier's Swift suites and the Swift canary as the `mac-fast-tier` and
`mac-swift-canary` steps of ci/steps.toml, in pr-pipeline.yml's `mac` job, which pr-router.yml starts only when
the change routes a `mac` step and the head is in the full tier (scripts/ci/pr_router.py FULL_TIER_JOBS). Each
step asks scripts/ci/mac_tiers.py, which reads cmux_next_route.py over the same merge-commit diff, whether its
tier is routed. So fast-tier, fast-tier-fleet, fast-tier-rerun-placement, swift-canary and swift-canary-fleet
lost their pull request clause here (fast-tier-handback-placement follows fast-tier-fleet), and
macos-placement no longer places them for a pull request. A push to feat-cmux-next and a dispatch still run
them here, unchanged.

Above `generated-files-base-red:` in `.github/workflows/cmux-next.yml`.

Leo, 2026-11-24: "de facto, im asking for 99% fewer minutes of ci time, period." In the 24 h to 2026-11-24 11Z,
`cmux-next generated files` ran 581 times for 17,010 runner-min and passed 0 times: base push runs went 41 red,
0 green, and every PR run was red for the base's reasons. There were two shapes. The first was SwiftPM exiting 1 with
`error: cannot find 'PaneMoreShotsTests' in scope` buried in about 43k warning lines; base fixed it at e627e833 but
long-queued PR merge refs predated the fix. The second was the action and settings export judges failing because the
CCmuxAppFFI pin (app-ffi-pin.json) lags the Rust catalog, so the Swift tests read the old catalog; it waits on the
re-pin PR. A PR run of a job red on the base tells nobody anything gh-merge-green does not already excuse, so a pull
request skips it while the newest base push verdict is red (scripts/ci/base_red_skip.py: fails open, 10% audit, the
full-ci label runs it, push and dispatch always run it). `vars.CI_SKIP_WHILE_BASE_RED` set to `0` turns it off.

## note-557

Above `path_route: PR_FAST_ONLY` in `.github/workflows/cmux-next.yml` (the last block of
scripts/ci/cmux-next-steps/classify-pull-request-paths.sh).

Leo, 2026-11-21: "help 100x ci speed and the decrease of needed minutes aka lower resources and lower wall time and
lower machine time while maintaining a partial semblance of checks. and we can infrequenrly have fuller checks."
(cmuxterm-hq goals/ci-verdict-wall-100x.md: PR verdict p50 at most 0.64 min.)

A pull request into feat-cmux-next runs only the PR fast tier in this workflow: the push head preflight, path
routing (its same-tree cmux-tui probe no longer runs, since no daemon or scheme tier is routed), the PR red-checks
comment and the compile-status job, which on a same-repository head hands cmux-next/compile to the build-fleet
controller and ends (it compiles nothing here). The route writes `false` for swift_canary, cmuxnext_swift,
mac_release, macos, generated, swift, daemon, full, fast_tier, fast_tier_cargo and scheme after every other route,
so each job they feed skips through its existing `if:`: macOS placement, the Mac fast tier and its fleet jobs, the
Swift canary, the app compile placement and fleet app compile, web bundles, swift test, daemon tests, generated
files, the Release compile, the scheme compile and crash-ends-app, and the cargo fast tier (10 to 17 min on
2026-11-24 PR runs). All of them still run on the feat-cmux-next push run and the base tier (the batched tier); a
red there is fixed forward.

Skipped is a passing verdict to land-judge (PASSING: success, neutral, skipped; a skip with no cancel in its run is
a routed skip, not "skipped by a cancel") and to next-autoland, whose Swift-package rule still dispatches
cmux-next.yml on the branch for a missing swift test (swift_dispatch) as before, and whose cmux-next/compile rule is
answered by the controller status that compile-status still requests. No check goes missing: each skipped job keeps
its check run.

The full-ci label runs every tier on the PR as before (labeling a PR full-ci re-runs this workflow). The dev-build
label keeps its scheme compile. `vars.CI_PR_FAST_ONLY` set to `0` turns the whole block off; unset or any other
value leaves it on.

Above `runs-on` in app-compile-fleet and swift-canary-fleet in `.github/workflows/cmux-next.yml`.

Both jobs used to take a gateway runner and hold it while the build fleet compiled the head: the client
submitted the Debug `--app` compile and waited up to 25 minutes for it. 2026-11-23..24, app-compile-fleet held
gateway runners for about 22,900 runner-min a day (1,791 jobs) doing nothing but wait.

Now the compile check posts its result back instead of holding a runner. The controller (cmuxterm-hq
cmux_next_app_debug_check.go) submits the Debug `--app` compile of a same-repository pull request head when
it sees either job queued, or when the job's read names the pull request, and serves the record at
`compile-checks/v1/<sha>?phase=app-debug` (configuration `debug`, recipe 2). That record never stands for the
land Release. The job runs on cmux-linux and reads only that record with the trusted base copy of
scripts/ci/fleet_compile_result.py (`--phase app-debug`). The check name, its `if`, its placement and its
verdicts are unchanged: pass is green, fail is red, and no result in 40 minutes (no record after 5 minutes,
the service down, or a base reader without the phase) is `unavailable` and fails closed, as a cmux-ci exit
other than 0, 1 or 75 did. A check the fleet still holds queued (`pending`) is a warning, as exit 75 was. swift-canary-fleet does the same for a pull request; any non-pass still lets the Mac
canary run, and a push keeps its tip-check read and gateway compile.

## note-fast-tier-current-base

Above `fast-tier: Build on the base's current tip` in `.github/workflows/cmux-next.yml`.

A pull_request run checks out the merge commit GitHub made when the run was queued, and the fast tier waits 1 to
4 hours for a Mac. So it compiled bases hours old: on 2026-11-24 from 01:30 to 03:02Z it failed 50 times and
passed 3 (34 runner-hours). Every failure sampled was the BrowserPageTunables compile error from #48267, which
#53025 had fixed at 01:07Z. Job 138099435473 started at 02:16Z on a base from 23:34Z, 151 commits behind.
scripts/ci/fast_tier_current_base.py applies the pull request's merged change to the base's current tip in a
scratch index and checks out a merge commit with parents (tip, PR head). On any failure (a conflict, a fetch that
fails or times out), the run's own merge stays checked out. `vars.CI_FAST_TIER_CURRENT_BASE` set to `0` turns it
off.

## note-pr-control-pool

Above `push-head-preflight` in `.github/workflows/cmux-next.yml` (moved here to keep the workflow under its size limit).

Its Linux control jobs (this one, the placements, release-compile-fast-admission, dev-landing-place) take
cmux-linux, the persistent runner pool, on a push's or same-repo PR's attempt 1 (cmuxterm-hq decisions/junctions.md:
one label for every own-branch Linux job). They took cmux-gcp-pr-control-jit-x64, one-job JIT VMs, until that label
queued 1,860 jobs (oldest about 2 h, 2026-11-21) while the pool had about 300 runners idle. compile-status and its
handoff stay on that label: each holds a statuses write App token (# ephemeral-required on its runs-on).
Not cmux-gcp-nightly-jit-x64: on 2026-11-20 these jobs filled it (333 queued) and the nightly's own
pick-nightly-app-runner waited behind them; that label serves nightly runs only. A re-run falls through to the pools.

## note-affected-set-replay

How much of a PR's verdict goes to checks its diff could not have made fail (Leo, 2026-11-21: "help 100x ci speed
... while maintaining a partial semblance of checks. and we can infrequenrly have fuller checks."). Replayed over
the last 20 non-bot PRs squash-merged into feat-cmux-next with `scripts/ci/affected_set_replay.py fetch` then
`report` (input map and assumptions in its header; test `tests/test_ci_affected_set_replay.py`). It is also the
before-number for cmux#54763.

| Measure (20 PRs, 2026-11-24) | Value |
| --- | --- |
| Machine minutes on checks the diff could not have failed | 103 of 1396 (7%) |
| Verdict wall summed, affected-only vs all | 1367 of 1380 min (1% less) |
| Verdict wall p50, all checks that ran | 29.4 min |
| Critical-path wall p50, affected checks only | 29.4 min |
| Costliest unaffectable checks (machine min) | tooling-tests 64, app compile (build fleet) 16, fast tier (cargo) 12 |

Reading: path routing already skips what the diff cannot touch (a skipped check costs nothing and is not counted),
so the checks that did run were nearly all inputs of the diff, the PR itself, or the routers that decide the rest.
An ideal input-based routing would save about 7% of minutes and almost no wall; the verdict wall is the slowest
affected check (and queue and reruns), not unaffected work. Lower bound: routers, placement, comment and
PR-metadata jobs and unknown checks count as affected, and CI plumbing paths are an input of every check.

## note-stall-step-bounds

Above the bounded checkout, setup and cache steps: `web-bundles` and `fast-tier-cargo` in
`.github/workflows/cmux-next.yml`, `agent-pane-real-acpmux` in `ci-web.yml`, the Bun cache restore in
`cmux-next-web-lint.yml`, `workflow-guard-history` in `ci-guards.yml` and backend.yml's `test` job.

Leo, 2026-11-21: "de facto, im asking for 99% fewer minutes of ci time, period." On 2026-11-23, pull request jobs
cancelled after they started cost 148,161 runner-min (130 per merged PR, 1,139 merged). The check-run annotations of
80 of them, sampled by minutes, read: 70 "The job has exceeded the maximum execution time", 8 "Canceling since a higher
priority waiting request ... exists" (a newer push), 2 cancelled by a person or bot. Of 30 timed-out jobs read step by
step, 13 had stalled in a checkout, toolchain setup or cache step (actions/checkout up to 29 min, Set up pinned Rust
10 to 13 min, setup-node 34 min, a Bun cache restore 7 to 11 min), on the self-hosted Linux pools (`fsr-*`,
`cmux-runner-pool-*`); healthy, they take seconds to about a minute. The job then held its runner for its whole limit
(15 to 55 min) before going red.

Healthy durations (26 successful runs, 2026-11-23): every checkout step 261 samples, p50 1 s, p99 123 s, max
193 s (the full-tree checkouts in these jobs p50 about 70 s, max 81 s); Set up pinned Rust max 2 s on a warm runner;
a Bun cache restore max 46 s. The bounds are a few times those: checkout 6 min, Set up pinned Rust 8 min (room for a
fresh runner's rustup install), setup-node and setup-python 5 min, Bun and web-bundle cache restores 4 min. A
stalled checkout or setup now fails its job in minutes instead of its full limit; it is still a red job to re-run,
as before, only sooner. A cache step that passes its bound continues (`continue-on-error`): the job runs on as on a
cache miss, so the bound never fails a job that would have passed. No step that runs code is bounded here, and no
job limit changes.

Stalls these bounds cannot reach: a job that hangs in the runner's own `Set up runner` or `Complete runner` (5 of the
30), before or after every workflow step. Those are the runner pools' to fix (goal-linux-pool for cmux-runner-pool,
freestyle-ci-first-class for fsr), or a shorter job `timeout-minutes` on the light jobs they hit.

## note-558

Above `fleet_queue_p90()` and its check in `fleet_gateway()` in `scripts/ci/side_lane_placement.py`
(the `macos-placement` job's "Place the macOS jobs" step).

Placement lists fast-tier for the build fleet (note-555's spill) only when the fleet could start its steps
within the client's 20-minute queue wait. In the 24 hours to 2026-11-24 22Z, none of fast-tier-fleet's 771
green runs had a fleet verdict inside 20 minutes: every one waited out `--queue-timeout 1200` (p50 21.2 min,
16,548 gateway runner-min) and handed the tier back (725 hand-back placements). The light class's p90 queue
wait was 3,317 s. A step the client stops waiting for keeps its place (note-539) and later runs for nobody,
ahead of the work queued after it (cmuxterm-hq docs/handbook/process-outlives-its-reader.md): about 1,500
such steps a day.

So placement reads the controller's `/v1/status` (`step_queue_wait_p90_seconds.light`, 5 s timeout), like
cmux-next-tab-switch.yml's admission. Past 1200 s it lists no fleet job: fast-tier-fleet is skipped and
`cmux-next fast tier` keeps the route the cascade gave it, with the reason in placement's summary. The
gateway job still runs nothing but the client. An unreadable status lists the job as before (fail open).

## note-head-fail-fast

Above each `*-fail-fast:` job in `.github/workflows/cmux-next.yml` (and the same callers in
`cmux-next-fast-gates.yml`, `cmux-next-guards.yml`, and `pr-router.yml`'s `pipeline-fail-fast`, which watches its `pipeline` call of `pr-pipeline.yml`: pr-pipeline.yml takes only ci/steps.toml jobs). Since 11-26 pr-router.yml calls cmux-next-fast-gates.yml too, so its fail-fast job runs inside the router's run: it reads that run's failed jobs and, never cancelling its own run, cancels only the other HEAVY runs of the head; a fast gates run is no longer a HEAVY target of the others (its path is pr-router.yml, about two minutes on Linux).

Leo, 2026-11-21: "de facto, im asking for 99% fewer minutes of ci time, period." Over 2026-11-23T20..2026-11-24T20Z
(controller timing feed, manaflow-ai/cmux pull request jobs), once a non-advisory job of a head had failed, the
head's other jobs kept running for 238,776 runner-min a day. A red head never lands as it is. So when one of the
jobs a head most often first fails on (app compile, fast tier, fast tier cargo, web bundles, generated files, fast
gates, tooling-tests, pr pipeline) fails, a caller job that needs only that job runs
`head-fail-fast.yml`: unless the failed job is red on the base too (land-judge excuses that red), it cancels the
head's other heavy pull_request runs still queued or running, never its own run, and lists them in its summary.
Replayed on that day's jobs, these triggers fire on 2,053 heads and cut about 51.7k runner-min a day net (54.2k no longer spent after the trigger, less 2.4k re-spent on the 250 heads later rerun). The failed check stays the head's verdict. `vars.CI_HEAD_FAIL_FAST` set to `0` turns it off; a full-ci label or a
fork's pull request never cancels. Rules: `scripts/ci/head_fail_fast.py`.

## note-559

Above the fast-tier-cargo job's env in `.github/workflows/cmux-next.yml`, its "List the changed paths" and run
steps, and `scope()` in `scripts/cmux-next/fast-tier.py`.

Leo, 2026-11-21: "de facto, im asking for 99% fewer minutes of ci time, period." A pull request into
feat-cmux-next runs only the fast tier entries, and the compiles, its change reaches; the full run moved into
the post-merge batch (suite `fast-tier`, cmux-next-fast-tier-batch.yml), where the judge bisects a red to its
commit.

`fast-tier.py --changed-files` picks the entries: a cargo entry when the change reaches its crate's inputs in
affected_jobs.py's crate graph (or the workspace inputs, or fast_tier_cargo_route.py's LINKED); a CmuxNext
suite when cmux_next_route.py routes the change to it (full, all tests, the fast registry, a priority suite or
its test targets); another swift package when the change is under it or a local `.package(path:)` it depends
on; a script entry when the change is under its folder. A cargo compile still runs when the change reaches the
job's inputs, so a broken build is still caught on the pull request. An unreadable list, the `full-ci` label, a
change to fast-tier.py, its registry or its quarantine, or a routing error runs every entry.

fast-tier-cargo writes the merge commit's first-parent diff and adds its hash to the job-reuse fingerprint
(`--extra scope=...`), so a scoped pass is never reused for a full one. The Mac fast tier step
(ci/steps.toml `mac-fast-tier`) passes `CI_PATHS_FILE` when no FFI repin selected its own suites. Pushes to
feat-cmux-next still run every entry.

The switch: `vars.CI_FAST_TIER_PR_SCOPE` set to `0` runs every entry on the pull request again (both jobs).

## note-scheme-fleet

Above the `cmux-scheme-compile-fleet` job, the `CMUX_SCHEME_FLEET_JOB` env, and the "Take the app the build fleet
built" and "Compare the fleet app with this compile" steps of `cmux-scheme-compile` in `.github/workflows/cmux-next.yml`.

Leo, 2026-11-25: "can't we nearly 100x reduce the amount we need to wait on mac fleet?" and "i need us to be defo
making sure it runs on our scheduler ... having our mac fleet be able to like... exist as fallbacks if we fucked up
logic ... is still fine. but if like... it works ... and is at least as fast if not faster, then we ought to just go
ahead."

The Debug scheme compile was the largest Mac job: 7 days to 2026-11-25, 1,138 runs, 48.2 Mac job-h/day, queue p50
43.7 min and p95 246.6 min, compile p50 17.7 min. The build fleet's `cmux` app recipe builds the same Debug cmux DEV
app; the controller starts it when it sees `cmux app scheme compile (build fleet)` queued and serves the verdict at
compile-checks phase `scheme-debug` with the job id of the app zip.

- `cmux-scheme-compile-fleet` (owned pool runner, no Mac) waits for that verdict. It never fails: anything but `pass`
  with a job id leaves `CMUX_SCHEME_FLEET_JOB` empty.
- `cmux-scheme-compile` with a job id fetches the verified zip (`scripts/cmux-next/fleet-scheme-app.sh`), runs the
  app-personality check on it and skips the toolchain, web-bundle and xcodebuild steps; the crash gate (Mac-native)
  and the dogfood artifact read the fleet app unchanged. A fetch or personality failure logs a `fleet fallback`
  warning and the Mac compiles as before, as does an empty job id.
- Parity: heads whose sha ends in `0` (1 in 16; `vars.CI_SCHEME_FLEET_PARITY=always` for every head) still compile on
  the Mac and compare file lists, Info.plist and Mach-O link lists (`scripts/ci/app_bundle_parity.py`); a difference
  is a `fleet parity` warning with the table in the step summary.
- Off switch: `vars.CI_SCHEME_COMPILE_FLEET=0` skips the fleet job; the Mac compiles every head and says so
  (2026-11-25-fleet-fallback.md); unset is null and null != '0' is false, so the `if` reads `(vars.CI_SCHEME_COMPILE_FLEET || '1') != '0'`. DEV Release (`dev_daily`) compiles are unchanged.

## note-canary-linux-read

Above `swift-canary-fleet: if`, `runs-on` and its push read in `.github/workflows/cmux-next.yml`.

Leo, 2026-11-25: "i need us to be defo making sure it runs on our scheduler, which has far more capabilities
than github actions. github actions is just there at the start and end or whatever maybe i guess, but we own the
in-between. all of it". On a feat-cmux-next push the controller's tip check already compiles the app at the
pushed head (SwiftPM Release -Onone; the record scripts/ci/fleet_compile_result.py reads). The job used to
take an idle gateway Mac runner, read that record for up to 15 min, and compile the head a second time through
`cmux-ci compile-check --app` when there was none (2.6 gateway job-hours on 2026-11-24). It now runs on
cmux-linux for every routed push, with or without an idle gateway, and only reads the record (up to 40 min,
600 s with no record at all). pass and superseded (note-551) let the Mac canary report from a small runner; a
fail runs the Mac canary, which prints the errors; no verdict prints `::warning title=mac fallback::` and runs
the Mac canary, the job's only fallback. macos-placement still judges the gateway for it (GATEWAY_JOBS), which
now only keeps the canary out of the cascade's runner count.

## note-560

Above fast-tier-fleet and fast-tier-fleet-mac in `.github/workflows/cmux-next.yml`, their consumers' verdict
reads, and `scripts/ci/fleet_fast_tier_result.py`.

Leo, 2026-11-25: "i need us to be defo making sure it runs on our scheduler, which has far more capabilities
than github actions. github actions is just there at the start and end or whatever maybe i guess, but we own the
in-between. all of it". fast-tier-fleet held a gateway Mac for up to 50 minutes only to submit two light steps
and wait on them. The controller now submits those same steps itself when the job is queued (cmuxterm-hq
`cmux_next_fast_tier_check.go`, hooked on the job name) and judges them, so the job runs on `cmux-linux` and
reads one verdict: `GET /compile-checks/v1/<sha>?repo=...&phase=fast-tier[&ffi_repin=1]`.

The reader trusts a 200 only when it names phase `fast-tier`, this sha and repo, the asked number of steps, and
steps that ran this head. A controller that predates the phase answers its tip compile receipt, which the reader
turns into `unavailable`, so the two sides merge in either order. `queued` past 20 minutes hands back as the
client's exit 75 did; `unavailable` (no record after 5 minutes, an outage past 2 minutes, a step with no
verdict, still running at 45 minutes) exits 0 and leaves the decision to fast-tier-fleet-mac.

fast-tier-fleet-mac is the old gateway client, unchanged but for its `::warning title=mac fallback::`, and runs
only on `unavailable` while the placement still names a gateway runner for this attempt. Its name differs, so
the controller's hook never fires on it. Consumers read `fast-tier-fleet-mac`'s verdict and result when it ran,
else fast-tier-fleet's; an `unavailable` with no fallback leaves cmux-next fast tier to run the suites itself,
as when no fleet job ran.
## note-cloud-journey-pr-wall

Above `seed`, the R2 restore steps and the workflow `env` in `.github/workflows/cloud-journey-pr.yml`, and
`scripts/cmux-next/cloud-journey-cargo-key.sh`.

`Cloud journey (PR CLI on staging)` was about 24 minutes of a pull request's wall, and most of it was a cold
`cargo build -p cmux-tui` with no cargo cache. In run 45528981033 (PR 55112, Freestyle runner) the job took 37 min:
queue about 3 s, checkout 23 s, submodules 14 s, apt, Rust and Zig setup 39 s, build 30.75 min (624 crates, 489 of
them dependencies; the `cmux-tui` crate alone 18 min at `opt-level = 1` with full debuginfo), staging journey 5 min.
Twelve recent runs: build 11 to 31 min, journey 5 to 9 min, total 20 to 37 min. Path routing was already in place,
and only 1 of 21 recent matching pull requests matched through test files alone, so routing was not the cause.

Three changes, the check unchanged:

- The compiled dependencies come from R2 (note-210b's store: public reads, so pull requests restore with no
  credentials). `seed` builds the same binary on a feat-cmux-next push that changes the key's inputs (lockfiles,
  toolchain, this workflow, the key script) or on a dispatch there. It skips when the exact key exists, strips
  the workspace's own output (`cargo_target_strip.py`) and saves the target and the registry. It is its own job
  because the R2 write keys live in `next-cache-writer` (tests/test_ci_pull_request_caches_are_read_only.py), and
  `journey` already holds `cmux-next-vm-image-dev`. A miss or a slow restore (4 min bound, continue-on-error)
  builds cold as before.
- The workspace crates build at `opt-level 0` with `debug = line-tables-only` and no incremental output
  (`CARGO_PROFILE_DEV_*`, `CARGO_INCREMENTAL` in the workflow env). Dependencies keep `profile.dev.package."*"`
  (opt-level 3). The journey is network-bound, and a panic still has file and line. The key hashes these
  variables, so `seed` and `journey` cannot drift.
- `*_tests.rs` and `tests/` under cmux-tui no longer start the journey: neither reaches the binary.

Not changed here: backend.yml's journey-staging, cloud-resume-matrix.yml and migrate-journey-pr.yml run the same
uncached build.

## note-561

Above fast-tier-cargo's first steps in `.github/workflows/cmux-next.yml`: the Freestyle link check.

Freestyle runners (`fsr-*`) carry the shared Linux labels, so the linux_8 pool hands them this job. On
2026-11-26 07:52Z to 08:53Z, 90 fast-tier-cargo jobs ran there and none passed (41 failed, 49 cancelled at the
30-minute job timeout); the 32 passes were all on pool runners, whose checkout took 18 to 74 s. On Freestyle the
checkout from github.com took 7 to 23 minutes (`fatal: ... Operation too slow`, then a retry that hung, job
139761062609), and apt, zig, rustup and the R2 restores after it were each minutes long too (job 139765026748),
so a job that got through its checkout still ran out of time in the build. The runners' pack source list was
missing (`checkout_pack` fallback "no source list"), so every fetch went to github.com.

The checkout is bounded at 6 minutes (note-stall-step-bounds); on a Freestyle runner a checkout over 180 s stops the job with the
cause named: that link cannot finish the job in 30 minutes, so it fails in minutes instead of burning half an
hour. A Freestyle runner with a fast link runs the job as before; pool runners are unchanged.

## note-cheap-gate

Above the gated callers in `.github/workflows/pr-router.yml` (`machine-channel-pr-head`, `screen-share-drop-gate`,
`swift-linux-packages`, `ios-link-ffi-linux`, `pipeline`) and above `release-compile` and `compile-status` in
`.github/workflows/cmux-next.yml`.

Leo, 2026-11-23: "de facto, im asking for 99% fewer minutes of ci time, period." The heavy jobs now start only after a
cheap job has said the head is not red.

- pr-router.yml: since 11-26 the router calls cmux-next-fast-gates.yml as a callee, so fast gates run in the same run
  as the heavy callees. Fast-gates-fail-fast never cancels its own run (note-head-fail-fast), so a red fast gates
  head still paid for the whole pipeline, the machine channel build, Swift packages on Linux and the screen share
  gate. Over 2026-11-25T14Z..11-26T14Z (controller timing feed) those callees spent 43,244 runner-min on runs whose
  fast gates failed: pipeline 19.1k, machine channel 12.7k, Swift on Linux 9.8k, screen share 1.1k. Each of these
  callers now `needs: [route, fast-gates]` and starts only when fast gates did not fail (success, skipped or not
  routed). They skip the gate in the same cases fail-fast does: on a fork, with `full-ci`, outside pull_request, or
  with `vars.CI_HEAD_FAIL_FAST` set to `0`. The size budget and the classic API guard are left ungated: an edit
  re-judges them with no new push. The cost is one fast gates wall time (about 4 min) before the heavy callees
  start on a head.
- cmux-next.yml: #54731 started macos-placement and app-compile-placement only after `fast-tier-cargo` is not red.
  release-compile still started then: app-compile-fleet is skipped, its verdict is empty, and the Release compile
  takes the head. compile-status (the fleet Release compile) never waited at all. Both now take the same
  condition. On runs where cargo failed they spent about 6 to 9k runner-min a day. Cargo skips itself when it is
  red on the base (path_route base_red_jobs), so a red base does not hold them.

Rerunning the failed fast gates or cargo job (`gh run rerun ID --failed`) reruns the jobs it skipped.
Tests: tests/test_ci_head_fail_fast.py CheapGateTests.
