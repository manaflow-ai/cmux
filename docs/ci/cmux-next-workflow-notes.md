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
