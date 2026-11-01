#!/usr/bin/env python3
"""Move a pull request CI run off a busy persistent macOS pool.

pr_runner_pool.py picks one pool per run. When that pool is owned (a
`glaeda-<class>-xcode-<version>` label, pr_runner_pool.persistent), the jobs
it names in `owned_jobs` take it and the rest take retry_runner (Blacksmith).
GitHub never re-routes a queued job: one on the owned pool waits for it
however long the pool stays busy. ci-owned-pool-rescue.yml runs this script
from the default branch, with Actions write, as one sweeper (SWEEP=1,
sweep()): it finds the runs placed on an owned pool by their fixed-name
markers and gives each a thread running follow(), the per-run watch described
below. A dispatch with a run's id (WATCH_RUN_ID) watches that run alone,
checked as a workflow_run event's run would be.

The script waits for ci.yml's `changes` job, which runs the picker. When the
picker chose a persistent pool, that job uploads a marker artifact
(`macos-pool-persistent-<run id>-<attempt>-<jobs>p<placed>-<pool>`, the counts and pool
for the janitor's count); no marker means the run is on an
ephemeral pool and the watch ends. Otherwise it watches the run's jobs until the
run finishes. If a job on the persistent pool is still queued with no runner
after the budget (CI_OWNED_POOL_RESCUE_SECONDS, 90 by default), it confirms the
pull request head has not moved, cancels the run, waits for it to finish, and
re-runs it. The re-run is attempt 2, which runs `changes` again: the picker
places it like attempt 1 without queueing (pr_runner_pool.LAST_OWNED_ATTEMPT),
on the owned machines free now and Blacksmith for the rest. The sweeper finds
attempt 2 among the unfinished CI runs (owned_reruns()) and watches it the way
it watches attempt 1: it waits for `changes` and looks for attempt 2's own
marker (the marker name carries the attempt), because a macOS job gets its
label only after the picker has chosen, then for late-placement's. A job stuck
or refused there has its failed and cancelled jobs re-run on attempt 3, which
always takes Blacksmith.

A queue rescue never moves a job onto a Blacksmith label the pickers call
stalled (simple_pool_picker.blacksmith_stalled(), read from the janitor's
snapshot): while the label its re-run would take (the workflow's runs-on
fallback) is stalled, the job stays queued on its owned pool, and while that
label has no free slot it moves only after OWNED_WAIT_FLOOR_SECONDS
(hold_for_destination()). A re-run the picker places again (ci.yml's
attempt 2) is not held.

A run whose pull request is still open at the run's head is never
cancelled, whatever the watch saw (rescue(), OPEN_HEAD_RULE): run
40398277457 (cmux-next, PR #25446) attempt 1 was cancelled and re-run here,
and its attempt 2 was then cancelled by the janitor and left cancelled. So
the cancel-and-re-run in this docstring applies only to runs with no pull
request (main, nightly, E2E and side-lane pushes and dispatches); a stuck
pull request job waits, and the controller's fall-through moves its compile.
A refused job's failed jobs are still re-run once its run has finished (no
cancel), and a superseded or closed pull request's run is handled as before.

The one exception is the rulebook's stall-aware failover (Leo, 2026-10-28: "a
job queued more than about 3 minutes on a label that has started nothing is
cancelled and re-dispatched onto a live member of the set") where nothing is
lost (unstarted_failover()): no macOS job of the run has been taken by a
runner, in this attempt or a carried one, and no job runs; a job has waited
UNSTARTED_STALL_SECONDS or more for a runner on a label the janitor's snapshot
shows running nothing; and the run is no nightly, DEV or promote build. Then
the rescue cancels the run and at once re-runs every job at the same head, so
the placement runs again and checks the routes afresh. A job that starts
before the cancel goes out drops it (OpenHeadStarted). Run 40887257098
(cmux-next, PR #26999) waited from 15:20Z to 18:41Z on a session label with no
runner online while OPEN_HEAD_RULE kept it there.

A cmux-next pull request run's first attempt is re-run from its macOS
placement instead (placement_rerun()): the placement and the jobs that need it
run again, and every other finished job keeps its result, so its Linux checks,
which always finish before a Mac job has waited three minutes, no longer keep
the failover off, and a red `checks` is not repeated. watch() offers a run
the failover every FAILOVER_LOOK_SECONDS while a job of it waits, whatever
kept the queue rescue off (a red sibling, a refusals-only watch, a hold). From
2026-10-29 to 10-30 the failover moved no run: run 40993742146 (PR #27797)
waited over five hours with its fast tier queued behind a red `checks`, and
every snapshot read after a sweeper's first hour was refused with its
expired first token (fixed separately, cmux#28163).

Where that re-run would repeat a finished job (a red swift test below the
placement, or any finished job of another workflow or a later attempt) but
no job of the run is running or held by a runner, the settled-sibling
failover moves it instead (open_head_failover()'s `settled`): the cancel
stops only jobs still waiting for a runner, every finished job keeps its
result, and only what waited runs again, that one job and the jobs that need
it, or the failed and cancelled jobs when several waited. Run 40997814347
(PR #27853) had 28 of 29 jobs finished and its Release compile queued on
glaeda-std-xcode-26.6 for over four hours while that label ran nothing.

An owned runner can also refuse a job it was handed: glaeda's job-started
hook exits 1 when the host is busy (its lock is held), and the job fails
within seconds, before any step of the workflow succeeds. GitHub does not
retry it, so the pull request would stay red until someone re-ran it. A job
on the persistent pool that failed within REFUSAL_SECONDS of starting, with
its runner setup step failed or no workflow step succeeded, counts as refused
(compile admission's `always()` metrics steps still succeed after a refusal).
A failed "Set up runner" step, the one glaeda's hook runs in, counts whatever
its length (hook_refused()): the hook waits there for capacity with no limit,
so a refusal for a fleet build that began waiting meanwhile comes long after
REFUSAL_SECONDS. A failed job that ran no step at all counts too, whatever its length: GitHub
fails a job whose runner went away only after 10 minutes ("The self-hosted
runner lost communication with the server"), and so does one with a step
GitHub cancelled while the job failed: its runner was stopped mid-job ("The
runner has received a shutdown signal"). A failed Select Xcode or Select
helper Xcode step also counts, without a time limit, because a missing pin is
a machine fault even when a helper build succeeded first. The watcher lets the rest of the
run finish, since GitHub re-runs no job of a run in progress and cancelling
it would kill every healthy sibling, then confirms the head has not moved and
re-runs its failed jobs. Only a run still going at the watch's end, or main's
full-suite run (whose failure would open main's red-CI issue), is cancelled
first. GitHub can also hand a job to an owned runner that never takes it, and
after a few minutes it cancels that job alone ("The job was not acquired by
Runner of type self-hosted even after multiple attempts"): cancelled, with no
runner and no step (unacquired()). A run cancelled as a whole leaves its queued
jobs the same way, so such a job counts as refused only once its run has
finished with another conclusion; its failed and cancelled jobs are re-run.
That attempt 2 reuses attempt 1's outputs, so its owned jobs take the owned
labels again (a runner pinned on attempt 1 is not reused) and what already
passed (compile admission, say) is kept. A run on an owned pool is split across pools
anyway (per-job placement, CI_PR_POOL_OWNED_SPLIT), which is
sound only because both sides run the same Xcode: retry_runner is a macOS
26 pool on the lane's pin, the pin the owned label names, and on 2026-09-24
both the minis and Blacksmith's 6vcpu and 12vcpu macOS 26 images reported
Xcode 26.6 build 17F113. If those builds ever differ, re-run the whole run
here instead (rescue with failed_only=False).

glaeda's hook does not refuse a job for the mini's capacity: it waits, with
no limit, inside the runner's setup until the units and tokens the job needs
are free. A job on the persistent pool still in its runner's setup
SETUP_WAIT_SECONDS after it started is stuck like a queued one: once no
sibling is still running (or the watch is about to end), the run is cancelled
and re-run the same way. Until then the job is not accepted, so the watch goes
on.

Attempt 2 goes back to the fleet whoever started it: the failure
attribution's re-run after a machine failure, this rescue's after a refusal
or a stuck queue, or a person's. The job takes the owned label, not the mini
that failed it: a runner that lost communication is offline, and a busy
mini's gui runner stops listening. A person's re-run of a pull request (a code
failure) goes back to the minis on any attempt. Neither has a marker of its
own; the sweeper finds them among the unfinished CI runs (owned_reruns()) and
watches them like attempt 1, and a job stuck or refused there gets the bot's
next re-run, which every runs-on sends to retry_runner (Blacksmith) from
attempt 3 on, so a refusal costs two re-runs at most. cmux-next's bot attempt
3 is the exception: it keeps macos-placement's mini label, so it is watched
for refusals only and a refused one goes to Blacksmith as attempt 4
(REFUSAL_RESCUE_ATTEMPT), three re-runs at most.

E2E runs (test-e2e.yml) are watched the same way. Its `runner` job runs
e2e_runner_pool.py, which may pick an owned pool, and uploads the same marker
(with 1 job). An E2E run is a workflow_dispatch, not a pull request, so there
is no head to re-check, and its build and test jobs are not a split that can
break. A stuck or refused E2E job gets its failed and cancelled jobs re-run,
keeping a build that passed; those jobs keep attempt 1's pick, so they take
the runner job's retry_label, a macOS 26 Blacksmith pool on the same Xcode
build, and the follow-on watch of attempt 2 finds no owned job and stops.
A UI run's retry_label stays on its owned pool, since Blacksmith cannot run UI
tests (e2e_runner_pool.py), so the watch of attempt 2 may re-run it once more;
no attempt past 2 is watched, so it still never loops. A queued UI run moved
that way only rejoins the same owned queue, costing its place in it; the watch
stays for the refusals, which a re-run does clear. When the build itself did
not succeed, every job is re-run instead, so the `sibling` job looks again for
another run compiling the same revision (e2e_build_unfinished), and the runner
job picks again: attempt 2 takes that live pick, which may be an owned Mac,
because a Blacksmith re-run cannot adopt a product an owned Mac compiled (their
Rust toolchains differ) and so compiled it again. That attempt is followed like
a full re-run, by its picker and its own marker, and attempt 3 and later always
take retry_label. A stuck E2E run that finished some other way (a newer dispatch
in its concurrency group cancelled it) is not re-run, since that would cancel
the newer one. Its watch lasts E2E_WATCH_LIMIT_SECONDS, since its test job
queues only after a sibling wait and a build.

Main's full-suite dispatch of ci.yml (ci-main-full-suite.yml, a
workflow_dispatch on main) is watched exactly like a pull request run:
pr_runner_pool.py may put it on an owned pool like a pull request, and its
`changes` job uploads the
same marker. It has no pull request, so in place of the pull request head it
checks main's HEAD: once main has moved past the run's commit, a stuck run is
cancelled but not re-run, because its completion makes
ci-main-full-suite.yml dispatch the newer HEAD, and a re-run would only queue
the older commit behind it in main's CI concurrency group. A refused job's
failed jobs are re-run whether or not main moved, so a fleet refusal never
leaves main's run red.

Dispatches of test-ios.yml and ios-screenshots.yml are watched exactly like an
E2E run (DISPATCH_WORKFLOW_PATHS). Their `runner` job runs ios_runner_pool.py,
which may put the iOS jobs on an owned pool with the glaeda-ios-sim capability
label, and uploads the same marker; from attempt 2 on every macOS job takes
its retry_runs_on, the Blacksmith pool. A job asking for a capability label no
idle mini carries waits like any other queued owned job, so it is moved after
the same budget.

Dispatches of iroh-release-gate.yml, and of cmux-next-dev-daily.yml (its
verify job), are watched the same way. Its `runner`
job runs e2e_runner_pool.py for the Tailscale version-skew job alone, and
only takes an owned pool with a machine free now (no queue rounds), so that
job rarely waits. Its simulator-e2e jobs stay on Blacksmith, but they run in
the same run: a stuck owned job's rescue cancels them with it, and a refused
one's waits for them until the watch ends. The re-run of failed and
cancelled jobs keeps the modes that passed and puts everything on Blacksmith.

A DEV daily or nightly run whose owned job GitHub timed out is a machine
fault too (feed_timeouts()): a job's timeout-minutes counts the time in its
runner's setup (glaeda's capacity wait) and a slow mini's checkout, so a
healthy job on a busy or slow mini is cancelled with "The job has exceeded the
maximum execution time" (DEV run 40466210697, 2026-10-27: verify's checkout
took 12 minutes and tip-dmg-build waited 19 in setup, then both timed out and
the watch stopped with "the run finished"). GitHub concludes such a job and
its run `cancelled`, as if someone had cancelled them. Once the run finished,
an owned job that ran on a runner, concluded cancelled, and lasted its
workflow's timeout-minutes counts as refused: its failed and cancelled jobs
are re-run, and attempt 2 takes Blacksmith. A started DEV or nightly build is
never left cancelled for a slow runner.

Side-lane workflows (SIDE_WORKFLOW_PATHS) have no picker. On attempt 1 of a
trusted run (a same-repository pull request, or a push, schedule or
workflow_dispatch, whose code is this repository's own branch; see
TRUSTED_SIDE_EVENTS), their small macOS jobs take vars.CI_LIGHT_LANE_RUNNER
(the light minis' side label) or vars.CI_SIDE_LANE_RUNNER (the std minis'),
both glaeda-side-* labels that only the minis' non-root runners carry. Most
side lanes take the job's Blacksmith default on attempt 2 and later. cmux-next
keeps trusted attempts 1 and 2 on the owned side label and only overflows a
later bot attempt after its ten-minute queue budget. So the first job on an owned label marks the run as on a persistent
pool (a job behind a Linux gate appears once the gate ends), and the watch
stops once every owned job has been accepted, which a side lane's few short
jobs reach in minutes. A refused side-lane job gets the run's failed jobs
re-run; a stuck one gets the run cancelled and its failed and cancelled jobs
re-run, keeping the jobs that had already finished. That re-run takes the
lane's configured retry route, so the watch ends there or continues on
cmux-next's owned label. A
stuck run that finished some other way (a newer push cancelled it) is not
re-run. Its watch lasts SIDE_WATCH_LIMIT_SECONDS. A nightly-next watch does
not end when its accepted jobs are all that exist: prepare-nightly-variant takes
the side label only after build-nightly-app finishes, so it lasts until the
run finishes, within NIGHTLY_WATCH_LIMIT_SECONDS. Side lanes upload no marker
(cmux-next.yml aside), so the sweeper finds one's run by path once it has
failed (GitHub.failed_runs()), which a refused job makes it: its failed jobs
are re-run then. It also finds one by path while it is queued
(GitHub.queued_side_runs()): a job waiting on a label that starts nothing
never fails its run, so before that listing such a run was never watched
(run 41055587932, 2026-10-30, over five hours). A failed job of such a run that is not a refusal keeps it
red (a re-run of failed jobs would repeat it), except one that needs a refused
job, directly or through others, with no other failure or cancel upstream of it:
an `if: always()` aggregator such as cmux-tui.yml's hosted-verification fails
whenever a leg it requires was refused, so it fails only because of the refusal
(downstream_of_refusals(), which reads the `needs` graph from the workflow file
at the run's head). GitHub's re-run of failed jobs re-runs it too. A
side-lane job only queued long is moved here only for a run a dispatch names
(WATCH_RUN_ID); queue_janitor.py's unclaimed-leg rule moves the rest, from the
inventory its sweep already lists: an owned leg no runner claimed for
max(45 minutes, the pool's p90 wait), at the head of an open pull request or a
live branch, gets its run cancelled and its failed jobs re-run once, where that
re-run leaves the owned label (bot_rerun_leaves_owned()). A side-lane run that is not
a pull request has no head to move, like a dispatch. cmux-next.yml exists only
on the feat-cmux-next branch; its pull request and dispatch runs upload the
owned-pool-watch marker themselves, so the sweeper adopts them like a picker's
run. Its push runs upload none (they queue each Mac job in a group per branch),
and a cmux-next push run this rescue watches anyway (a dispatch with its run
id) is never cancelled because a newer push run exists; a refused job's failed
jobs are still re-run when no newer push run covers the branch.

Nightly builds (NIGHTLY_WORKFLOW_PATH) are watched like a side lane: there is
no picker, and attempt 1 of a push or schedule run on main (or a push on
nightly-next) puts build-nightly-app on a trusted owned pool
(glaeda-trusted-<class>-xcode-<version>, TRUSTED_LABEL) together with one
runner's own label (vars.CI_NIGHTLY_TRUSTED_RUNNER or
vars.CI_NIGHTLY_NEXT_TRUSTED_RUNNER, `glaeda-runner-<name>`), while every later
attempt takes Blacksmith. That runner is reserved for the build
(reserved_runner()): a wait for it is never stuck, queued or in its setup,
because it ends when that runner finishes what it holds, and a Blacksmith
re-run of a nightly waited an hour or more (runs 39318999424, 39320477722,
39329116254, 2026-10-19). Only a refusal is acted on. Another job pinned to
that runner (main's prepare-nightly-variant legs) waits RESERVED_FOLLOWER_SECONDS
at most, then moves like a stuck job. A nightly job with no
runner label of its own gets the configured budget (CI_OWNED_POOL_RESCUE_SECONDS)
like a side lane. A refused job waits for the run to finish (the signing job is
skipped behind it) and then gets its failed jobs re-run. The run is not a pull
request, so before any re-run it checks whether its commit is superseded on its
branch (pull_moved()): a newer nightly run that waits pending behind this one in
nightly.yml's concurrency group, which a re-run would join and cancel, or a
newer push run on the branch, not cancelled, once the branch head has moved past
this run's commit. A superseded run is never re-run; the newer run builds the
newer head. A superseded run that has not finished (a refusal at the watch's
end, or a stuck job with no reserved runner) is cancelled, not re-run, so the
newer run starts; a build waiting on its reserved runner never gets that far.
On nightly-next, nightly.yml's pick-nightly-build-runner also gives a
workflow_dispatch run, and a re-run that picks again, an idle owned Mac
(nightly_build_runner.py). Neither may start a workflow_run event (a dispatch
or re-run made with GITHUB_TOKEN starts none, and the workflow_run watch takes
attempt 1 only), so that job uploads the owned-pool-watch marker and the
sweeper adopts the run at whatever attempt it is on (NIGHTLY_NEXT_EVENTS,
owned_rerun()). A refusal there gets its failed jobs re-run, and that re-run
keeps the earlier attempt's pick, so it takes Blacksmith.

A nightly's signing jobs, and the jobs that verify, image, recover or follow
them (NIGHTLY_SIGN_ALTERNATES; on main, attempt 1 only), stay on Blacksmith macOS. One queued there with no
runner past the Blacksmith stall time (simple_pool_picker's
BLACKSMITH_STALL_MINUTES) is moved by a re-run of failed jobs, whose attempt 2
takes the alternate label nightly_sign_runner.py picked on attempt 1. GitHub
re-runs jobs only in a finished run, so this cancels the run first, which a
started nightly allows only when it loses no work: every other job of the run
has finished and no runner has taken the stalled jobs (signing_stall()). While
any other job is still running or queued the rescue only logs and looks again.
It acts only when the run's own nightly.yml has the attempt-2 alternate in the
job's runs-on (sign_stall_gate()); otherwise the re-run would queue on the same
label. From attempt 2 on (through SIGN_RESCUE_LAST_ATTEMPT) a re-run of failed
jobs would read that attempt's own pick, the label that stalled, so the run is
re-run in full and its pickers choose again (signing_rerun_full()).

A job stuck with no runner is not rescued while another job of its run is
running on a persistent runner, whatever the workflow: the rescue cancels the
whole run, which would move that job to Blacksmith too (#16463). The stuck
job waits until that job ends, and if the watch ends first, it stays queued
for the mini that frees up. A refused job, or one held in setup at the
watch's end, is still acted on as described above, running siblings or not.

On a pull request run, a stuck or held job is not rescued either once
another job of its attempt has failed on its own (decided_failures(): not a
refusal, not a runner that ran no step): the run is already red, and a
re-run repeats that failure while the stuck job loses its place in the
queue. It stays queued for the minis, and a failure that was really a
Blacksmith machine fault needs a person's re-run. A refusal is still re-run.
Main, nightly and push runs keep the rescue, since a stuck one holds its
concurrency group.

A job's wait is measured from the later of its `created_at` and the first
time the watcher saw it queued, so a job record created before its `needs`
were met can never count as already past the budget.

It stops watching, doing nothing, when:
- owned pools are off (CI_PR_POOL_OWNED is not 1), before any API request;
- the run is not attempt 1 of a same-repository pull request run of ci.yml
  or a side-lane workflow, of a trusted non-PR run of a side-lane workflow, of
  main's full-suite dispatch of ci.yml, or of a dispatch in
  DISPATCH_WORKFLOW_PATHS;
- a side-lane run finished with no job on an owned label, or the fleet
  accepted all of its owned jobs;
- on a re-run of failed jobs, no job runs on an owned label once
  late-placement, if it re-ran, has finished;
- on a full re-run, `changes` and late-placement finished without that
  attempt's markers;
- `changes` finished without a marker: the run is on an ephemeral pool.
  When ci.yml started the watch for late placement (LATE_PLACEMENT=1), it
  first waits for ci-macos.yml's late-placement job and follows the run if
  that job uploaded its marker (it moved jobs onto owned root runners);
- the run finished, or the watch limit passed.

Request budget: the reads use a manaflow-glaeda-route App token when the
workflow could mint one (READ_TOKEN; its own 5000 requests an hour), else
GITHUB_TOKEN, which allows about 1000 requests an hour for the whole
repository. Cancels and re-runs always use GITHUB_TOKEN (GitHub.__doc__). A run on an ephemeral pool costs a jobs listing every
POLL_SECONDS until `changes` finishes (usually two or three) plus one artifact
listing. A run on a persistent pool adds a jobs listing every POLL_SECONDS
while one of its jobs waits for a runner and every IDLE_POLL_SECONDS otherwise,
about 30 in all for an hour-long run. A read that fails is retried
READ_ATTEMPTS times before the watch gives up; a failed cancel or re-run is
never retried.

The cmux-bot installation's 5000 requests an hour are shared with other
jobs and ran dry overnight on 2026-10-27 (48 refusals in five windows), so
GitHub.request() makes every repeated GET conditional (If-None-Match; a 304
costs nothing, and a queued run's jobs listing rarely changes between looks;
every read still asks GitHub, so no decision uses a stored answer), and paces
the reads by GET /rate_limit (free) and each answer's rate-limit headers:
below BUDGET_FLOOR left, a watch looks every IDLE_POLL_SECONDS and the sweeper skips its
side-lane failure listing; below BUDGET_RESERVE it waits for the reset
instead of spending refusals. With BOT_APP_ID and BOT_APP_KEY the script
mints a new installation token before the old one's hour is up (the 5-hour
sweeper's token expired at minute 60 and every read after it was a 401).
GitHub's ETag covers the request's Authorization header as well as the
body (2026-10-31: the same token sent as `Bearer` and as `token` got two
ETags, and either one's If-None-Match under the other was a 200), so a
stored answer is only ever confirmed for the token that read it: each
re-mint starts the stored answers afresh, and no answer is worth keeping
from one job to the next. Listings bounded by `created>=` round the bound
down (created_floor()) so the URL repeats and can answer 304; a finished
job's annotations and a finished rescue run's jobs are read once; and the
rescue history stops at its first page when GitHub's count already says it
cannot be read whole (rescue_jobs()). When the budget is spent and resets
further out than a watch may wait, a single watch (not a nightly's) ends
green with a warning instead of holding its runner through the reset
(QuotaSpent).

A CI run's owned jobs may wait on purpose. pr_runner_pool.py puts a run on
an owned pool while its jobs are expected to start there no later than on
Blacksmith, and within CI_PR_POOL_QUEUE_ROUNDS job lengths (default 1, at
most MAX_QUEUE_ROUNDS). No idle machine is held for jobs a run creates later
(its shards): they join the label's queue behind whatever arrived meanwhile,
and the picker keeps that queue within machines x (1 + rounds) by every
run's peak. So any owned job of a CI run may wait up to about that long, and
its budget is the pool's expected wait plus a margin:
CI_OWNED_POOL_RESCUE_SECONDS plus QUEUE_ROUND_SECONDS per round
(queue_seconds(), 900 seconds by default, so 990 in all), under the watch limit so a stuck
job is still moved. With the rounds at 0 the picker takes an owned pool
only with machines free now, and the budget is the configured one. A
test-ios.yml or test-e2e.yml run's picker queues by the same rounds, so it
gets the same allowance, on every attempt: a re-run of failed jobs queues on
the owned labels like attempt 1's jobs. The configured budget alone is an iOS
screenshots or side-lane run's (#14391: no picker; the side lanes share the
runners PR runs queue on, so they are moved to Blacksmith more often).
"""
from __future__ import annotations

import argparse
import base64
import dataclasses
import datetime as dt
import http.client
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pr_runner_pool import (  # noqa: E402
    MAX_QUEUE_ROUNDS, QUEUE_ROUND_MINUTES, RUNNER_LABEL_PREFIX, nightly_dedicated, parse_queue_rounds, persistent)
from delivery_workflows import is_delivery_event, is_delivery_run  # noqa: E402
import owned_pool_sources  # noqa: E402
import pr_runner_pool  # noqa: E402
import simple_pool_picker  # noqa: E402
import ui_tests_dispatch  # noqa: E402

CI_WORKFLOW_PATH = ".github/workflows/ci.yml"
E2E_WORKFLOW_PATH = ".github/workflows/test-e2e.yml"
IOS_TEST_WORKFLOW_PATH = ".github/workflows/test-ios.yml"
IOS_SCREENSHOTS_WORKFLOW_PATH = ".github/workflows/ios-screenshots.yml"
IOS_KIT_WORKFLOW_PATH = ".github/workflows/cmux-next-ios-kit.yml"
IROH_RELEASE_GATE_WORKFLOW_PATH = ".github/workflows/iroh-release-gate.yml"
# The cmux NEXT DEV publisher's `runner` job offers its secret-free verify job
# to an owned Mac free now, like iroh-release-gate.yml's.
CMUX_NEXT_DEV_DAILY_WORKFLOW_PATH = ".github/workflows/cmux-next-dev-daily.yml"
# workflow_dispatch runs watched like an E2E run: each has a `runner` job that
# picks the pool and uploads the marker.
DISPATCH_WORKFLOW_PATHS = (E2E_WORKFLOW_PATH, IOS_TEST_WORKFLOW_PATH, IOS_SCREENSHOTS_WORKFLOW_PATH,
                           IROH_RELEASE_GATE_WORKFLOW_PATH, CMUX_NEXT_DEV_DAILY_WORKFLOW_PATH, IOS_KIT_WORKFLOW_PATH)
# Workflows whose picker may queue a run's jobs on an owned pool within
# CI_PR_POOL_QUEUE_ROUNDS (ios_runner_pool.py and e2e_runner_pool.py read it
# since run 36136190497).
QUEUEING_WORKFLOW_PATHS = (CI_WORKFLOW_PATH, IOS_TEST_WORKFLOW_PATH, E2E_WORKFLOW_PATH)
# Side-lane workflows: no picker job. Their small macOS jobs take
# vars.CI_LIGHT_LANE_RUNNER or vars.CI_SIDE_LANE_RUNNER (glaeda-side-* labels)
# on attempt 1 of a trusted run, and their Blacksmith default from attempt 2 on.
# nightly.yml: no picker job either. build-nightly-app takes the trusted owned
# pool (vars.CI_SEED_TRUSTED_POOL) on attempt 1 of a push or schedule run on
# main, and Blacksmith on every later attempt.
NIGHTLY_WORKFLOW_PATH = ".github/workflows/nightly.yml"
NIGHTLY_EVENTS = frozenset({"push", "schedule"})
# nightly-next's pick-nightly-build-runner places a push or a dispatch (any attempt) on an idle owned Mac;
# a dispatch and a re-run reach the sweeper through its owned-pool-watch marker.
NIGHTLY_NEXT_EVENTS = frozenset({"push", "workflow_dispatch"})
# The trusted owned pool's labels: minis with no pull request runners, whose
# job-started hook admits only main's push and schedule jobs. Only nightly.yml's
# app build asks for one through this watch.
TRUSTED_LABEL = re.compile(r"glaeda-(?:root-)?trusted-(?:xl|std|light)-xcode-[0-9]+(?:\.[0-9]+)*")
# feat-cmux-next's session and fast roles (glaeda#1530, pr_runner_pool.OWNED_LABEL there), which main's
# picker never hands out: cmux-next-base-autofix.yml's Mac exports take glaeda-session-std-xcode-26.6.
# The freshness slot's dev role (glaeda#1628, vars.CI_DEV_COMPILE_RUNNER, glaeda-dev-std-xcode-26.6) too:
# cmux-next.yml's macos-placement puts a feed compile there, and a job there that no runner acquired
# needs the same re-run as one on any other owned label.
# The nightly slot (glaeda#1684, runner.nightlySlot, glaeda-nightly-std-xcode-26.6) too: one runner per mini
# that takes only nightly jobs, which nightly-next's build picker offers first (vars.CI_NIGHTLY_NEXT_BUILD_RUNNER).
LANE_LABEL = pr_runner_pool.LANE_LABEL
# The freshness slot's own labels, a subset of LANE_LABEL: a job that started there is a DEV feed compile,
# which nothing automatic cancels (started_dev_compile()).
DEV_LABEL = re.compile(r"glaeda-(?:aws-)?dev-(?:xl|std|light)-xcode-[0-9]+(?:\.[0-9]+)*")
# Every other workflow that can put a job on an owned pool, on main or on
# feat-cmux-next (whose files are not in main's tree): owned_pool_sources.py
# finds them from their jobs' runs-on, and tests/test_ci_owned_pool_sources.py
# fails when a workflow it finds is missing here, or one here is found in
# neither branch. Most take a glaeda-side-* label on attempt 1 of a trusted
# run and Blacksmith later; some (the base and PR autofix's Mac exports) take
# a session or gui label on every attempt. None uploads a marker, so the
# sweeper finds their failed runs by path (GitHub.failed_runs()); cmux-next.yml
# is marked as well.
SIDE_WORKFLOW_PATHS = frozenset({
    ".github/workflows/agent-brands.yml",  # feat-cmux-next only
    ".github/workflows/app-host-test-rerun.yml",
    ".github/workflows/auth-refresh-tests.yml",
    ".github/workflows/cloud-command-deadlines.yml",
    ".github/workflows/cloud-machine-tests.yml",
    ".github/workflows/cloud-task-local-tests.yml",
    ".github/workflows/cmux-next-base-autofix.yml",  # feat-cmux-next only
    ".github/workflows/cmux-next-batch.yml",  # feat-cmux-next only
    ".github/workflows/cmux-next-frame-pacing.yml",  # feat-cmux-next only
    ".github/workflows/cmux-next-media.yml",  # feat-cmux-next only
    ".github/workflows/cmux-next-pr-autofix.yml",  # feat-cmux-next only
    ".github/workflows/cmux-next-terminal.yml",  # feat-cmux-next only
    # feat-cmux-next only; uploads the owned-pool-watch marker on attempt 1.
    ".github/workflows/cmux-next.yml",
    # feat-cmux-next only; its portable placement (portable_job_placement.py) puts the guard group,
    # tooling tests and release-notary guards on the side label only while a side runner is idle.
    ".github/workflows/cmux-next-guards.yml",
    ".github/workflows/cmux-tui-artifacts.yml",
    ".github/workflows/cmux-tui.yml",
    ".github/workflows/iroh-v2.yml",
    # The post-publication canary's Mac job takes the side label on attempt 1.
    ".github/workflows/nightly-next-canary.yml",
    # The post-publish launch smoke's Mac job takes the side label on attempt 1.
    ".github/workflows/nightly-next-launch-smoke.yml",
    ".github/workflows/relay-tls.yml",
    ".github/workflows/reload-build.yml",
    ".github/workflows/remote-daemon.yml",
    ".github/workflows/terminal-hang-diagnostics.yml",
    ".github/workflows/test-feed-reply-providers.yml",  # feat-cmux-next only
})
# Side workflows whose Mac jobs take a session or gui label on every attempt (feat-cmux-next only), so no
# re-run moves them off the minis (bot_rerun_leaves_owned()).
OWNED_EVERY_ATTEMPT_PATHS = frozenset({
    ".github/workflows/cmux-next-base-autofix.yml",
    ".github/workflows/cmux-next-pr-autofix.yml",
})
# cmux-next is the side lane whose placement and retry route are minis-first;
# other side workflows keep their existing fallback policy.
CMUX_NEXT_WORKFLOW_PATH = ".github/workflows/cmux-next.yml"
# Events whose code is this repository's own: a push or schedule runs a branch
# of it, and a workflow_dispatch needs write access. A side-lane run of one of
# these is owned-eligible like a same-repository pull request. merge_group,
# workflow_run and pull_request_target are not: they can carry fork code.
TRUSTED_SIDE_EVENTS = frozenset({"push", "schedule", "workflow_dispatch"})
# Workflows that can take an owned pool but are never rescued here, each with why. A person decides
# their re-runs. owned_pool_sources.py must find no owned workflow outside these and
# WATCHED_WORKFLOW_PATHS (tests/test_ci_owned_pool_sources.py).
UNRESCUED_WORKFLOW_PATHS = {
    ".github/workflows/stable-next.yml":
        "feat-cmux-next only (main keeps its tick); the nightly cmux NEXT Stable run. Its owned jobs take the gui pool or "
        "the gateway on attempt 1 and Blacksmith on a re-run; main's tick cancels a run still queued after 90 minutes and "
        "starts a fresh one, so a stuck job is moved without the rescue",
    ".github/workflows/release.yml":
        "the release signing job takes a drained owned Mac only on attempt 1 while vars.CI_SIGN_OWNED is 1 "
        "(pick-sign-runner, scripts/ci/signing_runner.py); glaeda refuses it within 300 s if the mini does not "
        "drain, and a person's re-run takes the Blacksmith alternate: a release step, so a person re-runs it",
    ".github/workflows/repair-v0-64-25-helper-rpaths.yml":
        "a manual repair that signs a release; like release.yml it takes a drained owned Mac only on attempt 1 "
        "while vars.CI_SIGN_OWNED is 1, and a person's re-run takes the Blacksmith alternate",
    ".github/workflows/app-ffi-release.yml":
        "feat-cmux-next only; builds and publishes the FFI xcframework every app build links on the trusted "
        "promote mini: a release step, so a person re-runs it",
    ".github/workflows/cmux-tui-nightly.yml":
        "feat-cmux-next only; builds (on a side label it passes cmux-tui-build-package.yml) and publishes the "
        "cmux-tui nightly packages: a release step, so a person re-runs it",
    ".github/workflows/ios-internal-nightly.yml":
        "feat-cmux-next only; signs and uploads the internal iOS build: a release step, so a person re-runs it",
    ".github/workflows/nightly-next-train.yml":
        "the train's candidate Release compile takes an owned Mac only while one is idle (pick-train-runner); "
        "the train's own drive (nightly_next_train_drive.py) re-runs a compile an owned Mac refused, and that "
        "re-run takes Blacksmith",
    ".github/workflows/main-compile-probe.yml":
        "one optional compile data point for main's compile attribution; its dispatcher already sends a probe "
        "that has not started to Blacksmith, and nothing waits on it",
    ".github/workflows/seed-derived-data.yml":
        "a cache seed on the trusted pool that nothing waits on; the next main push seeds again from the newest "
        "earlier seed",
}
# Every workflow this rescue acts on (target_from_event()); owned_pool_sources.py
# must find no owned workflow outside it and UNRESCUED_WORKFLOW_PATHS.
WATCHED_WORKFLOW_PATHS = frozenset({CI_WORKFLOW_PATH, NIGHTLY_WORKFLOW_PATH, *DISPATCH_WORKFLOW_PATHS,
                                    *SIDE_WORKFLOW_PATHS})
# test-e2e.yml's job that runs e2e_runner_pool.py (and the iOS workflows' job
# that runs ios_runner_pool.py).
E2E_PICKER_JOB = "runner"
# ci.yml's job that runs the pool picker; its jobs-API name (no `name:` override).
PICKER_JOB = "changes"
DEFAULT_BUDGET_SECONDS = 90
# Side lanes deliberately queue on the owned label while minis drain. Their
# overflow is a measured queue decision, not the 90-second CI rescue budget.
SIDE_DEFAULT_BUDGET_SECONDS = 600
MIN_BUDGET_SECONDS = 30
MAX_BUDGET_SECONDS = 600
# A job's budget ends this long before the watch does (job_budget()): two
# looks, so the rescue fires while the watch still runs.
END_MARGIN_SECONDS = 60
# One round of queue on an owned pool: the longest job a queued job commonly
# waits behind, compile admission. Over 80 pull request runs on 2026-09-25 it
# took a median 638 s on the minis (p90 745 s) and a p90 893 s on Blacksmith.
QUEUE_ROUND_SECONDS = QUEUE_ROUND_MINUTES * 60
FIRST_LOOK_SECONDS = 45
POLL_SECONDS = 20
IDLE_POLL_SECONDS = 120
# Long enough for a compile-only pull request run and its consumers to queue.
WATCH_LIMIT_SECONDS = 60 * 60
# An E2E test job queues after a sibling wait (up to 35 min) and a build.
E2E_WATCH_LIMIT_SECONDS = 150 * 60
# A side lane's macOS job is created at once, or after a Linux gate
# (cloud-machine-tests), which can wait in a busy Linux queue; a watch that
# ended before the job existed would leave it on the fleet unwatched.
SIDE_WATCH_LIMIT_SECONDS = WATCH_LIMIT_SECONDS
# A nightly's owned jobs run one after another: the app build (about 20 min
# on a mini, longer cold), then prepare-nightly-variant (up to 40 min).
NIGHTLY_WATCH_LIMIT_SECONDS = E2E_WATCH_LIMIT_SECONDS
READ_ATTEMPTS = 3
READ_RETRY_SECONDS = 10
MARKER_PREFIX = "macos-pool-persistent"
# ci-macos.yml's late-placement moved jobs after compile admission onto idle
# owned root runners (late_placement.py), and started this watch itself.
LATE_MARKER_PREFIX = "macos-pool-late"
LATE_JOB = "macos / late-placement"
# Compile admission: when a re-run of failed jobs runs it again, late-placement runs again after it.
ADMISSION_JOB = "macos / macOS compile admission"
# A cancelled run is only useful re-run: giving up leaves the pull request's
# run cancelled for good. A Mac job mid-compile has taken over 5 minutes to
# settle after a force-cancel (run 36074561333, 2026-09-24), so wait long, and
# force-cancel again while waiting.
CANCEL_WAIT_SECONDS = 20 * 60
FORCE_CANCEL_AFTER_SECONDS = 90
FORCE_CANCEL_AGAIN_SECONDS = 5 * 60
# Room for one watch's waits through GitHub rate limits (RATE_LIMIT_WAIT_SECONDS).
_RATE_LIMIT_ROOM_SECONDS = 15 * 60
# A rescue may run this long past the watch's end, so a refusal found late
# in the watch still gets its cancel settled and its re-run, rate-limit waits
# included (a sweeper's handover joins its rescues for this long).
RESCUE_GRACE_SECONDS = 25 * 60 + _RATE_LIMIT_ROOM_SECONDS
# Kept back from the job timeout for checkout and the summary.
JOB_TIMEOUT_MARGIN_SECONDS = 5 * 60
# ci-owned-pool-rescue.yml's timeout-minutes: the longest watch (an E2E
# run's), its rescue grace, and the margin.
JOB_TIMEOUT_SECONDS = E2E_WATCH_LIMIT_SECONDS + RESCUE_GRACE_SECONDS + JOB_TIMEOUT_MARGIN_SECONDS
# Time kept back after a cancel settles, for the re-run request itself.
RERUN_MARGIN_SECONDS = 60
# A refused job fails within the runner's setup; a real failure of the first
# step after checkout takes longer than this, and one that does not is cheap to
# retry. glaeda's hook once waited up to 240 s inside that setup for the mini's
# capacity before refusing; it now waits with no limit (SETUP_WAIT_SECONDS
# covers that), so a refusal is the hook's other checks, which answer at once,
# or one at the end of that wait, which hook_refused() catches by its step.
REFUSAL_SECONDS = 360
# The last attempt of the bot's own re-runs that may run on an owned pool
# (pr_runner_pool.LAST_OWNED_ATTEMPT): attempt 2 is placed like attempt 1. A
# person's re-run of a pull request (a code failure:
# pr_runner_pool.host_fault_retry()) goes back to the minis on any attempt and
# is watched whatever its attempt (owned_rerun()); the rescue's re-run of it is
# the bot's, on Blacksmith.
LAST_OWNED_ATTEMPT = 2
# cmux-next's bot attempt 3 keeps macos-placement's mini label (a re-run reuses
# attempt 1's outputs), so a lend drain can refuse it too, and before 2026-10-07
# nothing re-ran it (#18147's scheme compile, 02:23Z). It is watched for
# refusals only: when every failed job of it was refused, its failed jobs are
# re-run as attempt 4, which cmux-next.yml sends to Blacksmith. Minis-first
# still holds for attempts 1 to 3, and no attempt past 3 is watched.
REFUSAL_RESCUE_ATTEMPT = LAST_OWNED_ATTEMPT + 1
# The bot's re-runs: the workflow token's, and cmux-bot's since ci-owned-pool-rescue.yml mints that App's
# token for its mutations. A re-run by anyone else is a person's (owned_rerun()). Run 40444295785, a DEV
# daily, went through 10 cmux-bot attempts on the minis while only github-actions[bot] counted here.
RESCUE_ACTORS = frozenset({"github-actions[bot]", "cmux-bot[bot]"})
# ci.yml's placement (pr_runner_pool.RESCUE_ACTOR, ci-macos.yml's pr_retry_runner) still moves only
# github-actions[bot]'s attempt 3 off the minis, so a cmux-bot re-run of CI stays a person's here: it
# goes back to the minis and is watched.
CI_RESCUE_ACTOR = "github-actions[bot]"
# Why a pull request's run at its open head is left alone (queue_janitor.py shares it).
OPEN_HEAD_RULE = ("never cancelled: an open pull request's run at its head is never cancelled by anything "
                  "automatic; the controller's fall-through moves its compile instead")
# The stall-aware failover's queue floor at an open head (unstarted_failover()): Leo's "about 3 minutes".
UNSTARTED_STALL_SECONDS = 180
# The log line that names an open-head run the failover cancels and re-runs (unstarted_failover()).
OPEN_HEAD_FAILOVER = "open-head failover"


def owned_rerun(run: Mapping[str, Any]) -> bool:
    """A re-run of a CI run whose owned jobs go back to the minis, so it is watched like attempt 1: attempt 2,
    or a later one of a pull request someone other than the bot (CI_RESCUE_ACTOR; cmux-next: RESCUE_ACTORS) started."""
    attempt = int(run.get("run_attempt") or 0)
    if attempt <= 1:
        return False
    if run.get("path") == NIGHTLY_WORKFLOW_PATH:
        # nightly-next's picker places any attempt that runs it again (a person's full re-run, or the rescue's
        # re-run of the picker: rerun_failed_or_repick()) on an owned Mac and marks it; a re-run of failed jobs
        # keeps the earlier pick and takes Blacksmith, so its watch ends at its first look. The sweeper adopts it
        # only by that marker.
        return run.get("head_branch") == "nightly-next"
    actor = str((run.get("triggering_actor") or {}).get("login") or "")
    if run.get("path") == CMUX_NEXT_WORKFLOW_PATH:
        # Manual side-lane reruns stay minis-first at any attempt. The bot's
        # second attempt is still watched so a second long queue can overflow
        # on attempt three; bot attempt three is watched for refusals only.
        return actor not in RESCUE_ACTORS or attempt <= REFUSAL_RESCUE_ATTEMPT
    return run.get("path") == CI_WORKFLOW_PATH and (attempt <= LAST_OWNED_ATTEMPT or (
        run.get("event") == "pull_request" and actor != CI_RESCUE_ACTOR))
# The runner's own steps, which run before glaeda's hook decides.
SETUP_STEPS = frozenset({"Set up job", "Set up runner"})
# The step glaeda's job-started hook runs in. No workflow code runs there, so its
# failure is the runner's whatever its length (hook_refused()).
HOOK_STEP = "Set up runner"
XCODE_SELECTION_STEPS = frozenset({"Select Xcode", "Select helper Xcode"})
# glaeda's hook no longer refuses a job for the mini's capacity: it waits,
# with no limit, inside the runner's setup ("Set up runner") until the units
# and tokens it needs are free (glaeda CAPACITY_WAIT, 2026-09-28). A job still
# there this long after it started is stuck like a queued one and is moved the
# same way (Look "rescue"). A compile waiting for a canonical root normally
# waits for one running compile, about 7 minutes.
SETUP_WAIT_SECONDS = 15 * 60
MAX_JOB_PAGES = 3
# Main's full-suite dispatch (ci-main-full-suite.yml) runs ci.yml on this branch.
MAIN_BRANCH = "main"
API = "https://api.github.com"


def budget(value: str | None) -> int | None:
    """The queued-seconds budget from the variable, or None when it is invalid."""
    raw = (value or "").strip()
    if not raw:
        return DEFAULT_BUDGET_SECONDS
    try:
        seconds = int(raw)
    except ValueError:
        return None
    return seconds if MIN_BUDGET_SECONDS <= seconds <= MAX_BUDGET_SECONDS else None


def side_budget(value: str | None) -> int | None:
    """The side-lane queue budget, defaulting to ten minutes."""
    if not (value or "").strip():
        return SIDE_DEFAULT_BUDGET_SECONDS
    return budget(value)


def queue_seconds(rounds: str | None) -> int:
    """How long a CI run's owned job may wait on purpose: the pool's expected wait bound (CI_PR_POOL_QUEUE_ROUNDS).

    An invalid value makes the picker keep every run off the owned pools, so
    it adds nothing.
    """
    # parse_queue_rounds() clamps to MAX_QUEUE_ROUNDS, so the longest budget
    # (MAX_BUDGET_SECONDS + 2,700 s) stays under WATCH_LIMIT_SECONDS.
    return min(parse_queue_rounds(rounds) or 0, MAX_QUEUE_ROUNDS) * QUEUE_ROUND_SECONDS


def parse_time(value: object) -> dt.datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def nightly_control_label(label: object) -> bool:
    """Whether a nightly decide label is a configured fleet control runner."""
    value = str(label or "")
    return bool(value) and not value.startswith(("blacksmith-", "ubuntu-", "macos-", "windows-"))


def job_pool(job: Mapping[str, Any]) -> str | None:
    """The owned pool a job asked for, if any: a pull request pool or the trusted one."""
    for label in job.get("labels") or []:
        if (persistent(str(label)) or TRUSTED_LABEL.fullmatch(str(label)) or LANE_LABEL.fullmatch(str(label))
                or job.get("name") == "decide" and nightly_control_label(label)
                or nightly_dedicated(str(label))):
            return str(label)
    return None


# The nightly jobs whose wait for their reserved runner is never timed: the app build, which that runner is kept
# for. Any other job pinned to it (main's prepare-nightly-variant legs, #26494, which take the trusted mini right
# after its build when the picker saw it idle) moves after RESERVED_FOLLOWER_SECONDS: main's push nightlies run
# in parallel, so a newer push's build can take the mini between the pick and the legs, and they would wait
# behind a whole build. The re-run of failed jobs takes the job's Blacksmith fallback.
RESERVED_UNTIMED_JOBS = frozenset({"build-nightly-app"})
RESERVED_FOLLOWER_SECONDS = 5 * 60  # the queue alarm (QUEUE_ALARM_SECONDS)


def reserved_follower(job: Mapping[str, Any]) -> bool:
    """A job pinned to a reserved runner that is not the build kept for it (RESERVED_UNTIMED_JOBS)."""
    name = str(job.get("name") or "")
    return not any(name == build or name.startswith(build + " (") for build in RESERVED_UNTIMED_JOBS)


def app_built(jobs: Sequence[Mapping[str, Any]]) -> bool:
    """Whether the run's app build (RESERVED_UNTIMED_JOBS) succeeded on this attempt's job list."""
    return any(not reserved_follower(job) and job.get("status") == "completed" and job.get("conclusion") == "success"
               for job in jobs)


def reserved_runner(job: Mapping[str, Any]) -> str | None:
    """The one runner a job asked for by its own label (`glaeda-runner-<name>`), if any.

    Only honoured for a nightly build (assess(reserved=True)): nightly.yml names the runner kept for it
    (vars.CI_NIGHTLY_TRUSTED_RUNNER, vars.CI_NIGHTLY_NEXT_TRUSTED_RUNNER) beside the trusted pool, so the
    wait ends when that runner finishes what it holds. A pull request's compile admission also names a warm
    runner, but only as a preference the rescue may override (pr_runner_pool.py's warm affinity).
    """
    for label in job.get("labels") or []:
        if str(label).startswith(RUNNER_LABEL_PREFIX):
            return str(label)
    return None


def started_dev_compile(jobs: Sequence[Mapping[str, Any]]) -> str | None:
    """The freshness-slot label of a job a runner has taken, if any: a started DEV feed compile.

    The watch reads jobs before rescue() cancels, so a compile queued on the slot can start in between;
    a started dev build is never cancelled, so rescue() reads the jobs again right before its cancel.
    """
    for job in jobs:
        if job.get("status") == "queued" and not job.get("runner_name"):
            continue
        if job.get("status") == "completed":
            continue
        for label in job.get("labels") or []:
            if DEV_LABEL.fullmatch(str(label)):
                return str(label)
    return None


# nightly.yml's Blacksmith macOS sign, verify and DMG jobs, on both branches: the signing jobs, which hold the
# release keys, and the jobs that verify, image, recover or follow them. On 2026-10-27 build-sign-notarize-nightly
# and sign-nightly-identity-legacy sat 16 minutes (10:58 to 11:14Z) on a starved blacksmith-6vcpu-macos-26 in run
# 40489472569. From attempt 2 on, each job's runs-on reads `github.run_attempt > 1 && needs.<job>.outputs.<name>`:
# an alternate macOS 26 label the sign picker chose on attempt 1 (nightly_sign_runner.py on nightly-next, #26171;
# classic_nightly_build_runner.py on main, whose expression also checks the pick's own attempt), which a re-run of
# failed jobs keeps. Each job maps to its jobs-API name (a matrix leg adds ` (arm64)`) and the expressions that
# give it that label. The rescue acts on a job only when the run's own nightly.yml has one of them in the job's
# runs-on (sign_stall_gate()); without it a re-run would queue on the same stalled label, so the job is left alone.
# nightly-next's signer-dmg-image and signer-verify were missing until 2026-10-28: run 40585960129's signer-verify
# sat queued on blacksmith-6vcpu-macos-26 for over an hour, and as a job outside this table it counted as
# unfinished work, so the run's stalled final-DMG verify was never moved either.
# tests/test_ci_owned_pool_sources.py derives the jobs that need an entry from both branches' nightly.yml
# (owned_pool_sources.uncovered_sign_jobs()).
_SIGN_ALTERNATE = "github.run_attempt > 1 && needs.pick-nightly-sign-runner.outputs.alternate"
_CLASSIC_SIGN_ALTERNATE = ("github.run_attempt > 1 && needs.pick-classic-sign-runner.outputs.attempt != "
                           "github.run_attempt && needs.pick-classic-sign-runner.outputs.alternate")
_RECOVERY_ALTERNATE = "github.run_attempt > 1 && needs.find-nightly-next-recovery.outputs.sign_alternate"
_LEGACY_ALTERNATE = "github.run_attempt > 1 && needs.legacy-identity-target.outputs.sign_alternate"
NIGHTLY_SIGN_ALTERNATES: dict[str, tuple[str, tuple[str, ...]]] = {
    "build-sign-notarize-nightly": ("build-sign-notarize-nightly", (_SIGN_ALTERNATE, _CLASSIC_SIGN_ALTERNATE)),
    "verify-signed-nightly": ("Verify signed nightly app", (_SIGN_ALTERNATE, _CLASSIC_SIGN_ALTERNATE)),
    "verify-final-dmg-nightly": ("Verify final nightly DMG", (_SIGN_ALTERNATE,)),
    "signer-dmg-image": ("signer-dmg-image", (_SIGN_ALTERNATE,)),
    "signer-verify": ("signer-verify", (_SIGN_ALTERNATE,)),
    "generate-nightly-deltas": ("generate-nightly-deltas", (_SIGN_ALTERNATE, _CLASSIC_SIGN_ALTERNATE)),
    "recover-nightly-next-notarization": ("recover-nightly-next-notarization", (_RECOVERY_ALTERNATE,)),
    "verify-recovered-nightly-next": ("verify-recovered-nightly-next", (_RECOVERY_ALTERNATE,)),
    "sign-nightly-identity-legacy": ("sign-nightly-identity-legacy", (_LEGACY_ALTERNATE,)),
    # feat-cmux-next's same-run Blacksmith signer for a refused owned-Mac attempt (#27357). It runs on attempt 1
    # only: a rescue re-run skips it and re-runs the failed sign-nightly-identity-legacy on its alternate label.
    "sign-nightly-identity-legacy-blacksmith": ("sign-nightly-identity-legacy-blacksmith", (_LEGACY_ALTERNATE,)),
    "verify-nightly-identity-legacy": ("verify-nightly-identity-legacy", (_LEGACY_ALTERNATE,)),
}
SIGN_BLACKSMITH_LABEL = re.compile(r"blacksmith-[0-9]+vcpu-macos-[0-9]+(?:-[a-z0-9]+)*")
# simple_pool_picker.blacksmith_stalled()'s rule: a Blacksmith job with no runner this long is on a stalled label.
SIGN_STALL_SECONDS = simple_pool_picker.BLACKSMITH_STALL_MINUTES * 60
# The last attempt whose stalled signing jobs are rescued. Attempt 1 re-runs its failed jobs: attempt 2 reads the
# `alternate` its pickers wrote. From attempt 2 on a re-run of failed jobs would read that attempt's own outputs,
# the very label that stalled (run 40500413442, 2026-10-27: attempt 2's legacy sign queued on
# blacksmith-12vcpu-macos-26 from 13:01Z, its verify jobs from 15:15Z), so the run is re-run in full: the pickers
# run again and choose afresh, never a size their snapshot sees stalled (nightly_sign_runner.py, #26239). A full
# re-run builds the app again, so it stops here.
SIGN_RESCUE_LAST_ATTEMPT = 3


def signing_rerun_full(attempt: int) -> bool:
    """Whether a signing-stall rescue of `attempt` re-runs the whole run (the pickers choose again) rather than its
    failed jobs (which take the alternate attempt 1's pickers wrote)."""
    return attempt > 1


def sign_job_key(job: Mapping[str, Any]) -> str | None:
    """The NIGHTLY_SIGN_ALTERNATES job a jobs-API job is, if any."""
    name = str(job.get("name") or "")
    return next((key for key, (shown, _) in NIGHTLY_SIGN_ALTERNATES.items()
                 if name == shown or name.startswith(shown + " (")), None)


def signing_stall(jobs: Sequence[Mapping[str, Any]], now: dt.datetime,
                  first_seen: Mapping[Any, dt.datetime] | None = None) -> Look | None:
    """nightly-next's signing jobs (NIGHTLY_SIGN_ALTERNATES) queued on Blacksmith macOS past SIGN_STALL_SECONDS
    with no runner, or None.

    GitHub re-runs jobs only in a finished run, so moving a queued job means cancelling the run first,
    and a started nightly is never cancelled for a slow runner. A cancel here loses no work only when
    every other job of the run has finished: then the run holds nothing but the stalled jobs, which no
    runner has taken. So Look "stalled" (cancel, then re-run failed jobs, so only those jobs run again)
    needs both. Anything else still in progress or queued (the other signing job included, until it
    stalls too) gives Look "watch": the next look decides again.
    """
    seen = first_seen or {}
    stalled = [job for job in jobs if sign_job_key(job) and waiting_for_runner(job)
               and any(SIGN_BLACKSMITH_LABEL.fullmatch(str(label)) for label in job.get("labels") or [])
               and queued_seconds(job, now, seen.get(job.get("id"))) >= SIGN_STALL_SECONDS]
    if not stalled:
        return None
    names = ", ".join(sorted(str(job.get("name") or job.get("id")) for job in stalled))
    label = next(str(label) for label in stalled[0].get("labels") or [] if SIGN_BLACKSMITH_LABEL.fullmatch(str(label)))
    busy = sorted(str(job.get("name") or job.get("id")) for job in jobs
                  if job.get("status") != "completed" and not any(job is other for other in stalled))
    if busy:
        return Look("watch", f"{names} queued on {label} with no runner past the {SIGN_STALL_SECONDS}s Blacksmith "
                             f"stall time, but {', '.join(busy)} not finished; cancelling the run would lose that "
                             "work, so it is not rescued on this look", waiting=True)
    return Look("stalled", f"{names} queued on {label} with no runner past the {SIGN_STALL_SECONDS}s Blacksmith "
                           "stall time, and every other job of the run has finished")


def gated_signing_stall(jobs: Sequence[Mapping[str, Any]], now: dt.datetime, first_seen: Mapping[Any, dt.datetime],
                        workflow_text: str | None) -> Look | None:
    """signing_stall(), with Look "stalled" turned into "watch" unless the runs-on in `workflow_text` of every
    covered job of the run takes its alternate label on a re-run (sign_stall_gate())."""
    stall = signing_stall(jobs, now, first_seen)
    if stall is None or stall.action != "stalled":
        return stall
    # Every covered job of the run, finished or not: a re-run of failed jobs also re-runs a signing job that
    # failed or was cancelled, and that one must take its alternate label too.
    keys = sorted({key for job in jobs for key in [sign_job_key(job)] if key})
    missing = sign_stall_gate(workflow_text, keys)
    if missing:
        return Look("watch", f"{stall.reason}, but the runs-on of {', '.join(missing)} at the run's head takes no "
                             "alternate label on a re-run, so a re-run would queue on the same label; not rescued",
                    waiting=True)
    return stall


def sign_stall_gate(workflow_text: str | None, keys: Sequence[str]) -> list[str]:
    """The jobs among `keys` whose runs-on in `workflow_text` lacks every attempt-2 alternate label expression
    NIGHTLY_SIGN_ALTERNATES gives them. Fails closed: a missing or unreadable file, or a missing job, counts."""
    if not workflow_text:
        return sorted(keys)
    try:
        spec = owned_pool_sources._load(workflow_text).get("jobs") or {}
    except Exception:  # noqa: BLE001 - an unparseable file, or no PyYAML, takes no re-run
        return sorted(keys)
    missing = []
    for key in keys:
        runs_on = str((spec.get(key) or {}).get("runs-on") or "") if isinstance(spec.get(key), Mapping) else ""
        if not any(expression in runs_on for expression in NIGHTLY_SIGN_ALTERNATES[key][1]):
            missing.append(key)
    return sorted(missing)


def waiting_for_runner(job: Mapping[str, Any]) -> bool:
    return job.get("status") == "queued" and not job.get("runner_name")


def in_setup(job: Mapping[str, Any]) -> bool:
    """A job its runner took that is still in the runner's setup, where glaeda's hook waits for capacity."""
    if job.get("status") != "in_progress":
        return False
    steps = [step for step in job.get("steps") or [] if isinstance(step, Mapping)]
    return any(step.get("name") in SETUP_STEPS and step.get("status") == "in_progress" for step in steps)


def setup_seconds(job: Mapping[str, Any], now: dt.datetime) -> float:
    """How long the job has been in its current setup step (glaeda's hook runs in "Set up runner")."""
    steps = [step for step in job.get("steps") or [] if isinstance(step, Mapping)]
    step = next((step for step in steps if step.get("name") in SETUP_STEPS and step.get("status") == "in_progress"),
                None)
    started = parse_time((step or {}).get("started_at")) or parse_time(job.get("started_at"))
    return 0.0 if started is None else max(0.0, (now - started).total_seconds())


def wait_start(job: Mapping[str, Any], first_seen: dt.datetime | None = None) -> dt.datetime | None:
    created = parse_time(job.get("created_at"))
    return max(filter(None, (created, first_seen)), default=None)


def queued_seconds(job: Mapping[str, Any], now: dt.datetime, first_seen: dt.datetime | None = None) -> float:
    since = wait_start(job, first_seen)
    return 0.0 if since is None else max(0.0, (now - since).total_seconds())


def job_budget(job: Mapping[str, Any], budget_seconds: int, *, deadline: dt.datetime | None,
               floor_seconds: int | None, first_seen: dt.datetime | None = None) -> int:
    """A job's budget, cut so a job queued late is still judged before the watch ends.

    A CI run's budget includes the owned wait it may expect (queue_seconds()),
    and its shards appear about 11 minutes in; at 3 rounds a shard that got
    stuck would otherwise outlast the watch and never be moved. So a job
    waiting since `since` is rescued after at most deadline - since -
    END_MARGIN_SECONDS, and never before `floor_seconds` (the configured
    CI_OWNED_POOL_RESCUE_SECONDS).
    """
    since = wait_start(job, first_seen)
    if deadline is None or since is None:
        return budget_seconds
    left = int((deadline - since).total_seconds()) - END_MARGIN_SECONDS
    floor = budget_seconds if floor_seconds is None else min(floor_seconds, budget_seconds)
    return max(floor, min(budget_seconds, left))


# Workflows whose owned jobs timing out are re-run (feed_timeouts()): they build a feed, which a started
# build must not be left cancelled for (the rulebook: never for a slow runner).
FEED_TIMEOUT_PATHS = frozenset({CMUX_NEXT_DEV_DAILY_WORKFLOW_PATH, NIGHTLY_WORKFLOW_PATH})
# GitHub's default job timeout-minutes.
DEFAULT_TIMEOUT_MINUTES = 360
# GitHub cancels a timed-out job within seconds of its limit; a job cancelled this much short of it was not timed out.
TIMEOUT_SLACK_SECONDS = 30


def timed_out(workflow_text: str, jobs: Sequence[Mapping[str, Any]],
              attempt_started: dt.datetime | None = None) -> list[str]:
    """Names of this attempt's owned jobs GitHub timed out: on a runner, with steps, concluded `cancelled`
    (what GitHub records for a job past its timeout-minutes), and lasting at least that limit. A job's
    timeout-minutes comes from the workflow file at the run's head, matched by its rendered name; a name
    matching no job, or one whose limit is an expression, never counts. A run someone cancelled ends its jobs
    short of their limits, so they never count."""
    document = owned_pool_sources._load(workflow_text)
    spec = {str(key): job for key, job in (document.get("jobs") or {}).items() if isinstance(job, Mapping)}
    patterns = {key: _job_name_pattern(key, job) for key, job in spec.items()}
    found: list[str] = []
    for job in jobs:
        if not (job_pool(job) and job.get("status") == "completed" and job.get("conclusion") == "cancelled"
                and job.get("runner_name") and job.get("steps") and not carried(job, attempt_started)):
            continue
        keys = [key for key, pattern in patterns.items() if pattern.fullmatch(str(job.get("name") or ""))]
        limits = [spec[key].get("timeout-minutes", DEFAULT_TIMEOUT_MINUTES) for key in keys]
        if not limits or not all(isinstance(limit, (int, float)) and not isinstance(limit, bool) for limit in limits):
            continue
        started, completed = parse_time(job.get("started_at")), parse_time(job.get("completed_at"))
        if started is None or completed is None:
            continue
        if (completed - started).total_seconds() >= min(limits) * 60 - TIMEOUT_SLACK_SECONDS:
            found.append(str(job.get("name") or job.get("id")))
    return sorted(found)


def feed_timeouts(api: "GitHub", target: "Target", jobs: Sequence[Mapping[str, Any]],
                  sleep: Callable[[float], None], log: Callable[[str], None]) -> list[str]:
    """timed_out() for a finished DEV daily or nightly run (FEED_TIMEOUT_PATHS), else []. Reads the workflow
    file only when an owned job of the run was cancelled on a runner."""
    if target.path not in FEED_TIMEOUT_PATHS or not any(
            job_pool(job) and job.get("conclusion") == "cancelled" and job.get("runner_name") for job in jobs):
        return []
    try:
        text = read(lambda: api.workflow_file(target.path, target.head_sha), sleep, log)
        if not text:
            log(f"{target.path} is not at {target.head_sha[:12]}; no cancelled job is put down to a timeout")
            return []
        return timed_out(text, jobs, target.attempt_started_at)
    except Aborted:
        raise
    except Exception as error:  # noqa: BLE001 - an unreadable file, or no PyYAML, only counts no timeout
        log(f"could not read {target.path}'s timeouts at {target.head_sha[:12]} ({type(error).__name__}: "
            f"{error}); no cancelled job is put down to a timeout")
        return []


def refused(job: Mapping[str, Any]) -> bool:
    """An owned runner's setup or Xcode pin failure, or a lost runner."""
    if not job_pool(job) or job.get("status") != "completed" or job.get("conclusion") != "failure":
        return False
    steps = [step for step in job.get("steps") or [] if isinstance(step, Mapping)]
    if not steps:
        # The runner ran nothing, not even "Set up job": GitHub failed a job whose
        # runner went away ("The self-hosted runner lost communication with the
        # server"), which it reports only after 10 minutes, so no length applies
        # (run 36420353579).
        return True
    if any(step.get("conclusion") == "cancelled" for step in steps) and \
            not any(step.get("conclusion") == "failure" for step in steps):
        # The runner was stopped mid-job ("The runner has received a shutdown signal",
        # then "The operation was canceled."): the step it was in is cancelled while the
        # job fails, whatever its length. Job 121926149188 (run 40424205219, PR #25241) and
        # four other open pull requests' cmux-next jobs failed so at 01:19Z on 2026-10-27,
        # in glaeda's hook and in "Run the fast tier". A failing step concludes failure, a
        # step's timeout-minutes too ("The action has timed out."), and a cancelled or
        # timed-out job concludes cancelled, so only a stopped runner leaves this. A step
        # that failed before the stop (tests, then a cleanup cut short) keeps the job the code's.
        return True
    # A helper build can precede Xcode selection, so neither elapsed time nor
    # earlier successful steps make a missing pin a source failure.
    if any(step.get("name") in XCODE_SELECTION_STEPS and step.get("conclusion") == "failure"
           for step in steps):
        return True
    if hook_refused(steps):
        return True
    started, completed = parse_time(job.get("started_at")), parse_time(job.get("completed_at"))
    if started is None or completed is None or (completed - started).total_seconds() > REFUSAL_SECONDS:
        return False
    # The hook runs inside the runner's own setup, so a failed setup step is a
    # refusal even when the job's `always()` steps still ran and succeeded.
    if any(step.get("name") in SETUP_STEPS and step.get("conclusion") == "failure" for step in steps):
        return True
    return not any(step.get("conclusion") == "success" and step.get("name") not in SETUP_STEPS
                   for step in steps)


def hook_refused(steps: list[Mapping[str, Any]]) -> bool:
    """glaeda's job-started hook refused the job: its "Set up runner" step failed.

    The hook waits for capacity inside that step with no limit and can then refuse,
    for a fleet build that started waiting for the host meanwhile (job 122357989139
    of run 40551896747, 2026-10-27: 766 s in the capacity wait, then "refused: a
    fleet build is waiting for the host"). REFUSAL_SECONDS cannot tell that from a
    code failure, but the step can: no workflow code runs in "Set up runner", and a
    failed one skips every workflow step but the `always()` ones (which may fail
    too, as compile admission's metrics step does), so it is the runner's at any
    length."""
    return any(step.get("name") == HOOK_STEP and step.get("conclusion") == "failure" for step in steps)


def unacquired(job: Mapping[str, Any]) -> bool:
    """An owned job GitHub cancelled because no runner took it: cancelled, with no runner and no step.

    Run 39607661629's ios-simulator-build (2026-10-21) waited 4 minutes for glaeda-ios-sim, then GitHub
    cancelled it alone ("The job was not acquired by Runner of type self-hosted even after multiple
    attempts") and the run ended in failure. A run cancelled as a whole leaves its queued jobs the same
    way, so watch() counts this only in a run that finished with another conclusion, or one the rescue
    itself cancelled and never re-ran (rerun_intended()).
    """
    return bool(job_pool(job)) and job.get("status") == "completed" and job.get("conclusion") == "cancelled" \
        and not job.get("runner_name") and not job.get("steps")


# GitHub's annotation on the jobs of a cancelled run: "The run was canceled by @cmux-bot[bot]." (DEV run 40506100431).
CANCELLED_BY = re.compile(r"\bThe run was cancell?ed by @([A-Za-z0-9-]+(?:\[bot\])?)")


# Annotation reads per look: GitHub writes the "canceled by" line on some of a cancelled run's jobs, so each is read
# until one names the canceller; a run with more cancelled jobs than this, none read naming one, is unknown.
CANCELLED_BY_READS = 30
# Pages of 100 annotations read per job; a job with more is unknown (GitHub keeps at most 50 per step and 10 steps' worth).
ANNOTATION_PAGES = 5


class RescueHistoryCapped(Exception):
    """The rescue runs were not all listed (GitHub.rescue_jobs() read RESCUE_RUN_PAGES pages and found no end): a
    settled mark may be on the next page, so no intent is read from it. Not a read error: read() does not retry it."""


class RescueHistoryLive(RescueHistoryCapped):
    """Another rescue run that could have resumed this run's re-run (a sweeper, or this run's own watch) is still
    running: its CANCEL_SETTLED, if any, cannot be read until it ends (GitHub.rescue_jobs())."""


class AnnotationsCapped(Exception):
    """A job's annotations were not all read (GitHub.annotations()); not a read error, so read() does not retry it."""
# rescue() logs CANCEL_SENT once the cancel it means to follow with a re-run went out, and CANCEL_SETTLED when it is
# done with that cancel either way (re-ran, or left it: a moved head, someone else's re-run, an error). Both are
# in the rescue job's own log, which outlives the job: a run with CANCEL_SENT and no CANCEL_SETTLED is one whose
# rescue job stopped in between (cancelled, killed, out of time), and a successor re-runs it (rerun_intended()).
# The queue janitor cancels as cmux-bot too, so the actor alone cannot say whose cancel it was.
_SETTLED_LOCK = threading.Lock()
CANCEL_SENT = "owned-pool rescue: cancel sent, re-run to follow:"
CANCEL_SETTLED = "owned-pool rescue: cancel settled:"
CANCEL_MARK = re.compile(r"owned-pool rescue: (cancel sent, re-run to follow|cancel settled): run (\d+) attempt (\d+)"
                         r"(?=\s|$)( of every job| of job (\d+))?")
# CANCEL_SENT's tail when the re-run to follow is of every job (rescue()'s failed_only off), not its failed ones.
EVERY_JOB = " of every job"
# CANCEL_SENT's tail when the re-run to follow is of one job and its dependents (a settled-sibling failover).
ONE_JOB = " of job {}"
# A rescue job's life: a sweeper's SWEEP_SECONDS and its rescue grace, within ci-owned-pool-rescue.yml's
# timeout-minutes (345); a single watch's JOB_TIMEOUT_SECONDS is shorter.
RESCUE_JOB_LIFETIME_SECONDS = 345 * 60
RESCUE_RUN_PAGES = 10
# A rescue job's log is read as a stream up to this much; a longer one is not judged (the run stays cancelled).
JOB_LOG_MAX_BYTES = 256 * 1024 * 1024
# A log line is read at most this much at a time; the rest of a longer one is skipped.
JOB_LOG_LINE_BYTES = 64 * 1024


def cancel_marks(lines: Any) -> dict[tuple[int, int], str]:
    """The last CANCEL_SENT or CANCEL_SETTLED mark of each (run id, attempt) in a log's lines: "sent" (its failed jobs
    to be re-run), "sent all" (every job), "sent job N" (job N and its dependents) or "settled"."""
    found: dict[tuple[int, int], str] = {}
    for line in lines:
        if "owned-pool rescue: cancel" not in line:
            continue
        for mark in CANCEL_MARK.finditer(line):
            sent = ("sent all" if mark.group(4) == EVERY_JOB else f"sent job {mark.group(5)}" if mark.group(5)
                    else "sent")
            found[(int(mark.group(2)), int(mark.group(3)))] = (
                sent if mark.group(1).startswith("cancel sent") else "settled")
    return found


def canceller(api: GitHub, jobs: Sequence[Mapping[str, Any]], sleep: Callable[[float], None],
              log: Callable[[str], None]) -> str | None:
    """Who cancelled the run, as GitHub's annotation on one of its cancelled jobs says ("" when none of them says;
    None when the annotations could not be read, or not all of them). Jobs no runner acquired first."""
    cancelled = sorted((job for job in jobs if job.get("conclusion") == "cancelled" and job.get("id")),
                       key=lambda job: not unacquired(job))
    for job in cancelled[:CANCELLED_BY_READS]:
        try:
            notes = read(lambda: api.annotations(int(job["id"]), final=job.get("status") == "completed"), sleep, log)
        except (*READ_ERRORS, AnnotationsCapped) as error:
            log(f"could not read who cancelled the run ({error})")
            return None
        for note in notes:
            found = CANCELLED_BY.search(str(note.get("message") or ""))
            if found:
                return found.group(1)
    if len(cancelled) > CANCELLED_BY_READS:
        log(f"{len(cancelled)} cancelled jobs, and none of the first {CANCELLED_BY_READS} names who cancelled the run")
        return None
    return ""


def rerun_intended(api: GitHub, run: Mapping[str, Any], attempt: int, sleep: Callable[[float], None],
                   log: Callable[[str], None]) -> str:
    """"failed", "all" or "job:N" (the re-run it meant) when a rescue job that has ended logged CANCEL_SENT for this run's
    attempt and no CANCEL_SETTLED: it cancelled the run to re-run it and stopped before it was done (cancelled,
    killed, out of time); "" otherwise.

    Only the rescue jobs that ended no earlier than CANCEL_WAIT_SECONDS (the longest a cancel takes to settle)
    before the run finished are read: those that ran when it was cancelled, and every later one, so a successor
    that already resumed the re-run (its CANCEL_SETTLED) stops the next from resuming it again. Fails closed:
    a mark read nowhere, or a log that cannot be read, leaves the run cancelled."""
    finished = parse_time(run.get("updated_at"))
    if finished is None:
        return ""
    wanted = (int(run.get("id") or 0), attempt)
    with _SETTLED_LOCK:
        if wanted in SETTLED_HERE:
            return ""  # this sweeper settled it already (its own log is read only once it ends)
    state = ""
    try:
        for job_id in read(lambda: api.rescue_jobs(finished - dt.timedelta(seconds=CANCEL_WAIT_SECONDS), wanted[0]),
                           sleep, log):
            marks = read(lambda: api.job_marks(job_id), sleep, log)
            if marks is None:
                log(f"rescue job {job_id}'s log could not be read whole; the run is left cancelled")
                return ""
            state = marks.get(wanted) or state
            if state == "settled":
                return ""
    except (*READ_ERRORS, RescueHistoryCapped) as error:
        log(f"could not read the rescue jobs' logs ({error}); the run is left cancelled")
        return ""
    if state.startswith("sent job "):
        return "job:" + state.removeprefix("sent job ")
    return {"sent": "failed", "sent all": "all"}.get(state, "")


def accepted(job: Mapping[str, Any], now: dt.datetime) -> bool:
    """An owned job its runner took and has not refused: past its setup and started over REFUSAL_SECONDS ago,
    or done."""
    if job.get("status") == "completed":
        return not refused(job)
    started = parse_time(job.get("started_at"))
    return job.get("status") == "in_progress" and not in_setup(job) and started is not None and \
        (now - started).total_seconds() > REFUSAL_SECONDS


def carried(job: Mapping[str, Any], attempt_started: dt.datetime | None = None) -> bool:
    """A job a re-run of failed jobs kept from an earlier attempt.

    GitHub's attempt-jobs response has no documented ``created_at`` field. When
    the workflow run supplies its API-backed attempt start, compare the job's
    start with that boundary; retain the receipt fallback for older callers.
    """
    if attempt_started is not None:
        started = parse_time(job.get("started_at"))
        return started is not None and started < attempt_started
    created, started = parse_time(job.get("created_at")), parse_time(job.get("started_at"))
    return created is not None and started is not None and started < created


def picker_finished(jobs: Sequence[Mapping[str, Any]], picker_job: str = PICKER_JOB) -> bool:
    picker = [job for job in jobs if job.get("name") == picker_job]
    return bool(picker) and all(job.get("status") == "completed" for job in picker)


def run_finished(jobs: Sequence[Mapping[str, Any]]) -> bool:
    return bool(jobs) and all(job.get("status") == "completed" for job in jobs)


@dataclasses.dataclass(frozen=True)
class Look:
    action: str  # "rescue" (cancel, re-run all), "refused" (re-run failed jobs) or "watch"
    reason: str
    waiting: bool = False  # a persistent-pool job has no runner yet


def decided_failures(jobs: Sequence[Mapping[str, Any]], attempt_started: dt.datetime | None = None) -> list[str]:
    """Names of this attempt's jobs that failed on their own: not a fleet refusal (refused()), not a
    job whose runner never ran a step (a lost runner, owned or not) and not one carried from an
    earlier attempt. Such a failure has already made the run red."""
    return sorted(str(job.get("name") or job.get("id")) for job in jobs
                  if job.get("status") == "completed" and job.get("conclusion") == "failure"
                  and job.get("steps") and not refused(job) and not carried(job, attempt_started))


# A `${{ ... }}` expression in a job's `name:`.
NAME_EXPRESSION = re.compile(r"\$\{\{(.*?)\}\}", re.S)
EXPRESSION_LITERAL = re.compile(r"'((?:[^']|'')*)'")
# `operand == operand` or `!=`: a condition whose literal is never the expression's value.
EXPRESSION_COMPARISON = re.compile(r"(?:'(?:[^']|'')*'|[A-Za-z_][\w.\-\[\]*]*)\s*[!=]=\s*"
                                   r"(?:'(?:[^']|'')*'|[A-Za-z_][\w.\-\[\]*]*)")
EXPRESSION_CONTEXT = re.compile(r"\b(?:matrix|inputs|needs|github|vars|env|steps|secrets|strategy|runner|job)\.")


def _name_expression(expression: str) -> str:
    """A regex for the values one `${{ ... }}` of a job name can render to: its string literals (bar
    those a comparison tests against), and anything when a context value can be the result."""
    rest = EXPRESSION_COMPARISON.sub(" ", expression)
    literals = [literal.replace("''", "'") for literal in EXPRESSION_LITERAL.findall(rest)]
    choices = [re.escape(literal) for literal in literals]
    if not literals or EXPRESSION_CONTEXT.search(EXPRESSION_LITERAL.sub(" ", rest)):
        choices.append(".+?")
    return "(?:" + "|".join(choices) + ")"


def _job_name_pattern(key: str, job: Mapping[str, Any]) -> re.Pattern[str]:
    """The jobs API names a workflow job `key` can take: its `name:` (or key) rendered, with a matrix's
    ` (values)` suffix and, for a reusable workflow call, ` / <called job>`."""
    template = str(job.get("name") or key)
    pattern, at = "", 0
    for match in NAME_EXPRESSION.finditer(template):
        pattern += re.escape(template[at:match.start()]) + _name_expression(match.group(1))
        at = match.end()
    pattern += re.escape(template[at:])
    if isinstance(job.get("strategy"), Mapping) and (job.get("strategy") or {}).get("matrix") is not None:
        pattern += r"(?: \(.+\))?"
    if job.get("uses"):
        pattern += r"(?: / .+)?"
    return re.compile(pattern, re.S)


def downstream_of_refusals(workflow_text: str, jobs: Sequence[Mapping[str, Any]],
                           attempt_started: dt.datetime | None = None) -> set[str]:
    """Names of this attempt's failed jobs that failed only because a job they need was refused.

    A job counts when the workflow file's `needs` graph puts a refused job (refused(), or one no runner
    acquired, unacquired()) upstream of it, directly or through other jobs, and every job upstream of it
    that failed, timed out or was cancelled is a refusal or counts itself. That is an `if: always()`
    aggregator failing on a refused leg, such as cmux-tui.yml's hosted-verification (`require_success
    "Rust tests"` after the macOS test leg was refused). A job's own failure cannot be told apart from
    its refused upstream's, so such a job is re-run with it: GitHub's re-run of failed jobs re-runs
    every failed job and everything that needs one. Names map to workflow jobs by their rendered
    `name:`; a name that could be several jobs counts only when every one of them qualifies, and a
    name that matches none never counts.
    """
    document = owned_pool_sources._load(workflow_text)
    spec = {str(key): job for key, job in (document.get("jobs") or {}).items() if isinstance(job, Mapping)}
    needs: dict[str, set[str]] = {}
    for key, job in spec.items():
        wanted = job.get("needs") or []
        needs[key] = {str(item) for item in ([wanted] if isinstance(wanted, str) else wanted)} & set(spec)
    upstream: dict[str, set[str]] = {}

    def ancestors(key: str) -> set[str]:
        if key not in upstream:
            upstream[key] = set()  # a cycle is invalid YAML for GitHub; never loop on one
            found: set[str] = set()
            for parent in needs.get(key, ()):
                found |= {parent} | ancestors(parent)
            upstream[key] = found
        return upstream[key]

    patterns = {key: _job_name_pattern(key, job) for key, job in spec.items()}
    keys_of: dict[int, set[str]] = {}
    for job in jobs:
        name = str(job.get("name") or "")
        keys_of[id(job)] = {key for key, pattern in patterns.items() if pattern.fullmatch(name)}
    current = [job for job in jobs if job.get("status") == "completed" and not carried(job, attempt_started)]
    causes = [job for job in current if refused(job) or unacquired(job)]
    broken = [job for job in current if job.get("conclusion") in ("failure", "timed_out", "cancelled")
              and not any(job is cause for cause in causes)]
    excused: list[Mapping[str, Any]] = []
    changed = True
    while changed:
        changed = False
        for job in broken:
            keys = keys_of[id(job)]
            if job.get("conclusion") == "cancelled" or not keys or any(job is other for other in excused):
                continue
            above = set().union(*(ancestors(key) for key in keys))
            # Every job this name could be needs a refused job, whichever job each refused name is.
            if not all(any(keys_of[id(cause)] and keys_of[id(cause)] <= ancestors(key) for cause in causes)
                       for key in keys):
                continue
            # No other failure or cancel upstream of it that is not itself excused.
            if any(other is not job and keys_of[id(other)] & above and not any(other is ok for ok in excused)
                   for other in broken):
                continue
            excused.append(job)
            changed = True
    return {str(job.get("name") or job.get("id")) for job in excused}


def setup_budget(job: Mapping[str, Any], now: dt.datetime, budget_seconds: int,
                 deadline: dt.datetime | None) -> float:
    """SETUP_WAIT_SECONDS, cut so a job that entered setup late is still judged before the watch ends (as
    job_budget() cuts a queued job's), and never below the queued budget."""
    if deadline is None:
        return SETUP_WAIT_SECONDS
    left = setup_seconds(job, now) + (deadline - now).total_seconds() - END_MARGIN_SECONDS
    return min(SETUP_WAIT_SECONDS, max(budget_seconds, left))


def assess(jobs: Sequence[Mapping[str, Any]], *, now: dt.datetime, budget_seconds: int,
           first_seen: Mapping[Any, dt.datetime] | None = None, deadline: dt.datetime | None = None,
           floor_seconds: int | None = None, allow_running_rescue: bool = False,
           leave_decided: bool = False, attempt_started_at: dt.datetime | None = None,
           reserved: bool = False, stranded: bool = False) -> Look:
    """One look at the jobs of a run on a persistent pool (each job's budget: job_budget()).

    With `leave_decided` (a pull request run), a stuck or held job is left queued once another job of
    the attempt has failed on its own (decided_failures()). With `reserved` (a nightly build), a job
    waiting for the one runner it names (reserved_runner()) is never stuck or held: only a refusal of
    it is acted on. With `stranded` (the run finished, not cancelled), a job no runner acquired
    (unacquired()) counts as refused.
    """
    seen = first_seen or {}
    waiting = [job for job in jobs if job_pool(job) and waiting_for_runner(job)]
    budgets = {id(job): job_budget(job, budget_seconds, deadline=deadline, floor_seconds=floor_seconds,
                                   first_seen=seen.get(job.get("id"))) for job in waiting}
    kept = [job for job in jobs if reserved and job_pool(job) and reserved_runner(job)
            and (waiting_for_runner(job) or in_setup(job))]
    # A job other than the build waits for the reserved runner RESERVED_FOLLOWER_SECONDS at most.
    timed_out = [job for job in kept if reserved_follower(job) and waiting_for_runner(job)
                 and queued_seconds(job, now, seen.get(job.get("id"))) >= RESERVED_FOLLOWER_SECONDS]
    kept = [job for job in kept if not any(job is other for other in timed_out)]
    stuck = [job for job in waiting if queued_seconds(job, now, seen.get(job.get("id"))) >= budgets[id(job)]
             and not any(job is other for other in kept)]
    stuck += [job for job in timed_out if not any(job is other for other in stuck)]
    names = ", ".join(sorted(str(job.get("name") or job.get("id")) for job in stuck))
    # Rescuing normally cancels the whole run, so a job already running on a
    # persistent runner would die with the stuck one and move to Blacksmith
    # too (#16463). cmux-next's explicit rescue window is the overflow
    # boundary: move the run as the bot once a side job waits past budget even
    # when another side job is still running. Manual reruns stay minis-first
    # through attempt 2; the bot's next rerun is the overflow.
    on_mini = [job for job in jobs if job_pool(job) and job.get("status") == "in_progress" and not in_setup(job)]
    if reserved:
        # A started nightly is never cancelled for a slow runner: any job of it a runner has taken, anywhere
        # (a Blacksmith helper build, a Linux sibling, one still in its runner's setup), blocks the cancel.
        on_mini = [job for job in jobs if job.get("status") == "in_progress"]
    # A job that failed on its own (not refused by the fleet) has already made the run red. Cancelling
    # and re-running it repeats that failure and puts the stuck job at the back of the same queue
    # (feat-cmux-next, 2026-10-20: 33 of 44 cmux-next pull request runs reached attempt 2 or 3, each
    # failing `checks` again), so the stuck job stays queued for the minis instead.
    decided = decided_failures(jobs, attempt_started_at) if leave_decided else []
    if stuck and not decided and (allow_running_rescue or not on_mini):
        suffix = (" while another owned job is running; overflowing the queued side jobs"
                  if on_mini else " with no runner")
        return Look("rescue", f"{names} queued on {job_pool(stuck[0])} for at least "
                              f"{min(budgets[id(job)] for job in stuck)}s{suffix}")
    settling = [job for job in jobs if job_pool(job) and in_setup(job)]
    held = [job for job in settling if setup_seconds(job, now) >= setup_budget(job, now, budget_seconds, deadline)
            and not any(job is other for other in kept)]
    # Cancelling the run would kill siblings still running (run 36198335113 lost five
    # shards that way to a refusal), so a job held in setup waits for them, as a
    # refusal does, until the watch is about to end.
    running = [job for job in jobs if job.get("status") == "in_progress" and not in_setup(job)]
    if reserved:
        # A nightly job held in setup has started too (and so has any sibling in its setup): never cancelled.
        running = [job for job in jobs if job.get("status") == "in_progress"]
    closing = deadline is not None and now >= deadline - dt.timedelta(seconds=END_MARGIN_SECONDS)
    # A nightly's running sibling is never cancelled, not even as the watch ends.
    if held and not decided and (not running or closing and not reserved):
        names = ", ".join(sorted(str(job.get("name") or job.get("id")) for job in held))
        return Look("rescue", f"{names} waited in {job_pool(held[0])}'s runner setup for capacity for at least "
                              f"{SETUP_WAIT_SECONDS}s")
    turned_away = [job for job in jobs if refused(job)]
    if turned_away:
        names = ", ".join(sorted(str(job.get("name") or job.get("id")) for job in turned_away))
        return Look("refused", f"{names} refused by {job_pool(turned_away[0])} at job start or Xcode selection")
    lost = [job for job in jobs if stranded and unacquired(job)]
    if lost:
        names = ", ".join(sorted(str(job.get("name") or job.get("id")) for job in lost))
        return Look("refused", f"{names} cancelled by GitHub: no {job_pool(lost[0])} runner acquired it")
    if (stuck or held) and decided:
        waits = ", ".join(sorted(str(job.get("name") or job.get("id")) for job in stuck + held))
        return Look("watch", f"{waits} waiting on {job_pool((stuck or held)[0])}, but {', '.join(decided)} "
                             "already failed, so a re-run would repeat that failure; leaving it queued",
                    waiting=True)
    if kept:
        held_for = ", ".join(sorted(f"{job.get('name') or job.get('id')} ({reserved_runner(job)})" for job in kept))
        return Look("watch", f"{held_for} waiting for the runner reserved for it; never moved", waiting=True)
    if stuck:
        return Look("watch", f"{names} queued on {job_pool(stuck[0])} with no runner, but "
                             f"{len(on_mini)} job(s) of the run are running"
                             + (" (a started nightly is never cancelled)" if reserved else " on a persistent runner"),
                    waiting=True)
    if waiting or settling:
        return Look("watch", f"{len(waiting)} job(s) waiting for a persistent runner, {len(settling)} in its setup",
                    waiting=True)
    return Look("watch", "no job is waiting for a persistent runner")


class Aborted(Exception):
    pass


def _headers(token: str) -> dict[str, str]:
    return {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "cmux-ci-owned-pool-rescue",
    }


# A request GitHub refuses for a rate limit waits and is tried again instead of ending the watch.
# A rescue that cancelled a run and then lost its re-run to a refusal left the run cancelled for
# good (2026-10-26: nightly-next run 40340830337 at e22f9384 was cancelled at 14:36:06Z and the
# watch "gave up: HTTP Error 403" at 14:37:38Z, so the tip never built). The repository's
# GITHUB_TOKENs share one installation budget and a secondary limit that sends no reset, so a
# refusal waits Retry-After, or until x-ratelimit-reset when the budget reads spent, or else
# 60, 120, 240, then 300 s; one job waits at most RATE_LIMIT_WAIT_SECONDS in all, which the
# job timeout keeps room for (JOB_TIMEOUT_SECONDS, ci-owned-pool-rescue.yml's timeout-minutes).
RATE_LIMIT_WAIT_SECONDS = _RATE_LIMIT_ROOM_SECONDS
RATE_LIMIT_FIRST_WAIT_SECONDS = 60
RATE_LIMIT_MAX_WAIT_SECONDS = 300


class QuotaSpent(urllib.error.HTTPError):
    """A single watch's read found the token's hourly budget spent, with its reset further out than the watch may
    wait. Waiting through it only holds a runner, so the read is refused at once and the watch ends green with a
    warning (an infra skip, main()), never red. Still an HTTPError, so every caller that treats a refused read as a
    failed one (READ_ERRORS) keeps doing so. Only before the watch has sent any write (GitHub.may_end_on_spent()): a
    rescue that has cancelled a run still waits through every rate limit for the reads and the re-run that follow,
    as before. The cmux-bot installation ran dry at about 00:50Z on 2026-10-31, and the per-run rescues that hit it
    waited 15 minutes and then failed red."""

    def __init__(self, error: urllib.error.HTTPError, said: str, why: str) -> None:
        super().__init__(error.url, error.code, why, error.headers, io.BytesIO(said.encode()))
        self.why = why


def quota_skip(error: BaseException) -> str | None:
    """The infra-skip warning for a watch that ended on a spent API budget, or None for any other error."""
    if not isinstance(error, QuotaSpent):
        return None
    return (f"::warning title=GitHub API budget::infra skip: {error.why}; the run is left as GitHub scheduled it "
            "(a later sweeper adopts what it would have watched)")


def rate_limit_wait(code: int, headers: Mapping[str, str], body: str, now: float, tries: int) -> float | None:
    """Seconds to wait before retrying a refused request, or None when it is not a rate limit.

    A permission 403 has no Retry-After, no spent budget and no "rate limit" in its message."""
    if code not in (403, 429):
        return None
    get = {str(key).lower(): str(value) for key, value in (headers or {}).items()}.get
    retry_after = (get("retry-after") or "").strip()
    remaining = (get("x-ratelimit-remaining") or "").strip()
    said = body.lower()
    # The same messages scripts/ci/gh_budget_wait.sh treats as a rate limit.
    limited = code == 429 or bool(retry_after) or remaining == "0" or any(
        phrase in said for phrase in ("rate limit", "abuse detection", "too many requests"))
    if not limited:
        return None
    if retry_after.isdigit():
        return max(float(retry_after), 1.0)
    reset = (get("x-ratelimit-reset") or "").strip()
    if remaining == "0" and reset.isdigit() and int(reset) > now:
        return int(reset) - now + 5
    return float(min(RATE_LIMIT_FIRST_WAIT_SECONDS << min(tries, 8), RATE_LIMIT_MAX_WAIT_SECONDS))


# GitHub.request()'s budget (the module docstring's last paragraph on the request budget).
BUDGET_FLOOR = 1000
BUDGET_RESERVE = 100
BUDGET_READ_SECONDS = 30
# An installation token lasts 60 minutes; a new one is minted after this many seconds.
TOKEN_REFRESH_SECONDS = 45 * 60
# How long one janitor snapshot read serves every watch of a process (GitHub.pool_snapshot()).
SNAPSHOT_CACHE_SECONDS = 60
BOT_PERMISSIONS = {"actions": "write", "checks": "read", "contents": "read", "issues": "write",
                   "pull_requests": "write"}
_CACHE_LIMIT = 4000


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def app_jwt(app_id: str, key: str, now: float | None = None,
            run: Callable[..., Any] = subprocess.run) -> str:
    """An App JWT (RS256), signed by openssl: the runner's Python has no RSA."""
    now = time.time() if now is None else now
    iss: int | str = int(app_id) if app_id.isdigit() else app_id
    head = _b64(json.dumps({"alg": "RS256", "typ": "JWT"}, separators=(",", ":")).encode())
    claims = _b64(json.dumps({"iat": int(now) - 60, "exp": int(now) + 540, "iss": iss},
                             separators=(",", ":")).encode())
    signing = f"{head}.{claims}"
    # mkstemp's file is 0600; the key never reaches argv or the log.
    with tempfile.NamedTemporaryFile("w", suffix=".pem") as handle:
        handle.write(key)
        handle.flush()
        signature = run(["openssl", "dgst", "-sha256", "-sign", handle.name], input=signing.encode(),
                        capture_output=True, check=True, timeout=30).stdout
    return f"{signing}.{_b64(signature)}"


def app_token_minter(app_id: str, key: str, repo: str) -> Callable[[], str]:
    """A function returning a new installation token of the App for `repo`, with BOT_PERMISSIONS."""
    def call(method: str, url: str, jwt: str, body: Mapping | None = None) -> Mapping[str, Any]:
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, method=method, headers=_headers(jwt), data=data)
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.loads(response.read() or b"{}")

    def mint() -> str:
        jwt = app_jwt(app_id, key)
        installation = call("GET", f"{API}/repos/{repo}/installation", jwt)
        found = call("POST", f"{API}/app/installations/{int(installation['id'])}/access_tokens", jwt,
                     {"repositories": [repo.split("/", 1)[-1]], "permissions": BOT_PERMISSIONS})
        return str(found["token"])
    return mint


# A listing's `created>=` bound is rounded down to this step, so the same URL is asked again tick after tick and its
# ETag can answer 304 (a bound that moved every tick made every listing a new URL, never conditional); the runs the
# rounding adds are dropped by their own created_at (created_before()).
CREATED_STEP_SECONDS = 30 * 60


def created_floor(moment: dt.datetime) -> dt.datetime:
    """`moment` in UTC, rounded down to CREATED_STEP_SECONDS."""
    stamp = int(moment.astimezone(dt.timezone.utc).timestamp())
    return dt.datetime.fromtimestamp(stamp - stamp % CREATED_STEP_SECONDS, dt.timezone.utc)


def created_before(run: Mapping[str, Any], oldest: dt.datetime) -> bool:
    """The run was created before `oldest` (a run the rounded-down listing bound let in)."""
    created = parse_time(run.get("created_at"))
    return created is not None and created < oldest


def _kind(path: str) -> str:
    return re.sub(r"/[0-9]+", "/{n}", path.split("?", 1)[0])


class GitHub:
    """The Actions API. Reads may use `read_token`, writes always use `token`.

    `read_token` is a manaflow-glaeda-route App installation token, so the
    watch's polling draws on the App's own 5000 requests an hour instead of
    the repository's GITHUB_TOKEN budget. Cancels and re-runs keep
    GITHUB_TOKEN: a re-run's triggering actor must stay github-actions[bot],
    which ci-macos.yml's attempt-2 routing checks. An installation token
    lasts an hour and a watch may outlive it, so a 401 on a read drops back to
    `token` for the rest of the watch. A 403 is a read the App may not make
    (branch_head needs contents, which it lacks): that one read uses `token`.
    """

    def __init__(self, token: str, repo: str, read_token: str = "") -> None:
        self.repo = repo
        self.headers = _headers(token)
        self.read_headers = _headers(read_token) if read_token else self.headers
        self._snapshot_token = read_token or token
        # pool_snapshot()'s last read: (monotonic time, snapshot or None).
        self._snapshot_cache: tuple[float, Mapping[str, Any] | None] | None = None
        self.sleep: Callable[[float], None] = time.sleep
        # Each watch (the sweeper runs one per thread on this one client) has its own
        # RATE_LIMIT_WAIT_SECONDS, so one run's waits never spend another's.
        self._limits = threading.local()
        self._lock = threading.Lock()
        # GET answers by (token, path): (ETag, body, monotonic time read or confirmed). By token: GitHub's ETag
        # covers the Authorization header, so another token's ETag never answers 304 (the module docstring).
        self._cache: dict[tuple[str, str], tuple[str, bytes, float]] = {}
        # Finished jobs' cancel marks by job id (job_marks()): a finished job's log no longer changes.
        self._logs: dict[int, dict[tuple[int, int], str] | None] = {}
        # This rescue job's own workflow run (GITHUB_RUN_ID), which rescue_jobs() never waits on.
        self.own_run = 0
        self._log_lines: dict[int, list[str]] = {}
        # Requests by (kind, "charged" | "not modified"), for the budget lines.
        self.counts: dict[tuple[str, str], int] = {}
        self.started = time.monotonic()
        self._budget: tuple[float, int | None, float | None] = (-1e9, None, None)
        # Set by main() with BOT_APP_ID and BOT_APP_KEY: a new token before the hour is up.
        self.mint: Callable[[], str] | None = None
        self._minted_at = time.monotonic()
        # Bumped when reads move to another token's pool: a budget reading of the old pool is dropped.
        self._pool = 0
        # Every Authorization the minted App (GH_TOKEN) has used: only its 401s mint a new token.
        self._app_auths = {self.headers["Authorization"]}
        # Set by main() for a single watch that is not a nightly's: pace() ends it (QuotaSpent) instead of waiting
        # through a reset further out than RATE_LIMIT_WAIT_SECONDS. The sweeper keeps waiting: it is the one
        # watcher of every marked run, and the next one starts only with the cron.
        self.end_on_spent = False
        # Annotations of finished jobs by job id (annotations(final=True)): they no longer change.
        self._annotations: dict[int, list[Mapping[str, Any]]] = {}
        # Finished rescue runs' finished job ids by (run id, attempt) (rescue_jobs()): they no longer change.
        self._rescue_attempt_jobs: dict[tuple[int, int], list[int]] = {}

    def _count(self, path: str, outcome: str) -> None:
        with self._lock:
            key = (_kind(path), outcome)
            self.counts[key] = self.counts.get(key, 0) + 1

    def usage(self) -> str:
        """`N charged (P/h), M not modified` since the client started, and the costliest kinds."""
        with self._lock:
            counts = dict(self.counts)
        total = {outcome: sum(n for (_, seen), n in counts.items() if seen == outcome)
                 for outcome in ("charged", "not modified")}
        hours = max((time.monotonic() - self.started) / 3600, 1 / 60)
        kinds = sorted(((n, kind) for (kind, seen), n in counts.items() if seen == "charged"), reverse=True)[:4]
        return (f"REST {total['charged']} charged ({total['charged'] / hours:.0f}/h), "
                f"{total['not modified']} not modified (304)"
                + ("; " + ", ".join(f"{kind} {n}" for n, kind in kinds) if kinds else ""))

    def budget_left(self) -> tuple[int | None, float | None]:
        """(remaining, reset epoch) of the read token's core pool, from GET /rate_limit, which costs
        nothing; read at most every BUDGET_READ_SECONDS. (None, None) when it cannot be read."""
        with self._lock:
            read_at, remaining, reset = self._budget
            if time.monotonic() - read_at < BUDGET_READ_SECONDS:
                return remaining, reset
            self._budget = (time.monotonic(), remaining, reset)  # one reader at a time
            pool, headers = self._pool, dict(self.read_headers)
        try:
            self._fresh_token()
            with self._lock:
                if pool == self._pool:
                    headers = dict(self.read_headers)
            request = urllib.request.Request(f"{API}/rate_limit", headers=headers)
            with urllib.request.urlopen(request, timeout=20) as response:
                core = (json.loads(response.read() or b"{}").get("resources") or {}).get("core") or {}
            remaining, reset = int(core["remaining"]), float(core["reset"])
        except (*READ_ERRORS, KeyError, TypeError) as error:
            print(f"could not read the API budget ({error})", flush=True)
            remaining, reset = None, None
        with self._lock:
            if pool == self._pool:
                self._budget = (time.monotonic(), *self._merged(remaining, reset))
            return self._budget[1], self._budget[2]

    def _note_budget(self, seen: Mapping[str, str] | None, pool: int | None) -> None:
        """A read-token answer's own rate-limit headers keep budget_left() current between its reads.
        `pool` is the read pool the request was sent on (None: not the read token's); an answer from a
        pool the reads have since left says nothing about the current one."""
        if pool is None:
            return
        try:
            remaining = int((seen or {}).get("X-RateLimit-Remaining") or "")
            reset = float((seen or {}).get("X-RateLimit-Reset") or "")
        except (ValueError, TypeError, AttributeError):
            return
        if ((seen or {}).get("X-RateLimit-Resource") or "core") != "core":
            return
        with self._lock:
            if pool == self._pool:
                self._budget = (self._budget[0], *self._merged(remaining, reset))

    def _merged(self, remaining: int | None, reset: float | None) -> tuple[int | None, float | None]:
        """The newer reading, under the lock: a later window replaces an older one, and within one
        window the lowest balance wins (answers can arrive out of order)."""
        _, known, known_reset = self._budget
        if remaining is None or known is None or known_reset is None or reset is None or reset > known_reset:
            return remaining, reset
        if reset < known_reset:
            return known, known_reset
        return min(known, remaining), reset

    def pace(self, interval: float) -> float:
        """How long to wait before the next non-urgent read: `interval`, IDLE_POLL_SECONDS below
        BUDGET_FLOOR, or until the reset below BUDGET_RESERVE (refused reads would only add waits)."""
        remaining, reset = self.budget_left()
        if remaining is None or remaining >= BUDGET_FLOOR:
            return interval
        if remaining < BUDGET_RESERVE and reset is not None:
            until = reset - time.time() + 5
            if until > RATE_LIMIT_WAIT_SECONDS and self.may_end_on_spent():
                # A single watch (not the sweeper, not a nightly's) does not hold its runner through the reset.
                raise QuotaSpent(urllib.error.HTTPError(f"{API}/rate_limit", 403, "spent", None, None), "",
                                 f"{remaining} API requests left and the budget resets in {until:.0f}s, past the "
                                 f"{RATE_LIMIT_WAIT_SECONDS}s a watch may wait")
            return max(interval, until)
        return max(interval, IDLE_POLL_SECONDS)

    def may_end_on_spent(self) -> bool:
        """A spent budget may end this thread's watch (QuotaSpent): a single watch that is not a nightly's
        (end_on_spent), before this thread has sent any write. After a cancel, its reads and re-run wait as before."""
        return self.end_on_spent and not getattr(self._limits, "wrote", False)

    def _fresh_token(self, stale: str | None = None) -> None:
        """Swap in a new installation token when the current one is TOKEN_REFRESH_SECONDS old, or when
        it is still `stale` (the Authorization a request was refused with: concurrent 401s mint once)."""
        if self.mint is None or stale is None and time.monotonic() - self._minted_at < TOKEN_REFRESH_SECONDS:
            return
        with self._lock:
            if stale is not None and self.headers["Authorization"] != stale:
                return  # another thread already minted
            if stale is None and time.monotonic() - self._minted_at < TOKEN_REFRESH_SECONDS:
                return
            try:
                token = self.mint()
            except Exception as error:  # noqa: BLE001 - the old token is still tried
                print(f"::warning title=GitHub API budget::could not mint a new token "
                      f"({type(error).__name__}); trying again in a minute", flush=True)
                self._minted_at = time.monotonic() - TOKEN_REFRESH_SECONDS + 60
                return
            old = self.headers["Authorization"]
            # In place: request() tells the two token's headers apart by identity. Only the App's
            # token (GH_TOKEN) is replaced, in whichever header set carries it; a different
            # READ_TOKEN is left alone.
            for headers in (self.headers, self.read_headers):
                if headers["Authorization"] == old:
                    headers["Authorization"] = f"Bearer {token}"
            self._app_auths.add(f"Bearer {token}")
            self._minted_at = time.monotonic()
        print("minted a new cmux-bot installation token", flush=True)

    @property
    def rate_limit_waited(self) -> float:
        """This thread's waits for rate limits so far."""
        return getattr(self._limits, "waited", 0.0)

    @property
    def rate_limit_tries(self) -> int:
        return getattr(self._limits, "tries", 0)

    def no_rate_limit_waits(self) -> None:
        """This thread's requests raise on a rate limit instead of waiting (the sweeper's own
        listings, which run on its schedule and must not push its handover past the job's timeout)."""
        self._limits.waited = float(RATE_LIMIT_WAIT_SECONDS)

    def _wait_for_rate_limit(self, method: str, path: str, error: urllib.error.HTTPError) -> bool:
        """Wait out a GITHUB_TOKEN request's rate-limit refusal; False when it is not one. Raises QuotaSpent when this
        thread's waits are used up, or when the hour's budget is spent and resets later than they could wait."""
        try:
            said = error.read().decode("utf-8", "replace")
        except Exception:  # noqa: BLE001 - the body only explains the refusal
            said = ""
        headers = dict(error.headers.items()) if error.headers is not None else {}
        wait = rate_limit_wait(error.code, headers, said, time.time(), self.rate_limit_tries)
        if wait is None:
            return False
        left = RATE_LIMIT_WAIT_SECONDS - self.rate_limit_waited
        if left < 1:
            return False
        spent = {key.lower(): value for key, value in headers.items()}.get("x-ratelimit-remaining", "").strip() == "0"
        if spent and wait > left and method == "GET" and self.may_end_on_spent():
            # The hour's budget is gone and its reset is further out than the wait left: waiting it out only holds
            # the runner, and the request fails at the end anyway.
            raise QuotaSpent(error, said, f"{method} {path} was refused: the API budget is spent and resets in "
                                          f"{wait:.0f}s, past the {left:.0f}s this watch may wait")
        wait = min(wait, left)
        self._limits.tries = self.rate_limit_tries + 1
        self._limits.waited = self.rate_limit_waited + wait
        shown = {key: value for key, value in headers.items()
                 if key.lower().startswith(("x-ratelimit", "retry-after", "x-github-request-id"))}
        print(f"::notice title=GitHub API budget::{method} {path} was refused for a rate limit "
              f"(HTTP {error.code}, {shown or 'no rate-limit headers'}: {said.strip()[:200]}); "
              f"waiting {wait:.0f}s ({self.rate_limit_waited - wait:.0f}s waited so far)",
              file=sys.stderr, flush=True)
        self.sleep(wait)
        return True

    def request(self, method: str, path: str, *, own_token: bool = False, body: Mapping | None = None,
                before_retry: Callable[[], None] | None = None, refreshed: bool = False,
                before_send: Callable[[], None] | None = None) -> Any:
        self._fresh_token()
        if method != "GET":
            self._limits.wrote = True  # from here on this watch waits through rate limits (may_end_on_spent())
        headers = self.read_headers if method == "GET" and not own_token else self.headers
        with self._lock:
            # One token for the whole request, read under the lock _fresh_token() swaps it under.
            sent = dict(headers)
            cached = self._cache.get((sent["Authorization"], path)) if method == "GET" else None
            # The read pool this request counts against, or None (GITHUB_TOKEN's writes and fallbacks).
            pool = self._pool if headers is self.read_headers else None
        key = (sent["Authorization"], path)
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(f"{API}/repos/{self.repo}{path}", method=method, headers=sent, data=data)
        if cached is not None:
            # Always asked again (never served from memory): a 304 says the answer is still current.
            request.add_header("If-None-Match", cached[0])
        if before_send is not None:
            # Last, after any token mint and outside the lock another thread may hold through one, right
            # before the request goes out (and again before any retry of it): raises to drop the request
            # (GitHub.cancel()).
            before_send()
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                body = response.read()
                seen = getattr(response, "headers", None) or {}
                self.remaining = seen.get("X-RateLimit-Remaining") or self.remaining
                self.limit = seen.get("X-RateLimit-Limit") or self.limit
                etag = seen.get("ETag") if method == "GET" else None
                self._note_budget(seen, pool)
            self._limits.tries = 0
            self._count(path, "charged")
            if etag:
                with self._lock:
                    if len(self._cache) >= _CACHE_LIMIT:
                        old = time.monotonic() - 15 * 60
                        self._cache = {k: v for k, v in self._cache.items() if v[2] > old}
                    self._cache[key] = (etag, body, time.monotonic())
        except urllib.error.HTTPError as error:
            self._note_budget(error.headers, pool)
            if error.code == 304 and cached is not None:
                # Not modified: GitHub does not count it against the budget.
                self._limits.tries = 0
                self._count(path, "not modified")
                return json.loads(cached[1]) if cached[1] else None
            if (error.code == 401 and self.mint is not None and not refreshed
                    and sent["Authorization"] in self._app_auths):
                # Only the minted App's own token (GH_TOKEN, current or just replaced); a different
                # READ_TOKEN keeps the fallback to GITHUB_TOKEN below.
                # The token expired before its refresh (a 401 is not charged): mint one, unless another
                # thread already replaced the token this request carried, and send it again once.
                self._fresh_token(stale=sent["Authorization"])
                if before_retry is not None:
                    before_retry()  # what a write acts on may have changed while the token was minted
                return self.request(method, path, own_token=own_token,
                                    body=json.loads(data) if data is not None else None, before_retry=before_retry, before_send=before_send,
                                    refreshed=True)
            if headers is self.headers and error.code in (403, 429) and self._wait_for_rate_limit(method, path, error):
                # The same request again, after the wait (a refused request did nothing on GitHub's side),
                # unless what it acts on changed meanwhile (before_retry raises).
                if before_retry is not None:
                    before_retry()
                return self.request(method, path, own_token=own_token,
                                    body=json.loads(data) if data is not None else None, before_retry=before_retry, before_send=before_send,
                                    refreshed=refreshed)
            if error.code not in (401, 403, 429) or headers is self.headers:
                raise
            if error.code in (403, 429):
                # The installation lacks this read's permission, or its budget is spent: this one
                # read goes on GITHUB_TOKEN (which waits through a rate limit).
                return self.request(method, path, own_token=True, refreshed=refreshed, before_send=before_send)
            with self._lock:
                self.read_headers = self.headers
                self._budget = (-1e9, None, None)  # another token's pool: read it afresh
                self._pool += 1
            return self.request(method, path, refreshed=refreshed, before_send=before_send)
        return json.loads(body) if body else None

    remaining = ""  # the token's requests left this hour, from the last response
    limit = ""  # and its hourly limit

    def marked_runs(self, name: str, count: int, oldest: dt.datetime | None = None, pages: int = 1,
                    log: Callable[[str], None] = lambda message: None) -> list[tuple[int, dt.datetime | None]]:
        """Runs with an artifact named `name`, by artifact id, newest first, with when each was uploaded (sweep()).

        Reads up to `pages` pages of `count`, stopping at a short page or at
        one whose last marker is older than `oldest` by MARKER_ORDER_SKEW:
        the listing is ordered by id, which trails upload time by up to that
        much. A page that cannot be read ends the listing with what came
        before it, unless it is the first.
        """
        found = []
        for page in range(1, pages + 1):
            try:
                data = self.request("GET", f"/actions/artifacts?name={name}&per_page={count}&page={page}")
            except READ_ERRORS:
                if page == 1:
                    raise
                log(f"could not read page {page} of the {name} markers; using the first {page - 1}")
                return found
            items = (data or {}).get("artifacts") or []
            for item in items:
                run_id = int(((item or {}).get("workflow_run") or {}).get("id") or 0)
                if run_id:
                    found.append((run_id, parse_time(item.get("created_at"))))
            last = parse_time(items[-1].get("created_at")) if items else None
            if len(items) < count or oldest is None or last is None or last < oldest - MARKER_ORDER_SKEW:
                return found
        if oldest is not None:
            log(f"read {pages} pages of {name} markers without reaching {oldest:%H:%M}; older ones wait for a later tick")
        return found

    def run(self, run_id: int) -> Mapping[str, Any]:
        return self.request("GET", f"/actions/runs/{run_id}")

    def owned_reruns(self, count: int) -> list[tuple[int, int]]:
        """(run id, attempt) of unfinished CI and cmux-next re-runs whose owned jobs go back to the minis
        (owned_rerun()): a re-run of failed jobs uploads no marker. GitHub lists a run as `queued` while a job of it waits for a
        runner, so both statuses are read."""
        found: list[tuple[int, int]] = []
        for workflow in (CI_WORKFLOW_PATH, CMUX_NEXT_WORKFLOW_PATH):
            name = workflow.rsplit("/", 1)[-1]
            for status in ("queued", "in_progress"):
                data = self.request("GET", f"/actions/workflows/{name}/runs?status={status}&per_page={count}")
                found += [(int(run["id"]), int(run["run_attempt"])) for run in (data or {}).get("workflow_runs") or []
                          if isinstance(run, Mapping) and run.get("id") and owned_rerun(run)]
        return found

    def nightly_reruns(self, count: int) -> list[tuple[int, int]]:
        """(run id, attempt) of unfinished nightly-next re-runs, every attempt from 2 on. Only a re-run whose build
        picker chose an owned Mac leaves a marker, so a re-run on Blacksmith (a re-run of failed jobs, or a full one
        the picker placed there) is found here, for its signing jobs' stalls (signing_stall(), which watch() still
        acts on through SIGN_RESCUE_LAST_ATTEMPT only). An owned pick's marker on a later attempt is no help either:
        the marker listing adopts a run id once (`seen`). So every attempt is listed: while every Blacksmith label
        stalls, the picker queues each attempt's build on a busy or offline owned pool, and the rescue's timed hold
        re-runs the picker (rerun_failed_or_repick()), attempt after attempt; attempt 4 and later were never
        watched, so such a build could wait unwatched with no limit (review P1 on #26614). Main's nightly is
        rescued on attempt 1 only (its workflow_run watch): a full re-run there builds the app again."""
        name = NIGHTLY_WORKFLOW_PATH.rsplit("/", 1)[-1]
        found: list[tuple[int, int]] = []
        for status in ("queued", "in_progress"):
            data = self.request("GET", f"/actions/workflows/{name}/runs?status={status}&branch=nightly-next"
                                       f"&per_page={count}")
            found += [(int(run["id"]), int(run["run_attempt"])) for run in (data or {}).get("workflow_runs") or []
                      if isinstance(run, Mapping) and run.get("id") and run.get("head_branch") == "nightly-next"
                      and int(run.get("run_attempt") or 0) > 1]
        return found

    def failed_runs(self, count: int, oldest: dt.datetime, since: dt.datetime | None = None,
                    pages: int = 1) -> list[tuple[int, int]]:
        """(run id, attempt) of the failed runs of SIDE_WORKFLOW_PATHS created since `oldest` and, when
        `since` is given, finished after it: newest first, `count` a page, at most `pages` pages.

        Those workflows upload no marker (sweep()), and a job the fleet refused fails its run, so a
        refusal shows here once the run ends, which is when its failed jobs can be re-run.
        """
        created = created_floor(oldest).strftime("%Y-%m-%dT%H:%M:%SZ")
        found: list[tuple[int, int]] = []
        # Cancelled ones too, one page: a rescue's cancel whose re-run never came (sweep_target()).
        listings = [*(("failure", page) for page in range(1, pages + 1)), ("cancelled", 1)]
        while listings:
            status, page = listings.pop(0)
            data = self.request("GET", f"/actions/runs?status={status}&exclude_pull_requests=true&per_page={count}"
                                       f"&page={page}&created=%3E%3D{created}")
            runs = [run for run in (data or {}).get("workflow_runs") or [] if isinstance(run, Mapping)]
            for run in runs:
                finished = parse_time(run.get("updated_at"))
                entry = (int(run.get("id") or 0), int(run.get("run_attempt") or 0))
                if entry[0] and entry not in found and run.get("path") in SIDE_WORKFLOW_PATHS and not (
                        since is not None and finished is not None and finished < since) \
                        and not created_before(run, oldest):
                    found.append(entry)
            # A status-filtered page can come back short before the last one (queue_janitor.GitHub.
            # in_flight_runs()), so only an empty page ends the listing before `pages`.
            if not runs and status == "failure":
                listings = [listing for listing in listings if listing[0] != "failure"]
        return found

    def queued_side_runs(self, count: int, oldest: dt.datetime, pages: int = 1) -> list[tuple[int, int]]:
        """(run id, attempt) of the queued runs of SIDE_WORKFLOW_PATHS created since `oldest`, cmux-next.yml's
        aside (its placement's marker adopts it): newest first, `count` a page, at most `pages` pages.

        A side-lane job waiting on a label that starts nothing never fails its run, so failed_runs() never
        lists it; GitHub lists a run `queued` while its jobs wait and none runs, which is when the open-head
        failover (unstarted_failover()) may move it. A delivery run (never_fails_over(): a scheduled launch smoke,
        say) is not listed: nothing here cancels one that has not failed.
        """
        created = created_floor(oldest).strftime("%Y-%m-%dT%H:%M:%SZ")
        found: list[tuple[int, int]] = []
        for page in range(1, pages + 1):
            data = self.request("GET", f"/actions/runs?status=queued&exclude_pull_requests=true&per_page={count}"
                                       f"&page={page}&created=%3E%3D{created}")
            runs = [run for run in (data or {}).get("workflow_runs") or [] if isinstance(run, Mapping)]
            for run in runs:
                entry = (int(run.get("id") or 0), int(run.get("run_attempt") or 0))
                path = str(run.get("path") or "")
                if entry[0] and entry not in found and path in SIDE_WORKFLOW_PATHS and path != CMUX_NEXT_WORKFLOW_PATH \
                        and not never_fails_over(path, run.get("event")) and not created_before(run, oldest):
                    found.append(entry)
            # As in failed_runs(): only an empty page ends the listing before `pages`.
            if not runs:
                break
        return found

    def jobs(self, run_id: int, attempt: int) -> list[Mapping[str, Any]]:
        found: list[Mapping[str, Any]] = []
        for page in range(1, MAX_JOB_PAGES + 1):
            data = self.request("GET", f"/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100&page={page}")
            batch = [job for job in (data or {}).get("jobs") or [] if isinstance(job, Mapping)]
            found.extend(batch)
            if len(batch) < 100:
                break
        return found

    def rescue_jobs(self, earliest_end: dt.datetime, run_id: int = 0) -> list[int]:
        """The job ids of the finished ci-owned-pool-rescue.yml runs that ended at or after `earliest_end`,
        newest first (a sweeper or a single watch).

        Listed by creation, which precedes the start by the run's wait in the sweeper's concurrency group: at most
        the one sweeper ahead of it (it never cancels in progress, so one waits), RESCUE_JOB_LIFETIME_SECONDS."""
        since = (earliest_end - dt.timedelta(seconds=2 * RESCUE_JOB_LIFETIME_SECONDS)).astimezone(dt.timezone.utc)
        runs: list[Mapping[str, Any]] = []
        for page in range(1, RESCUE_RUN_PAGES + 1):
            # Every status: a rescue run re-run is in progress while its earlier attempts' finished jobs hold marks.
            data = self.request("GET", f"/actions/workflows/{RESCUE_WORKFLOW_FILE}/runs?per_page=100"
                                       f"&page={page}&created=%3E%3D{since.strftime('%Y-%m-%dT%H:%M:%SZ')}")
            batch = [run for run in (data or {}).get("workflow_runs") or [] if isinstance(run, Mapping)]
            runs += batch
            total = (data or {}).get("total_count") if isinstance(data, Mapping) else None
            if page == 1 and isinstance(total, int) and total > 100 * RESCUE_RUN_PAGES:
                # GitHub already counts more than the pages would hold: the other nine pages would only end in the
                # same RescueHistoryCapped. The window holds every skipped rescue run too (360 an hour on
                # 2026-10-30), so every read of it ended here, after ten charged pages, 64 times in one sweeper.
                raise RescueHistoryCapped(f"{total} rescue runs in the window, more than {RESCUE_RUN_PAGES} pages")
            # A page can come back short before the last one (failed_runs()): only an empty one ends.
            if not batch:
                break
        else:
            raise RescueHistoryCapped(f"{RESCUE_RUN_PAGES} pages of rescue runs and no end")
        found: list[int] = []
        for run in runs:
            attempts = int(run.get("run_attempt") or 1)
            if run.get("status") == "in_progress" and attempts == 1 and int(run.get("id") or 0) != self.own_run:
                # A job's log is read only once it has ended. A live sweeper, or this run's own watch, may already
                # have resumed this re-run and logged CANCEL_SETTLED: not known until it ends, so not judged now
                # (the run stays cancelled; a later sweeper reads it). Other watches never resume this run, and a
                # re-run of the rescue workflow logs no marks (main()).
                title = str(run.get("display_title") or run.get("name") or "")
                if title == "owned-pool-sweeper" or run_id and title.startswith(f"owned-pool-rescue-{run_id}-"):
                    raise RescueHistoryLive(f"rescue run {run.get('id')} ({title}) is still running")
            if attempts <= 1 and run.get("conclusion") == "skipped":
                continue
            began, ended = parse_time(run.get("run_started_at")), parse_time(run.get("updated_at"))
            if began is None or ended is None or ended < earliest_end:
                continue
            # Each attempt's jobs, newest first: the jobs endpoint alone answers the latest attempt's, and a re-run of
            # the rescue workflow would hide an earlier attempt's CANCEL_SENT or CANCEL_SETTLED. Only finished jobs
            # have a log to read; a running one has not settled anything a successor needs.
            for attempt in range(attempts, 0, -1):
                # A finished attempt's jobs no longer change: listed once per process. An earlier attempt of a run
                # is finished once a later one exists; the newest only once the run is.
                done = attempt < attempts or run.get("status") == "completed"
                memo = (int(run["id"]), attempt)
                with self._lock:
                    known = self._rescue_attempt_jobs.get(memo) if done else None
                if known is None:
                    jobs = self.request("GET", f"/actions/runs/{int(run['id'])}/attempts/{attempt}/jobs?per_page=20")
                    known = [int(job["id"]) for job in (jobs or {}).get("jobs") or []
                             if isinstance(job, Mapping) and job.get("id") and job.get("status") == "completed"
                             and job.get("conclusion") != "skipped"]
                    if done:
                        with self._lock:
                            self._rescue_attempt_jobs[memo] = known
                found += known
        return found

    def job_marks(self, job_id: int) -> dict[tuple[int, int], str] | None:
        """cancel_marks() of a finished job's log, read as a stream (None past JOB_LOG_MAX_BYTES). GitHub answers
        with a redirect to the log's storage, fetched without our token."""
        if job_id in self._logs:
            return self._logs[job_id]
        lines = self._read_log_lines(job_id)
        marks = cancel_marks(lines) if lines is not None else None
        if marks is not None:
            self._logs[job_id] = marks
        return marks

    def job_log_lines(self, job_id: int) -> list[str] | None:
        """A finished picker job's log lines (nightly_retry_destinations()), cached per job. Only the picker
        lines nightly_retry_destinations() matches are kept (NIGHTLY_RETRY_LINE), so the cache stays a few
        short lines a job however long its log; job_marks() caches only its marks."""
        if job_id in self._log_lines:
            return self._log_lines[job_id]
        lines = self._read_log_lines(job_id)
        if lines is None:
            return None
        kept = [line for line in lines if NIGHTLY_RETRY_LINE.search(line)]
        self._log_lines[job_id] = kept
        return kept

    def _read_log_lines(self, job_id: int) -> list[str] | None:
        """A finished job's whole log as lines, or None (an unsized, partial or over-JOB_LOG_MAX_BYTES read)."""

        class Stay(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args: Any, **kwargs: Any) -> None:
                return None
        request = urllib.request.Request(f"{API}/repos/{self.repo}/actions/jobs/{job_id}/logs",
                                         headers=dict(self.read_headers))
        def scan(response: Any) -> list[str] | None:
            """None unless the whole log was read: a Content-Length the response states, and exactly that many bytes.
            A chunked or unsized transfer is not judged (http.client's readline() swallows a chunked one's early
            end). Lines are read JOB_LOG_LINE_BYTES at a time; a longer one is skipped (a mark is a short line of
            its own)."""
            headers = getattr(response, "headers", None) or {}
            stated = headers.get("Content-Length")
            if stated is None or "chunked" in str(headers.get("Transfer-Encoding") or "").lower() or \
                    str(headers.get("Content-Encoding") or "identity").lower() != "identity":
                return None
            read_bytes, lines, partial = 0, [], False
            while True:
                raw = response.readline(JOB_LOG_LINE_BYTES)
                if not raw:
                    break
                read_bytes += len(raw)
                if read_bytes > JOB_LOG_MAX_BYTES:
                    return None
                whole = raw.endswith(b"\n")
                if not partial and (whole or len(raw) < JOB_LOG_LINE_BYTES):
                    lines.append(raw.decode("utf-8", "replace"))
                partial = not whole
            if read_bytes != int(stated):
                return None
            return lines
        try:
            with urllib.request.build_opener(Stay).open(request, timeout=20) as response:
                lines = scan(response)
        except urllib.error.HTTPError as error:
            location = error.headers.get("Location") if error.headers is not None else None
            if error.code not in (301, 302, 303, 307, 308) or not location:
                raise
            with urllib.request.urlopen(location, timeout=60) as response:
                lines = scan(response)
        return lines

    def next_feed_newest_build(self) -> int | None:
        """The newest build in cmux NEXT's nightly appcast (NEXT_FEED_URL), or None when the feed has none. A failed
        read raises (one of READ_ERRORS), so nightly_next_moot() can tell an outage from an empty feed (#29448)."""
        request = urllib.request.Request(NEXT_FEED_URL, headers={"User-Agent": "cmux-owned-pool-rescue"})
        with urllib.request.urlopen(request, timeout=20) as response:
            return newest_feed_build(response.read().decode("utf-8", "replace"))

    def annotations(self, job_id: int, *, final: bool = False) -> list[Mapping[str, Any]]:
        """The annotations of a job's check run (GitHub's "The run was canceled by @actor." among them). `final`: the
        job has finished, so its annotations no longer change and are read once per job (canceller())."""
        if final:
            with self._lock:
                known = self._annotations.get(job_id)
            if known is not None:
                return known
        notes: list[Mapping[str, Any]] = []
        for page in range(1, ANNOTATION_PAGES + 1):
            data = self.request("GET", f"/check-runs/{job_id}/annotations?per_page=100&page={page}")
            batch = [note for note in data or [] if isinstance(note, Mapping)]
            notes += batch
            if len(batch) < 100:
                if final:
                    with self._lock:
                        self._annotations[job_id] = notes
                return notes
        # Not all read: the canceller's line may be past them, so the caller must not read "none says" (canceller()).
        raise AnnotationsCapped(f"job {job_id} has over {100 * ANNOTATION_PAGES} annotations")

    def workflow_file(self, path: str, ref: str) -> str | None:
        """The text of `path` at commit `ref`, or None when it is not there."""
        try:
            data = self.request("GET", f"/contents/{urllib.parse.quote(path)}?ref={urllib.parse.quote(ref)}")
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            raise
        if not isinstance(data, Mapping) or data.get("encoding") != "base64":
            return None
        return base64.b64decode(str(data.get("content") or "")).decode("utf-8")

    def snapshot_token(self) -> str:
        """The token the snapshot reads send: the client's current read token. _fresh_token() swaps a new cmux-bot
        token into the header sets in place, but the snapshot reads kept the token the client started with, which
        expires after an hour: a sweeper's every snapshot read after its first hour was refused (401), and with no
        snapshot the open-head failover keeps every run (sweeper run 41006853342, 2026-10-30: 22 refusals from
        06:12Z, an hour after it started). A read token of another App, which this client never re-mints, gives way
        to the minted App's once one is minted."""
        self._fresh_token()
        with self._lock:
            authorization = str(self.read_headers.get("Authorization") or "")
            if authorization not in self._app_auths and self.mint is not None:
                authorization = str(self.headers.get("Authorization") or "")
        return authorization.split(" ", 1)[1] if authorization.startswith("Bearer ") else self._snapshot_token

    def pool_snapshot(self, now: dt.datetime) -> Mapping[str, Any] | None:
        """The queue janitor's newest trusted pool snapshot, or None when missing or stale (the pickers' read).

        One read serves every watch of this process for SNAPSHOT_CACHE_SECONDS (the janitor writes one every 10
        minutes, so a closer read finds the same one, and each read is two requests); each caller still judges its
        age at its own `now`."""
        with self._lock:
            cached = self._snapshot_cache
        if cached is not None and time.monotonic() - cached[0] < SNAPSHOT_CACHE_SECONDS:
            snapshot = cached[1]
        else:
            snapshot = pr_runner_pool.GitHub(self.snapshot_token(), self.repo).snapshot(now=now)
            with self._lock:
                self._snapshot_cache = (time.monotonic(), snapshot)
        if snapshot is None or pr_runner_pool.snapshot_problem(snapshot, now):
            return None
        return snapshot

    def code_shas(self, names: Sequence[str]) -> dict[str, str]:
        """The git blob shas of `names` in MAIN_BRANCH's scripts/ci (one request: the directory listing)."""
        listing = self.request("GET", f"/contents/{CODE_DIRECTORY}?ref={MAIN_BRANCH}")
        found = {str(item.get("name")): str(item.get("sha") or "") for item in listing or []
                 if isinstance(item, Mapping)}
        return {name: found.get(name, "") for name in names}

    def waiting_sweeper(self) -> int | None:
        """The id of a sweeper run other than this one that has not started yet (queued, or pending in the
        sweeper concurrency group), else None. One listing per status, made only at a handover."""
        for status in SWEEPER_WAITING_STATUSES:
            data = self.request("GET", f"/actions/workflows/{RESCUE_WORKFLOW_FILE}/runs?status={status}&per_page=100")
            for run in (data or {}).get("workflow_runs") or []:
                if (isinstance(run, Mapping) and str(run.get("display_title") or "") == SWEEPER_TITLE
                        and int(run.get("id") or 0) != self.own_run):
                    return int(run["id"])
        return None

    def dispatch_sweeper(self) -> None:
        """Start a sweeper on MAIN_BRANCH's code. It queues in the sweeper concurrency group until this one exits."""
        self.request("POST", f"/actions/workflows/{RESCUE_WORKFLOW_FILE}/" + "dispatches", own_token=True,
                     body={"ref": MAIN_BRANCH})

    def has_artifact(self, run_id: int, prefix: str, pages: int = 5) -> bool:
        """Whether the run uploaded an artifact whose name starts with `prefix`."""
        for page in range(1, pages + 1):
            data = self.request("GET", f"/actions/runs/{run_id}/artifacts?per_page=100&page={page}")
            names = [str(item.get("name") or "") for item in (data or {}).get("artifacts") or []]
            if any(name.startswith(prefix) for name in names):
                return True
            if len(names) < 100:
                return False
        return False

    def pull(self, number: int) -> Mapping[str, Any]:
        return self.request("GET", f"/pulls/{number}")

    def newer_unfinished_runs(self, path: str, run_id: int, branch: str) -> list[int]:
        """Ids of `path`'s runs on `branch` newer than `run_id` that wait behind it (one request).

        Pending runs only: nightly.yml's `full` group never cancels in
        progress, so a newer push, daily-schedule or full dispatch run waits
        there as `pending` while this run holds the group, and a re-run of this
        run would cancel it. The six-hourly cache seed runs in its own
        cancel-in-progress group and is never pending, so it does not count.
        (A seed-only or fast dispatch pending in its own group behind another
        of its kind still counts: a missed rescue, not a cancelled build.)
        """
        workflow = path.rsplit("/", 1)[-1]
        data = self.request("GET", f"/actions/workflows/{workflow}/runs?branch={branch}&per_page=20")
        return sorted(int(run.get("id") or 0) for run in (data or {}).get("workflow_runs") or []
                      if isinstance(run, Mapping) and int(run.get("id") or 0) > run_id
                      and run.get("status") == "pending")

    def newer_push_runs(self, path: str, run_id: int, branch: str) -> list[int]:
        """Ids of `path`'s push runs on `branch` newer than `run_id` and not cancelled (one request)."""
        workflow = path.rsplit("/", 1)[-1]
        data = self.request("GET", f"/actions/workflows/{workflow}/runs?branch={branch}&event=push&per_page=20")
        return sorted(int(run.get("id") or 0) for run in (data or {}).get("workflow_runs") or []
                      if isinstance(run, Mapping) and int(run.get("id") or 0) > run_id
                      and run.get("event") == "push" and run.get("conclusion") != "cancelled")

    def branch_head(self, branch: str) -> str:
        return str(((self.request("GET", f"/branches/{branch}") or {}).get("commit") or {}).get("sha") or "")

    def cancel(self, run_id: int, before_send: Callable[[], None] | None = None) -> None:
        """`before_send` runs right before the cancel is sent, after any token mint, and before every re-send
        after a rate-limit wait or a token refresh; it raises to drop the cancel (rescue(before_cancel=...))."""
        self.request("POST", f"/actions/runs/{run_id}/cancel", before_send=before_send)

    def force_cancel(self, run_id: int) -> None:
        self.request("POST", f"/actions/runs/{run_id}/force-cancel")

    def rerun(self, run_id: int, next_attempt: int) -> None:
        check = self._still_finished(run_id, next_attempt)
        self.request("POST", f"/actions/runs/{run_id}/rerun", before_retry=check, before_send=check)
        self.request_ui_tests(run_id, next_attempt)

    def rerun_job(self, run_id: int, job_id: int, next_attempt: int) -> None:
        """Re-run one job of a finished run and every job that needs it (one attempt more).

        The run is read again right before the send (and any re-send): the reads that chose this job may have
        waited out a rate limit while another watch re-ran the run."""
        self.request("POST", f"/actions/jobs/{job_id}/rerun", before_send=self._still_finished(run_id, next_attempt))

    def rerun_failed(self, run_id: int, next_attempt: int) -> None:
        check = self._still_finished(run_id, next_attempt)
        self.request("POST", f"/actions/runs/{run_id}/rerun-failed-jobs", before_retry=check, before_send=check)
        self.request_ui_tests(run_id, next_attempt)

    def _still_finished(self, run_id: int, next_attempt: int) -> Callable[[], None]:
        """A re-run sent (first, after a token mint, and again after a rate-limit wait) only while the run is still
        the finished attempt it re-runs.

        Two watches can own one failed attempt (a cmux-next `completed` event's and the sweeper's, or a sweeper
        mid-rescue and its successor picking up the same cancelled run): the other's re-run may have started, and
        even finished, since rescue() read the run, and sending this one then would start one attempt more than
        either meant.
        """
        def check() -> None:
            run = self.run(run_id) or {}
            attempt = int(run.get("run_attempt") or 0)
            if attempt != next_attempt - 1 or run.get("status") != "completed":
                raise Aborted(f"run {run_id} is at attempt {attempt} ({run.get('status') or 'unknown'}), not "
                              f"finished attempt {next_attempt - 1}; someone else already re-ran it, so it is not "
                              "re-run again")
        return check

    def request_ui_tests(self, run_id: int, attempt: int) -> None:
        """Start ci-ui-tests.yml for the attempt a re-run of a pull request's CI began.

        This token's re-run may emit no workflow_run event, and that attempt's
        ui-tests job waits for ci-ui-tests.yml (ui_tests_dispatch.rerun_dispatch()).
        Best effort: a failure here never stops the rescue.
        """
        try:
            run = self.request("GET", f"/actions/runs/{run_id}") or {}
            if run.get("path") != CI_WORKFLOW_PATH or run.get("event") != "pull_request":
                return
            # The caller's attempt: a read right after the re-run may still show the old one.
            path, body = ui_tests_dispatch.rerun_dispatch(run_id, attempt)
            self.request("POST", f"/{path}", body=body)
        except (urllib.error.URLError, OSError, ValueError) as error:
            print(f"::warning::could not start {ui_tests_dispatch.DISPATCH_WORKFLOW_FILE} for run {run_id}: {error}",
                  flush=True)


@dataclasses.dataclass
class Target:
    run_id: int
    attempt: int
    head_sha: str
    pr_number: int  # 0 for an E2E dispatch, which has no pull request
    e2e: bool = False  # a dispatch of DISPATCH_WORKFLOW_PATHS, watched as an E2E run
    path: str = CI_WORKFLOW_PATH
    # This attempt is a full re-run: `changes` runs again and picks a pool,
    # so it is watched the attempt-1 way (picker, then marker).
    full_rerun: bool = False
    side: bool = False  # a side-lane workflow (SIDE_WORKFLOW_PATHS): no picker job
    main: bool = False  # main's full-suite dispatch of ci.yml: no pull request, main's HEAD instead
    # A push or schedule run of nightly.yml on main (watched as a side lane,
    # against main's HEAD).
    nightly: bool = False
    # ci.yml started this watch because late-placement may move jobs onto owned
    # root runners after compile admission (LATE_PLACEMENT=1); the picker placed none.
    late: bool = False
    attempt_started_at: dt.datetime | None = None
    # A side lane's push run: its branch. Push runs of a side lane may each hold
    # their own concurrency group, so a newer push does not cancel this one.
    push_branch: str = ""
    # cmux-next's bot attempt 3 (REFUSAL_RESCUE_ATTEMPT): still on the minis, so a
    # refusal there goes to Blacksmith as attempt 4; a long queue is not moved.
    refusals_only: bool = False
    # The run's event (pull_request, push, schedule, ...); "" when unread, which never_fails_over() treats as a
    # delivery event.
    event: str = ""

    @property
    def picker_job(self) -> str:
        return E2E_PICKER_JOB if self.e2e else PICKER_JOB

    @property
    def late_owned_jobs(self) -> bool:
        """nightly-next's nightly.yml puts prepare-nightly-variant on the side label after the app build."""
        return self.nightly and self.push_branch == "nightly-next"

    @property
    def signs_late(self) -> bool:
        """A nightly on either branch: its sign, verify and DMG jobs (NIGHTLY_SIGN_ALTERNATES) appear only once the
        app build finishes and can stall on Blacksmith macOS then (signing_stall()). Main's is rescued on attempt 1
        only (sweep_target() never adopts its later attempts unless they are its own re-runs)."""
        return self.nightly and (self.push_branch == "nightly-next" or self.attempt == 1)

    @property
    def watch_limit(self) -> int:
        # Every nightly is watched until its run finishes, within this limit: its app build's 90-minute timeout
        # can only be seen once it fires (feed_timeouts()).
        if self.nightly:
            return NIGHTLY_WATCH_LIMIT_SECONDS
        if self.side:
            return SIDE_WATCH_LIMIT_SECONDS
        return E2E_WATCH_LIMIT_SECONDS if self.e2e else WATCH_LIMIT_SECONDS


def target_from_event(event: Mapping[str, Any], repository: str) -> Target | str:
    """The CI, E2E, iOS or nightly run to watch, or why this event is not one."""
    run = event.get("workflow_run") or {}
    path = run.get("path")
    if path == NIGHTLY_WORKFLOW_PATH:
        return nightly_target(run, repository)
    side = path in SIDE_WORKFLOW_PATHS
    if path != CI_WORKFLOW_PATH and path not in DISPATCH_WORKFLOW_PATHS and not side:
        return (f"started by {path or 'an unknown workflow'}, not {CI_WORKFLOW_PATH}, {NIGHTLY_WORKFLOW_PATH}, "
                f"a side-lane workflow or one of {', '.join(DISPATCH_WORKFLOW_PATHS)}")
    e2e = path in DISPATCH_WORKFLOW_PATHS
    attempt_started = parse_time(run.get("run_started_at") or run.get("created_at"))
    on_main = (path == CI_WORKFLOW_PATH and run.get("event") == "workflow_dispatch"
            and run.get("head_branch") == MAIN_BRANCH)
    # test-ios.yml also runs for pull requests: watched as an E2E run, but
    # against its pull request's head like a CI run.
    ios_pull = path in (IOS_TEST_WORKFLOW_PATH, IOS_KIT_WORKFLOW_PATH) and run.get("event") == "pull_request"
    kit_push = path == IOS_KIT_WORKFLOW_PATH and run.get("event") == "push"
    expected = "workflow_dispatch" if e2e else "pull_request"
    # A side lane's trusted non-PR run (push, schedule, dispatch) is watched too.
    side_trusted = side and run.get("event") in TRUSTED_SIDE_EVENTS
    if run.get("event") != expected and not on_main and not ios_pull and not kit_push and not side_trusted:
        what = f"{expected} or a dispatch on {MAIN_BRANCH}" if path == CI_WORKFLOW_PATH else expected
        return f"a {run.get('event') or 'unknown'} run of {path}, not a {what}"
    head = (run.get("head_repository") or {}).get("full_name") or ""
    if head.casefold() != repository.casefold():
        return "a fork head; forks never take a persistent pool"
    attempt = int(run.get("run_attempt") or 0)
    if attempt != 1:
        return f"attempt {attempt}; its first attempt's watch follows it"
    if e2e and not ios_pull:
        return Target(int(run["id"]), attempt, str(run.get("head_sha") or ""), 0, e2e=True,
                      path=str(path), attempt_started_at=attempt_started, event=str(run.get("event") or ""))
    if on_main:
        return Target(int(run["id"]), attempt, str(run.get("head_sha") or ""), 0, path=str(path), main=True,
                      attempt_started_at=attempt_started, event=str(run.get("event") or ""))
    if side_trusted:
        # No pull request: no head to re-check (pull_moved), like a dispatch.
        push_branch = str(run.get("head_branch") or "") if run.get("event") == "push" else ""
        return Target(int(run["id"]), attempt, str(run.get("head_sha") or ""), 0, side=True, path=str(path),
                      attempt_started_at=attempt_started, push_branch=push_branch, event=str(run.get("event") or ""))
    pulls = [pr for pr in run.get("pull_requests") or [] if isinstance(pr, Mapping) and pr.get("number")]
    if len(pulls) != 1:
        return "the run does not name exactly one pull request"
    return Target(int(run["id"]), attempt, str(run.get("head_sha") or ""), int(pulls[0]["number"]),
                  e2e=e2e, side=side, path=str(path), attempt_started_at=attempt_started,
                  event=str(run.get("event") or ""))


def completed_target(event: Mapping[str, Any], repository: str) -> Target | str:
    """A cmux-next run that finished red (workflow_run `completed`): the attempt that failed, any attempt.

    ci-owned-pool-rescue.yml wakes on a failed DEV daily dispatch or feat-cmux-next push of cmux-next.yml,
    so a refused DEV compile gets its own watch instead of waiting for the sweeper, whose listings run
    out of the hour's API budget. The attempt is resolved the sweeper's way (sweep_target()): a bot attempt
    3 is refusals only, and a bot attempt past it is on Blacksmith and left alone.
    """
    run = event.get("workflow_run") or {}
    if run.get("path") != CMUX_NEXT_WORKFLOW_PATH:
        return (f"a finished run of {run.get('path') or 'an unknown workflow'}; only {CMUX_NEXT_WORKFLOW_PATH} "
                "wakes a rescue when it finishes")
    return sweep_target(run, repository, late=False)


def nightly_target(run: Mapping[str, Any], repository: str) -> Target | str:
    """Attempt 1 of main push/schedule or nightly-next push/dispatch, from this repository.

    The sweeper resumes a later attempt of a marked nightly-next run (sweep_target(), owned_rerun())."""
    next_run = run.get("head_branch") == "nightly-next"
    if run.get("event") not in (NIGHTLY_NEXT_EVENTS if next_run else NIGHTLY_EVENTS):
        return (f"a {run.get('event') or 'unknown'} run of {NIGHTLY_WORKFLOW_PATH}, not a "
                + ("push or dispatch" if next_run else "push or schedule"))
    if run.get("head_branch") not in (MAIN_BRANCH, "nightly-next"):
        return f"a run of {NIGHTLY_WORKFLOW_PATH} on {run.get('head_branch') or 'an unknown branch'}, not a trusted nightly event"
    head = (run.get("head_repository") or {}).get("full_name") or ""
    if head.casefold() != repository.casefold():
        return "a fork head; forks never take a persistent pool"
    attempt = int(run.get("run_attempt") or 0)
    if attempt != 1:
        return f"attempt {attempt}; its first attempt's watch follows it"
    return Target(int(run["id"]), attempt, str(run.get("head_sha") or ""), 0, path=NIGHTLY_WORKFLOW_PATH,
                  side=True, nightly=True, push_branch=str(run["head_branch"]), event=str(run.get("event") or ""))


def marker_name(target: Target) -> str:
    """The marker's name up to its jobs and pool, which only the janitor reads."""
    return f"{MARKER_PREFIX}-{target.run_id}-{target.attempt}-"


def late_marker_name(target: Target) -> str:
    """The marker late-placement uploads when it moved jobs onto owned root runners."""
    return f"{LATE_MARKER_PREFIX}-{target.run_id}-{target.attempt}"


READ_ERRORS = (urllib.error.URLError, http.client.HTTPException, OSError, ValueError)


def read(call: Callable[[], Any], sleep: Callable[[float], None], log: Callable[[str], None]) -> Any:
    """A GET, retried: one transient error must not end the watch it exists for."""
    for attempt in range(1, READ_ATTEMPTS + 1):
        try:
            return call()
        except READ_ERRORS as error:
            if attempt == READ_ATTEMPTS:
                raise
            log(f"read failed ({error}); retrying")
            sleep(READ_RETRY_SECONDS * attempt)
    raise AssertionError("unreachable")


def watch(api: GitHub, target: Target, *, budget_seconds: int,
          now: Callable[[], dt.datetime], sleep: Callable[[float], None],
          log: Callable[[str], None], deadline: dt.datetime | None = None,
          floor_seconds: int | None = None, seen: dict[Any, dt.datetime] | None = None,
          sign_seen: dict[Any, dt.datetime] | None = None,
          sign_text: list[str | None] | None = None) -> tuple[str, str]:
    """Watch until a stop, a rescue or `deadline`. Returns (outcome, reason).

    `sign_seen` and `sign_text` (when each signing job was first seen queued, and the run's workflow file once
    read) carry over from an earlier watch of the same attempt (follow()), so a stall keeps counting.

    A job's budget is cut to end before `deadline`, never below
    `floor_seconds` (job_budget()). `seen` (when each job was first seen
    queued) carries over from an earlier watch of the same attempt, so a
    held job's wait keeps counting (hold_for_destination()).

    One deadline covers every attempt a job watches (main()), so attempt 2
    cannot stretch the job past its timeout.
    """
    if deadline is None:
        deadline = now() + dt.timedelta(seconds=target.watch_limit)
    sleep(FIRST_LOOK_SECONDS)
    looks = 0
    on_persistent = False
    picker_marker: bool | None = None
    first_seen: dict[Any, dt.datetime] = {} if seen is None else seen
    sign_seen = {} if sign_seen is None else sign_seen
    sign_said = ""
    sign_text = [] if sign_text is None else sign_text  # the run's workflow file, read once a signing job stalls
    failover_at: dt.datetime | None = None  # the next look that may offer a decided run the open-head failover
    while True:
        looks += 1
        jobs = read(lambda: api.jobs(target.run_id, target.attempt), sleep, log)
        if target.signs_late and target.attempt <= SIGN_RESCUE_LAST_ATTEMPT:
            # A nightly's signing jobs on a stalled Blacksmith macOS label (signing_stall()).
            seen_at = now()
            for job in jobs:
                if sign_job_key(job) and waiting_for_runner(job):
                    sign_seen.setdefault(job.get("id"), seen_at)
            stall = signing_stall(jobs, seen_at, sign_seen)
            if stall is not None and stall.action == "stalled":
                if not sign_text:
                    try:
                        sign_text.append(read(lambda: api.workflow_file(target.path, target.head_sha), sleep, log))
                    except READ_ERRORS as error:
                        log(f"could not read {target.path} at {target.head_sha[:12]} ({error})")
                        sign_text.append(None)
                stall = gated_signing_stall(jobs, seen_at, sign_seen, sign_text[0])
                if stall is not None and stall.action == "stalled":
                    log(f"look {looks}: {stall.reason}")
                    return "stalled", stall.reason
            if stall is not None and stall.reason != sign_said:
                sign_said = stall.reason
                log(f"look {looks}: {stall.reason}")
        if not on_persistent and target.side:
            # No picker: a job that asks for an owned label is the choice. A
            # gated job (cloud-machine-tests) appears once its Linux gate ends.
            if any(job_pool(job) for job in jobs):
                on_persistent = True
                log("a side-lane job asked for a persistent pool")
            elif target.late_owned_jobs and target.attempt > SIGN_RESCUE_LAST_ATTEMPT and nightly_build_off_owned(
                    jobs, target.attempt_started_at):
                # Nothing left to rescue on this attempt: its signing stalls are not rescued past
                # SIGN_RESCUE_LAST_ATTEMPT, and no job of it can take an owned pool (nightly_reruns() lists every
                # attempt).
                return "stop", f"no job of attempt {target.attempt} can take a persistent pool"
            elif run_finished(jobs) and not (target.signs_late and read(
                    lambda: api.run(target.run_id), sleep, log).get("status") != "completed"):
                # A nightly's signing jobs appear only once the jobs they need finish (signing_stall()), so
                # its watch ends with the run, not with the jobs listed so far.
                return "stop", "no job of the run asked for a persistent pool"
            elif not jobs and read(lambda: api.run(target.run_id), sleep, log).get("status") == "completed":
                # A pending run cancelled before any job (a newer nightly took its place).
                return "stop", "the run finished with no job"
        elif not on_persistent and target.attempt > 1 and not target.full_rerun:
            # A re-run of failed jobs: no `changes` job, no marker. Follow it
            # if a job asks for an owned pool. When it runs compile admission
            # again, late-placement runs after it and may move the jobs after
            # admission onto one, so its marker decides; otherwise the first
            # look that lists jobs does.
            late = next((job for job in jobs if job.get("name") == LATE_JOB
                         and not carried(job, target.attempt_started_at)), None)
            if any(job_pool(job) for job in jobs):
                on_persistent = True
                log("a re-run job asked for a persistent pool")
            elif late is not None and late.get("status") == "completed":
                if late.get("conclusion") != "success" or not read(
                        lambda: api.has_artifact(target.run_id, late_marker_name(target)), sleep, log):
                    return "stop", "late placement moved no job onto a persistent pool"
                log("late placement moved jobs onto a persistent pool")
                on_persistent = True
            elif jobs and (run_finished(jobs) or late is None and not any(
                    job.get("name") == ADMISSION_JOB and not carried(job, target.attempt_started_at) for job in jobs)):
                return "stop", "no job of this attempt asked for a persistent pool"
        elif not on_persistent:
            if picker_finished(jobs, target.picker_job):
                if picker_marker is None:
                    picker_marker = bool(read(lambda: api.has_artifact(target.run_id, marker_name(target)),
                                              sleep, log))
                if picker_marker:
                    log("the picker chose a persistent pool")
                    on_persistent = True
                elif not target.late:
                    return "stop", "the run is on an ephemeral pool"
                elif picker_finished(jobs, LATE_JOB):
                    if not read(lambda: api.has_artifact(target.run_id, late_marker_name(target)), sleep, log):
                        return "stop", "late placement moved no job onto a persistent pool"
                    log("late placement moved jobs onto a persistent pool")
                    on_persistent = True
                elif run_finished(jobs):
                    return "stop", "the run finished on an ephemeral pool"
            elif run_finished(jobs):
                return "stop", "the run finished before the pool choice"
        # Waiting for compile admission and late placement: nothing can be stuck yet.
        interval = POLL_SECONDS if on_persistent or picker_marker is None else IDLE_POLL_SECONDS
        if on_persistent:
            run = read(lambda: api.run(target.run_id), sleep, log) if run_finished(jobs) else {}
            finished = run.get("status") == "completed"
            # A job no runner acquired looks like one a cancelled run left queued (unacquired()).
            stranded = finished and run.get("conclusion") not in (None, "cancelled")
            if finished and run.get("conclusion") == "cancelled" and int(run.get("run_attempt") or 0) == target.attempt:
                # Someone's cancel is final, whatever its jobs show (a refusal, a timeout): only a rescue's own
                # cancel whose re-run never came (rerun_intended()) is re-run here, as a stranded run.
                by = canceller(api, jobs, sleep, log)
                if by is None:
                    return "stop", "the run was cancelled, and who cancelled it could not be read; left cancelled"
                meant = rerun_intended(api, run, target.attempt, sleep, log) if by in RESCUE_ACTORS else ""
                if by and not meant:
                    return "stop", f"the run was cancelled by @{by}; left cancelled"
                if meant:
                    # Whatever its jobs show (queued ones no runner took, or one held in a runner's setup).
                    log(f"look {looks}: the rescue cancelled attempt {target.attempt} to re-run "
                        f"{'every job' if meant == 'all' else f'job {meant[4:]}' if meant.startswith('job:') else 'its failed jobs'} "
                        "and stopped before the re-run")
                    return "resume", meant
            if finished and not any(refused(job) or stranded and unacquired(job) for job in jobs):
                late = feed_timeouts(api, target, jobs, sleep, log)
                if not late:
                    return "stop", "the run finished"
                pool = next((job_pool(job) for job in jobs if str(job.get("name")) in late and job_pool(job)), "")
                reason = (f"{', '.join(late)} timed out on {pool} (its timeout counts a slow or busy owned "
                          "runner's setup and checkout); a started feed build is never left cancelled")
                log(f"look {looks}: {reason}")
                return "refused", reason
            seen_at = now()
            for job in jobs:
                if job_pool(job) and waiting_for_runner(job):
                    first_seen.setdefault(job.get("id"), seen_at)
            look = assess(jobs, now=seen_at, budget_seconds=budget_seconds, first_seen=first_seen,
                          deadline=deadline, floor_seconds=floor_seconds,
                          allow_running_rescue=target.path == CMUX_NEXT_WORKFLOW_PATH,
                          # Main, nightly and push runs keep the rescue: a stuck one holds its
                          # concurrency group, and rescue() cancels it once its head has moved.
                          leave_decided=bool(target.pr_number) and not (
                              target.main or target.nightly or target.push_branch),
                          attempt_started_at=target.attempt_started_at,
                          reserved=target.nightly, stranded=stranded)
            # The open-head failover's offer comes first, before every branch below that waits or returns: the
            # refusal wait (a refused sibling of a run that also failed on its own is never re-run by the refusal
            # path, follow()), and the "rescue" and "refused" returns (a hold for a Blacksmith slot re-watches and
            # would return before an offer placed after them). A job left queued is offered the failover every
            # FAILOVER_LOOK_SECONDS, whatever kept the queue rescue off: a red job of the attempt (a full re-run
            # would repeat it, but the placement or settled re-run keeps its result), a refusals-only watch (it
            # looked once, at its first queue alarm) or a hold for a Blacksmith slot. Its label runs nothing, so it
            # waits for no turn (open_head_failover()). Runs 40993742146 and 41013458526 (2026-10-30) waited hours
            # behind a red `checks` with the failover never looked at. A refusal with no failure of its own keeps
            # the refusal path, whose re-run of failed jobs brings back the refused job too.
            offer = look.waiting or look.action == "rescue" or (
                look.action == "refused" and bool(decided_failures(jobs, target.attempt_started_at)))
            if offer and target.pr_number and not finished and (failover_at is None or seen_at >= failover_at) \
                    and any(mac_route(job) and waiting_for_runner(job)
                            and queued_seconds(job, seen_at, first_seen.get(job.get("id"))) >= UNSTARTED_STALL_SECONDS
                            for job in jobs):
                failover_at = seen_at + dt.timedelta(seconds=FAILOVER_LOOK_SECONDS)
                why = open_head_failover(api, target, now=now, sleep=sleep, log=log, first_seen=first_seen).why
                if why:
                    return "failover", why
            if look.action == "refused" and not finished and seen_at < deadline and not target.main:
                # GitHub re-runs no job of a run still in progress (403 "already
                # running", for one job or the failed ones), and cancelling
                # the run to re-run it killed every healthy sibling (run
                # 36198335113: two refused app-host shards cost five running
                # shards and the CLI product tests, all re-run on Blacksmith).
                # Let the siblings finish; at the deadline, cancel as before.
                # Main's run still cancels at once: a run that ends in failure
                # makes ci-main-full-suite.yml open the red-CI issue before
                # the re-run starts, and a cancelled one does not.
                log(f"look {looks}: {look.reason}; waiting for the rest of the run to finish")
                wait = IDLE_POLL_SECONDS
                if getattr(api, "pace", None) is not None:
                    # Never sleeps past the deadline's look by more than a second.
                    wait = min(api.pace(wait), max(1.0, (deadline - now()).total_seconds() + 1))
                sleep(wait)
                continue
            if look.action == "refused" and not finished and target.nightly and any(
                    job.get("status") == "in_progress" for job in jobs):
                # At the watch's end a refusal in a nightly whose other jobs still run is left as it is:
                # cancelling it to re-run would kill started nightly work. The nightly-next tick re-runs a
                # failed tip, and the next nightly builds main.
                log(f"::warning::look {looks}: {look.reason}; the nightly still runs other jobs at the watch "
                    "limit, so it is not cancelled")
                return "stop", "watch limit reached with a started nightly still running"
            log(f"look {looks}: {look.reason}")
            if look.action in ("rescue", "refused"):
                return look.action, look.reason
            if not look.waiting:
                interval = IDLE_POLL_SECONDS
                owned = [job for job in jobs if job_pool(job)]
                # A re-run that runs its own admission (a full one, or a re-run
                # of a failed admission) makes its shards only after that
                # admission, so its watch goes on until the run finishes.
                own_admission = any(job.get("name") == ADMISSION_JOB
                                    and not carried(job, target.attempt_started_at) for job in jobs)
                if (target.attempt > 1 and not target.full_rerun and not target.nightly and not own_admission
                        and owned and all(accepted(job, seen_at) for job in owned)):
                    # The fleet took the retry; later attempts never come back to it. Not a nightly's: its
                    # sign and verify jobs can still stall on Blacksmith after its owned jobs are accepted,
                    # and the signing rescue needs the watch to last until then.
                    return "stop", "the fleet accepted the retry"
                if target.side and not target.nightly and owned \
                        and all(accepted(job, seen_at) for job in owned):
                    # A side lane's jobs are all created by now, and none can be refused any more.
                    # Not nightly-next's: prepare-nightly-variant takes the side label only once
                    # build-nightly-app has finished, and its runner can refuse it then
                    # (run 40144317744), so that watch lasts until the run finishes. Main's neither: an
                    # accepted app build can still time out, which feed_timeouts() re-runs.
                    return "stop", "the fleet accepted the side-lane jobs"
        if now() >= deadline:
            if target.nightly:
                # Never moved (assess(reserved=True)); say so, without claiming why it did not start.
                for job in jobs:
                    runner = reserved_runner(job)
                    if runner and job_pool(job) and (waiting_for_runner(job) or in_setup(job)):
                        log(f"::warning::{job.get('name') or job.get('id')} was still waiting for its reserved "
                            f"runner {runner} at the watch limit")
            return "stop", "watch limit reached"
        pace = getattr(api, "pace", None)
        if pace is not None:
            # A spent budget waits for its reset, but never past the deadline's look.
            interval = min(pace(interval), max(1.0, (deadline - now()).total_seconds() + 1))
        sleep(interval)


# How often a run held off a stalled Blacksmith label looks at the janitor's snapshot again; the janitor
# writes one every 10 minutes (ci-queue-janitor.yml), so a closer look would read the same one.
STALL_RECHECK_SECONDS = 5 * 60
# How often watch() offers a pull request run with a job left queued the open-head failover.
FAILOVER_LOOK_SECONDS = 2 * 60


def hold_for_destination(client: GitHub, target: Target, outcome: str, reason: str, *, budget_seconds: int,
                         floor_seconds: int | None, deadline: dt.datetime, now: Callable[[], dt.datetime],
                         sleep: Callable[[float], None], log: Callable[[str], None],
                         seen: dict[Any, dt.datetime], sign_seen: dict[Any, dt.datetime] | None = None,
                         sign_text: list[str | None] | None = None) -> tuple[str, str, str]:
    """Keep a queue rescue off a Blacksmith label with no room: returns (outcome, reason, held).

    `sign_seen` and `sign_text` go to its watch() so a signing stall (signing_stall()) found while held keeps
    the times follow() rescues it by.

    The re-run of a rescued run takes its workflow's Blacksmith retry label (move_verdict()). While that
    label is stalled the run stays queued on its owned pool, however long, until the label moves, a
    refusal, the run's end or the watch limit; while it is busy, the job moves only after
    OWNED_WAIT_FLOOR_SECONDS. A nightly is the exception: its hold on a stalled label ends after
    NIGHTLY_HOLD_SECONDS or at the watch limit, and the job moves (its re-run's label read from its picker's
    log where it can be, nightly_retry_destinations()). Re-picking another owned pool is no option here: a re-run never takes an
    owned label in the workflows this moves (cmux-next-dev-daily.yml's verify runs on its picker's label
    only on attempt 1), and a cancel would lose the job's place in the owned queue for a Blacksmith one.
    """
    held = ""
    held_since: dt.datetime | None = None
    current, floor = budget_seconds, floor_seconds
    while outcome == "rescue":
        # A re-run the picker places again takes the owned machines free now first: nothing to hold.
        if repicks(target):
            break
        # A run whose head moved is only cancelled, never re-run (rescue()), so nothing moves to Blacksmith.
        if pull_moved(client, target, sleep, log):
            break
        # assess() reports a stuck job before a refusal; a refused job needs its re-run whatever the queue.
        turned_away = [job for job in read(lambda: client.jobs(target.run_id, target.attempt), sleep, log)
                       if refused(job)]
        if turned_away:
            # The refusal path re-runs the failed jobs whether or not the run has finished by the time
            # rescue() reads it (a queued sibling may still run meanwhile); a queue rescue would skip a
            # finished run. A ci.yml attempt-1 full re-run never gets here (repicks(), above).
            names = ", ".join(sorted(str(job.get("name") or job.get("id")) for job in turned_away))
            return "refused", f"{names} refused by {job_pool(turned_away[0])} at job start", held
        if held and now() >= deadline:
            if nightly_moves(target):
                # NIGHTLY_HOLD_SECONDS: a held nightly job is moved at the watch limit, never left queued.
                log(f"moving the held nightly job at the watch limit: {held}")
                break
            # watch() reports a stuck job before its deadline check, so the hold ends here (after the
            # refusal look above, so a refusal on the last look still gets its re-run).
            return "stop", "watch limit reached", held
        verdict, label = move_verdict(client, target, now=now(), sleep=sleep, log=log)
        if verdict == "free" or verdict == "busy" and floor is not None and floor >= OWNED_WAIT_FLOOR_SECONDS:
            break
        if verdict == "stalled" and nightly_moves(target):
            held_since = held_since or now()
            if now() - held_since >= dt.timedelta(seconds=NIGHTLY_HOLD_SECONDS):
                log(f"moving the held nightly job: no mini took it in {NIGHTLY_HOLD_SECONDS}s past its budget, "
                    f"though the re-run takes {label}, which is stalled")
                break
        if verdict == "stalled":
            held = f"{label} is stalled (simple_pool_picker.blacksmith_stalled())"
            log(f"held on the owned pool: {reason}, but the re-run would take {held}; "
                f"looking again in {STALL_RECHECK_SECONDS}s")
            sleep(STALL_RECHECK_SECONDS)
        else:
            held = f"{label} has no free slot"
            log(f"held on the owned pool: {reason}, but the re-run would take {label}, which has no free slot; "
                f"moving only after {OWNED_WAIT_FLOOR_SECONDS}s")
        # The floor too: job_budget() cuts a budget short near the deadline, but never below its floor, so a
        # job moves onto a busy label only after it has really waited OWNED_WAIT_FLOOR_SECONDS.
        current = max(budget_seconds, OWNED_WAIT_FLOOR_SECONDS)
        floor = OWNED_WAIT_FLOOR_SECONDS
        outcome, reason = watch(client, target, budget_seconds=current, now=now, sleep=sleep, log=log,
                                deadline=deadline, floor_seconds=floor, seen=seen, sign_seen=sign_seen,
                                sign_text=sign_text)
    return outcome, reason, held


def bot_rerun_leaves_owned(path: str, attempt: int) -> bool:
    """Whether a bot's re-run of failed jobs of `attempt` sends a leg queued on an owned label elsewhere.

    queue_janitor.py's unclaimed-leg rule cancels a run whose owned leg no runner claimed within its bound
    and later re-runs its failed jobs (rerun-failed-jobs), so it acts only where that re-run is a rescue,
    as next_attempt() describes the routes:
    - a side lane other than cmux-next takes its Blacksmith default from attempt 2 on (cmux-tui.yml's
      macOS legs read `github.run_attempt == 1 && vars.CI_SIDE_LANE_RUNNER || 'blacksmith-...-macos-...'`);
    - cmux-next keeps the minis through REFUSAL_RESCUE_ATTEMPT and takes Blacksmith after it;
    - ci.yml's re-run of failed jobs reuses attempt 1's placement through LAST_OWNED_ATTEMPT;
    - test-ios.yml, ios-screenshots.yml, iroh-release-gate.yml and cmux-next-dev-daily.yml take their retry
      route from attempt 2;
      test-e2e.yml does not count, since a UI run's retry_label stays on its owned pool and the path alone
      cannot tell one apart;
    - the base and PR autofix's Mac exports (OWNED_EVERY_ATTEMPT_PATHS) keep their owned label on every
      attempt, so a re-run only rejoins the queue;
    - nightly, the UNRESCUED_WORKFLOW_PATHS and any workflow not watched here are a person's call.
    """
    following = attempt + 1
    if path in OWNED_EVERY_ATTEMPT_PATHS:
        return False
    if path == CMUX_NEXT_WORKFLOW_PATH:
        return following > REFUSAL_RESCUE_ATTEMPT
    if path == CI_WORKFLOW_PATH:
        return following > LAST_OWNED_ATTEMPT
    if path in DISPATCH_WORKFLOW_PATHS:
        return path != E2E_WORKFLOW_PATH and following > 1
    return path in SIDE_WORKFLOW_PATHS and following > 1


# A queue rescue never moves a job onto a Blacksmith label blacksmith_stalled() names, and moves one onto a
# label without a free slot only after the job has waited this long: the same 10 minutes after which the
# pickers call a Blacksmith queue stalled (simple_pool_picker.BLACKSMITH_STALL_MINUTES). Run 40466780519
# (DEV daily, 2026-10-27): the picker put verify and tip-dmg-build on the owned pool because
# blacksmith-6vcpu-macos-26 was stalled, and 53 s later this rescue moved both onto that label, where they
# queued 23 minutes.
OWNED_WAIT_FLOOR_SECONDS = simple_pool_picker.BLACKSMITH_STALL_MINUTES * 60
# A Blacksmith macOS label a workflow names, and a retry route a picker job computes (ci.yml's
# macos_pr_retry_runner, test-ios.yml's retry_runs_on), which may be any picker label.
BLACKSMITH_MACOS_LABEL = re.compile(r"blacksmith-[0-9]+vcpu-macos-[0-9]+")
PICKED_RETRY = re.compile(r"\boutputs\.[A-Za-z0-9_-]*retry[A-Za-z0-9_-]*")


def retry_labels(workflow_text: str | None) -> set[str]:
    """The picker Blacksmith labels a re-run of the workflow may take, as far as its file shows.

    Every picker label the file names anywhere counts: runs-on fallbacks, matrix entries, and the inputs it
    passes a reusable workflow (cmux-tui.yml's macos_retry_runner). A file that names none, cannot be
    read, or routes a retry through a picker job's output (PICKED_RETRY) may route anywhere, so every
    picker label counts, and the rescue judges the worst of them (move_verdict())."""
    every = set(simple_pool_picker.BLACKSMITH)
    if PICKED_RETRY.search(workflow_text or ""):
        return every
    found = set(BLACKSMITH_MACOS_LABEL.findall(workflow_text or "")) & every
    return found or every


def blacksmith_states(snapshot: Mapping[str, Any], now: dt.datetime) -> dict[str, str]:
    """Each picker Blacksmith label's state in the janitor snapshot: "stalled" (simple_pool_picker.stalled(),
    the pickers' rule), "free" (a slot free and nothing queued) or "busy"."""
    pools = snapshot.get("pools") if isinstance(snapshot.get("pools"), Mapping) else {}
    age = max(0.0, pr_runner_pool.snapshot_age_minutes(snapshot, now) or 0.0)

    def count(entry: Any, key: str) -> int:
        try:
            return max(0, int(entry.get(key, 0))) if isinstance(entry, Mapping) else 0
        except (TypeError, ValueError):
            return 0

    states: dict[str, str] = {}
    for label in simple_pool_picker.BLACKSMITH:
        entry = pools.get(label) or {}
        queued, running = count(entry, "queued"), count(entry, "running")
        if simple_pool_picker.stalled(queued, running, count(entry, "oldest_queued_minutes"), age):
            states[label] = "stalled"
        elif queued == 0 and running < simple_pool_picker.CAPACITY[label]:
            states[label] = "free"
        else:
            states[label] = "busy"
    return states


def repicks(target: Target) -> bool:
    """Whether the rescue's re-run picks a pool again (ci.yml's attempt 2: owned machines free now first)
    rather than taking a fixed Blacksmith retry label."""
    return target.path == CI_WORKFLOW_PATH and not target.e2e and target.attempt + 1 <= LAST_OWNED_ATTEMPT


# nightly-next's owned jobs and where a re-run of failed jobs sends each (nightly.yml on feat-cmux-next): the
# Blacksmith label its picker job chose on the earlier attempt, which the re-run keeps, as that picker's log
# prints it. build-nightly-app and the Ghostty helper read pick-nightly-build-runner's `blacksmith`
# ("nightly build runner: blacksmith: <label> (why)"); the secret-free verify jobs read pick-nightly-sign-runner's
# `alternate` ("nightly sign runner: ...; a re-run takes `<label>`"). Until 2026-10-27 the rescue judged every
# Blacksmith label the workflow file names (retry_labels()), so a stalled label no re-run would take held an
# owned nightly job queued while the label its re-run takes had room.
NIGHTLY_RETRY_SOURCES: tuple[tuple[str, str, re.Pattern[str]], ...] = (
    ("build-nightly-app", "pick-nightly-build-runner",
     re.compile(r"nightly build runner: blacksmith: (blacksmith-[0-9]+vcpu-macos-[0-9]+) ")),
    ("build-nightly-ghostty-cli-helper", "pick-nightly-build-runner",
     re.compile(r"nightly build runner: blacksmith: (blacksmith-[0-9]+vcpu-macos-[0-9]+) ")),
    *((name, "pick-nightly-sign-runner",
       re.compile(r"nightly sign runner: .*a re-run takes `(blacksmith-[0-9]+vcpu-macos-[0-9]+)`"))
      for name in ("Verify signed nightly app", "Verify final nightly DMG", "signer-dmg-image", "signer-verify")),
    # The cmux NIGHTLY-identity lane: attempt 1 may sign on pick-nightly-sign-runner's `sign_owned`; a re-run takes
    # legacy-identity-target's `sign_alternate`, which that job's own nightly_sign_runner.py step prints.
    *((name, "legacy-identity-target",
       re.compile(r"nightly sign runner: .*a re-run takes `(blacksmith-[0-9]+vcpu-macos-[0-9]+)`"))
      for name in ("sign-nightly-identity-legacy", "verify-nightly-identity-legacy")),
)
# The picker lines NIGHTLY_RETRY_SOURCES reads (GitHub.job_log_lines() keeps only these).
NIGHTLY_RETRY_LINE = re.compile(r"nightly (?:build|sign) runner: ")
# How long an owned nightly job is held while the label its re-run takes is stalled, after its queue budget:
# two Blacksmith stall windows. Past it the job moves anyway: no mini took it, and a nightly never waits on one
# label with no fallback (Leo, 2026-10-27: "a waiting nightly ... job is admitted on a mini ahead of every PR,
# DEV and side job"; the routing order ends at Blacksmith). The same holds at the watch limit: a held nightly
# job is moved, not left queued.
NIGHTLY_HOLD_SECONDS = 2 * OWNED_WAIT_FLOOR_SECONDS
# The last nightly attempt the stall hold moves off its owned pool (nightly_moves()). Each move re-runs the build
# picker (rerun_failed_or_repick()), which, while every Blacksmith label stays stalled, queues the next attempt on
# the owned pool again. From this attempt on a nightly waits there the way other targets do: held while the label
# its re-run takes is stalled, moved once it has room, and otherwise left queued on its owned pool at the watch
# limit, where a mini takes it. That bounds the re-runs (review on #28019) without sending it to a stalled label.
NIGHTLY_LAST_MOVE_ATTEMPT = 5


# nightly-next's picker jobs. Every owned runs-on in nightly.yml takes a picker's `owned` (or `sign_owned`) only
# when that picker ran on the run's own attempt (`outputs.attempt == github.run_attempt`, or attempt 1).
NIGHTLY_PICKER_JOBS = ("pick-nightly-build-runner", "pick-nightly-sign-runner")


def nightly_build_off_owned(jobs: Sequence[Mapping[str, Any]], attempt_started: dt.datetime | None) -> bool:
    """Whether no job of this nightly-next attempt can ask for an owned pool: both picker jobs are listed and both
    were kept from an earlier attempt (a re-run of failed jobs), so every owned runs-on falls through to its
    Blacksmith label. A picker that runs on this attempt, or one not listed yet, keeps the watch going: the jobs
    after it (the app build, prepare and verify jobs) may still take an owned pool once they appear."""
    pickers = {name: [job for job in jobs if job.get("name") == name] for name in NIGHTLY_PICKER_JOBS}
    return all(found and all(carried(job, attempt_started) for job in found) for found in pickers.values())


def nightly_moves(target: "Target") -> bool:
    """Whether the stall hold moves this nightly after NIGHTLY_HOLD_SECONDS or at the watch limit."""
    return target.nightly and target.attempt < NIGHTLY_LAST_MOVE_ATTEMPT


def nightly_retry_destinations(api: GitHub, target: Target, sleep: Callable[[float], None],
                               log: Callable[[str], None]) -> set[str] | None:
    """The Blacksmith labels a re-run of failed jobs sends nightly-next's owned jobs waiting now to, read from
    their picker jobs' logs (NIGHTLY_RETRY_SOURCES), or None when any of them is not known that way."""
    if not target.late_owned_jobs:
        return None
    reader = getattr(api, "job_log_lines", None)
    if reader is None:
        return None
    try:
        jobs = read(lambda: api.jobs(target.run_id, target.attempt), sleep, log)
    except Aborted:
        raise
    except Exception as error:  # noqa: BLE001 - the workflow's labels decide instead
        log(f"could not list the jobs for their retry labels ({type(error).__name__}: {error})")
        return None
    waiting = [job for job in jobs if job_pool(job) and (waiting_for_runner(job) or in_setup(job))]
    if not waiting:
        return None
    found: set[str] = set()
    for job in waiting:
        name = str(job.get("name") or "")
        source = next(((picker, pattern) for prefix, picker, pattern in NIGHTLY_RETRY_SOURCES
                       if name == prefix or name.startswith(prefix + " (")), None)
        if source is None:
            return None
        picker = next((other for other in jobs if other.get("name") == source[0]
                       and other.get("status") == "completed" and other.get("id")), None)
        if picker is None:
            return None
        try:
            lines = reader(int(picker["id"]))
        except Aborted:
            raise
        except Exception as error:  # noqa: BLE001 - the workflow's labels decide instead
            log(f"could not read {source[0]}'s log ({type(error).__name__}: {error})")
            return None
        labels = [match.group(1) for line in lines or () for match in [source[1].search(line)] if match]
        if not labels:
            return None
        found.add(labels[-1])
    return found


def move_verdict(api: GitHub, target: Target, *, now: dt.datetime, sleep: Callable[[float], None],
                 log: Callable[[str], None]) -> tuple[str, str]:
    """Whether a queue rescue may move the run now: ("free" | "busy" | "stalled", the label it judged).

    "free": every label the re-run may take has a free slot, so it moves at the configured budget.
    "stalled": one of them is stalled, so it never moves there. "busy" (also an unreadable snapshot):
    it moves once the job has waited OWNED_WAIT_FLOOR_SECONDS.
    """
    if repicks(target):
        return "free", ""
    reader = getattr(api, "pool_snapshot", None)
    try:
        snapshot = reader(now) if reader is not None else None
    except Aborted:
        raise
    except Exception as error:  # noqa: BLE001 - an unread snapshot only means the floor applies
        log(f"could not read the pool snapshot ({type(error).__name__}: {error}); waiting the owned floor")
        snapshot = None
    if not isinstance(snapshot, Mapping):
        return "busy", ""
    states = blacksmith_states(snapshot, now)
    if all(state == "free" for state in states.values()):
        return "free", ""
    resolved = nightly_retry_destinations(api, target, sleep, log)
    unknown = sorted((resolved or set()) - set(states))
    if unknown:
        # A label the snapshot's pools do not list has no state to judge: the workflow's labels decide instead.
        log(f"the re-run's label {', '.join(unknown)} is not a pool the snapshot judges; the workflow's labels decide")
        resolved = None
    if resolved:
        labels = sorted(resolved)
    else:
        try:
            text = read(lambda: api.workflow_file(target.path, target.head_sha), sleep, log)
        except Aborted:
            raise
        except Exception as error:  # noqa: BLE001 - every picker label then counts as a destination
            log(f"could not read {target.path} at {target.head_sha[:12]} ({type(error).__name__}: {error})")
            text = None
        labels = sorted(retry_labels(text))
    for verdict in ("stalled", "busy"):
        hit = next((label for label in labels if states.get(label) == verdict), "")
        if hit:
            return verdict, hit
    return "free", ""


def next_attempt(target: Target) -> str:
    """Where a re-run of failed jobs goes next."""
    following = target.attempt + 1
    if target.path == CMUX_NEXT_WORKFLOW_PATH:
        if following <= LAST_OWNED_ATTEMPT:
            return f"attempt {following} stays on the side lane's owned label"
        if following > REFUSAL_RESCUE_ATTEMPT:
            return f"attempt {following} takes Blacksmith: a mini refused attempt {target.attempt}"
        return f"attempt {following} takes the side lane's Blacksmith overflow after the long mini queue"
    if target.side:
        return f"attempt {following} takes the side lane's Blacksmith default"
    if following <= LAST_OWNED_ATTEMPT and not target.e2e:
        return f"attempt {following} goes back to the owned labels, where the sweeper watches it"
    return f"attempt {following} takes retry_runner on Blacksmith"


def e2e_build_unfinished(api: GitHub, target: Target, sleep: Callable[[float], None],
                         log: Callable[[str], None]) -> bool:
    """An E2E run whose build job did not succeed, so its re-run compiles.

    A re-run of failed jobs keeps the `sibling` job's attempt-1 answer, taken
    before the refusal, so it never waits for a sibling that started compiling
    the same revision since: run 36168890047's attempt 2 compiled product
    8c48a10e beside run 36168944875. Re-running every job runs the Linux
    jobs and that wait again, which costs seconds. A build that passed is
    kept, as always.
    """
    if target.path != E2E_WORKFLOW_PATH:
        return False
    jobs = read(lambda: api.jobs(target.run_id, target.attempt), sleep, log)
    build = next((job for job in jobs if job.get("name") == "build"), None)
    return build is None or build.get("conclusion") != "success"


# cmux NEXT's nightly appcast (nightly.yml's NIGHTLY_NEXT_FEED_BASE). A nightly build number is its run id and a
# two-digit attempt (4119158082902 is run 41191580829, attempt 2), and publish-nightly refuses a build no newer
# than the feed's, so a nightly-next run older than the feed's newest build's run can never publish there.
NEXT_FEED_URL = "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml"
_FEED_VERSION = re.compile(r"<sparkle:version>\s*(\d+)\s*</sparkle:version>")
# glaeda's job-started hook refuses an owned-Mac signing job when scripts/ci/glaeda-signing-hooks.txt at the run's
# own commit does not list the mini's hook. A re-run runs that same commit, so it is refused the same way every
# time: on 2026-10-31 the rescue re-ran old nightly-next runs' sign-nightly-identity-legacy up to attempt 15, each
# refused within seconds, while adding the hook to the list (at the tip) could never reach those commits.
HOOK_UNLISTED = "glaeda-signing-hooks.txt at this run's commit does not list this hook"


def newest_feed_build(xml: str) -> int | None:
    """The highest cmux NEXT Nightly <sparkle:version> in an appcast, or None when it has none. The appcast also
    carries cmux NEXT Dev items (channel cmux-next-dev), whose numbers are no nightly run's; only items on the
    cmux-next channel count, as in nightly_next_feed_watch.nightly_builds()."""
    builds = []
    for item in re.findall(r"<item\b.*?</item>", xml, re.S):
        channel = re.search(r"<sparkle:channel>\s*([^<]*?)\s*</sparkle:channel>", item)
        version = _FEED_VERSION.search(item)
        if channel and channel.group(1) == "cmux-next" and version:
            builds.append(int(version.group(1)))
    return max(builds) if builds else None


# A runs-on that can send a re-run elsewhere than the attempt that was refused: an attempt-2 alternate
# (`github.run_attempt > 1 && ...sign_alternate`) or a Blacksmith pick.
_RERUN_ELSEWHERE = re.compile(r"run_attempt\s*(?:>|>=|!=)|blacksmith", re.I)


# A runs-on that reads the attempt at all: its value can differ between attempts.
_READS_ATTEMPT = re.compile(r"run_attempt", re.I)


def rerun_stays_owned(workflow_text: str | None, name: str, *, failed_only: bool = False) -> bool:
    """Whether the workflow job the jobs API calls `name` runs on owned Macs at every attempt, so a re-run meets the
    same hook. Fails open (False): an unreadable file or an unmatched job keeps the re-run.

    `failed_only`: the re-run is of failed jobs only (rerun_failed_or_repick() from attempt 2 on, or attempt 1 of a
    run that is not nightly-next's), so the pickers the job needs keep their outputs. A runs-on that does not read the
    attempt then resolves to the same owned label the refused job was on, whatever fallback literal it ends in: the
    legacy signer's `needs.legacy-identity-target.outputs.sign_runner || 'blacksmith-6vcpu-macos-26'` takes the
    Blacksmith literal only when the picker's output is empty, which it was not for a job the minis' hook refused
    (#29447)."""
    if not workflow_text:
        return False
    try:
        spec = owned_pool_sources._load(workflow_text).get("jobs") or {}
    except Exception:  # noqa: BLE001 - an unparseable file, or no PyYAML, keeps the re-run
        return False
    matches = [job for key, job in spec.items() if isinstance(job, Mapping)
               and _job_name_pattern(str(key), job).fullmatch(name)]
    if len(matches) != 1:
        return False
    runs_on = matches[0].get("runs-on")
    if not runs_on:
        return False
    text = json.dumps(runs_on)
    if failed_only and not _READS_ATTEMPT.search(text):
        return True
    return not _RERUN_ELSEWHERE.search(text)


def nightly_next_moot(api: GitHub, target: Target, sleep: Callable[[float], None],
                      log: Callable[[str], None]) -> str:
    """Why re-running this finished nightly-next run can never publish, or "".

    Only a finished run is ever moot here: a newer tip or a refusal never cancels a started nightly (Nightly
    freshness), so a run that is still going keeps "" and its own path. A finished one is moot when cmux NEXT's
    feed already has a Nightly build of a newer run (publish-nightly would refuse this one), or when a job of this
    attempt was refused because its commit's signing-hook list lacks the mini's hook and the job's runs-on keeps
    every re-run on owned Macs (a re-run is refused the same way). Any read that fails answers "", as before: a feed
    that cannot be read keeps the run wanted, and no refusal is judged moot while it is unread (#29448)."""
    try:
        jobs = read(lambda: api.jobs(target.run_id, target.attempt), sleep, log)
        if not jobs or not run_finished(jobs):
            return ""
        reason = ""
        newest = getattr(api, "next_feed_newest_build", None)
        build = newest() if newest is not None else None
        if build and target.run_id < build // 100:
            reason = (f"cmux NEXT's feed already has Nightly build {build} of a newer run ({build // 100}), and "
                      "publish-nightly refuses an older build")
        text: list[str | None] = []
        for found in jobs if not reason else ():
            if not refused(found) or not found.get("id"):
                continue
            notes = read(lambda: api.annotations(int(found["id"]), final=True), sleep, log)
            if not any(HOOK_UNLISTED in str(note.get("message") or "") for note in notes if isinstance(note, Mapping)):
                continue
            if not text:
                text.append(read(lambda: api.workflow_file(target.path, target.head_sha), sleep, log))
            name = str(found.get("name") or found["id"])
            # From attempt 2 on, a refusal re-runs only the failed jobs (rerun_failed_or_repick()); attempt 1 of a
            # nightly-next run may re-run its build picker and the jobs that need it, which may pick afresh.
            if rerun_stays_owned(text[0], name, failed_only=target.attempt > 1):
                reason = (f"{name} was refused because scripts/ci/glaeda-signing-hooks.txt at "
                          f"{target.head_sha[:12]} does not list the minis' runner hook, and its runs-on keeps "
                          "every re-run on owned Macs, so a re-run is refused the same way")
                break
        if not reason:
            return ""
        # The listed jobs can all be done while the run still adds more: only a finished run is moot.
        run = read(lambda: api.run(target.run_id), sleep, log)
        if not run or run.get("status") != "completed":
            return ""
        return reason
    except (*READ_ERRORS, AnnotationsCapped) as error:
        log(f"could not tell whether nightly-next run {target.run_id} is moot ({error}); treating it as wanted")
    return ""


def pull_moved(api: GitHub, target: Target, sleep: Callable[[float], None],
               log: Callable[[str], None]) -> str:
    """Why the pull request (or main) no longer wants this run, or "" when it still does.

    A main nightly whose app build succeeded (app_built()) is not made moot by main moving on: only its jobs
    after the build are moved, each push run has its own concurrency group (a re-run cancels nothing), and the
    publisher refuses a source older than the feed's. Only a newer run pending behind it still wins."""
    if target.nightly and target.push_branch == "nightly-next":
        # Each nightly-next run builds and signs in groups of its own (nightly.yml
        # scopes them to github.run_id), so a newer tip builds alongside this one
        # and never makes it moot: a newer tip is never a reason to cancel a
        # nightly (Nightly freshness). publish-nightly's order check refuses a
        # build no newer than the feed, so re-running an older one never downgrades,
        # but it never publishes either: a finished run that can no longer publish
        # is not re-run (nightly_next_moot()).
        return nightly_next_moot(api, target, sleep, log)
    if target.nightly:
        # nightly.yml's concurrency group never cancels in progress: a newer
        # run waits behind this one, and a re-run of this one would join the
        # group and cancel that pending run. Leave the revision to it.
        branch = target.push_branch or MAIN_BRANCH
        newer = read(lambda: api.newer_unfinished_runs(target.path, target.run_id, branch), sleep, log)
        if newer:
            return f"a newer nightly run on {branch} ({newer[0]}) has not finished and builds instead"
        if app_built(read(lambda: api.jobs(target.run_id, target.attempt), sleep, log)):
            # Its jobs after the build (a reserved follower, a signing job) are moved, never the build: a
            # re-run of failed jobs keeps it, so the run is not moot either.
            return ""
        # Not pending does not mean not superseded: a nightly-next push run is
        # never pending at the workflow level (its builds share a job-level
        # slot), and a newer main push may already be running or done. Once the
        # branch has moved past this commit and a newer push run covers it, a
        # re-run would only build (and publish) an older head on Blacksmith.
        pushes = read(lambda: api.newer_push_runs(target.path, target.run_id, branch), sleep, log)
        if pushes:
            head = read(lambda: api.branch_head(branch), sleep, log)
            if head and head != target.head_sha:
                return (f"{branch} has moved on to {head[:12]}, and its newer push run ({pushes[-1]}) "
                        "builds it instead")
        return ""
    if target.push_branch:
        # Not the branch head: a head commit outside the workflow's paths has no
        # run, and the newest push run that does cover the branch must finish.
        newer = read(lambda: api.newer_push_runs(target.path, target.run_id, target.push_branch), sleep, log)
        if newer:
            return f"a newer push run on {target.push_branch} ({newer[-1]}) covers the branch instead"
        return ""
    if (target.e2e or target.side) and not target.pr_number:
        return ""  # a dispatch or schedule has no head to move
    if target.main:
        head = read(lambda: api.branch_head(MAIN_BRANCH), sleep, log)
        if head != target.head_sha:
            return (f"{MAIN_BRANCH} has moved on, and ci-main-full-suite.yml dispatches its new HEAD "
                    "once this run completes")
        return ""
    pull = read(lambda: api.pull(target.pr_number), sleep, log)
    if pull.get("state") != "open":
        return "the pull request is closed"
    if (pull.get("head") or {}).get("sha") != target.head_sha:
        return "the pull request has a newer head, whose own run replaces this one"
    return ""


# nightly.yml's runner picker for build-nightly-app and the Ghostty helper (feat-cmux-next). A re-run of
# failed jobs keeps a finished picker's outputs, and the build reads its owned pick only when that pick
# was made for the run's own attempt, so the re-run takes attempt 1's Blacksmith label: on 2026-10-27
# runs 40549487427, 40550551073 and 40550711613 (attempt 1's build refused at "Set up runner" on the
# dedicated builder, whose runner then went offline) re-ran onto blacksmith-6vcpu-macos-26, a label the
# picker had already reported as stalled. Re-running the picker job instead (GitHub re-runs a job and every
# job that needs it) makes the picker choose again: an idle owned Mac, else a moving Blacksmith label.
NIGHTLY_BUILD_PICKER = "pick-nightly-build-runner"


def repick_job(workflow_text: str, jobs: Sequence[Mapping[str, Any]]) -> tuple[int | None, str]:
    """(the id of this attempt's NIGHTLY_BUILD_PICKER job, when re-running it and the jobs that need it
    re-runs everything a re-run of failed jobs would and nothing that could break, or None, why).

    `jobs` is the attempt's whole job list, the jobs a re-run kept from earlier attempts included (the picker
    is one after a re-run of failed jobs). Every failed, timed-out or cancelled job in it must need the
    picker, directly or through others, so nothing a re-run of failed jobs would retry is left out (GitHub
    re-runs the picked job and its dependents only). A finished job that needs the picker but no failed job
    is re-run only by this (a re-run of failed jobs re-runs whatever needs a failed job already): unless it
    was skipped (it uploaded nothing), each of its artifact uploads must set `overwrite: true`, or its
    second upload of the same name could fail. Names map to workflow jobs as in downstream_of_refusals()."""
    try:
        document = owned_pool_sources._load(workflow_text)
    except Exception as error:  # noqa: BLE001 - an unreadable file keeps the re-run of failed jobs
        return None, f"the workflow file could not be read ({type(error).__name__})"
    spec = {str(key): job for key, job in (document.get("jobs") or {}).items() if isinstance(job, Mapping)}
    if NIGHTLY_BUILD_PICKER not in spec:
        return None, f"the workflow has no {NIGHTLY_BUILD_PICKER} job"
    needs: dict[str, set[str]] = {}
    for key, job in spec.items():
        wanted = job.get("needs") or []
        needs[key] = {str(item) for item in ([wanted] if isinstance(wanted, str) else wanted)} & set(spec)
    below: dict[str, set[str]] = {}

    def descendants(key: str) -> set[str]:
        if key not in below:
            below[key] = set()  # never loop on a cycle
            found: set[str] = set()
            for child, parents in needs.items():
                if key in parents:
                    found |= {child} | descendants(child)
            below[key] = found
        return below[key]

    patterns = {key: _job_name_pattern(key, job) for key, job in spec.items()}

    def keys(job: Mapping[str, Any]) -> set[str]:
        name = str(job.get("name") or "")
        return {key for key, pattern in patterns.items() if pattern.fullmatch(name)}

    current = list(jobs)
    pickers = [job for job in current if keys(job) == {NIGHTLY_BUILD_PICKER}]
    if len(pickers) != 1 or not pickers[0].get("id"):
        return None, f"this attempt has no single {NIGHTLY_BUILD_PICKER} job"
    picker = pickers[0]
    if picker.get("status") != "completed":
        return None, f"{NIGHTLY_BUILD_PICKER} has not finished"
    under = descendants(NIGHTLY_BUILD_PICKER)
    failed = [job for job in current if job is not picker and job.get("status") == "completed"
              and job.get("conclusion") in ("failure", "timed_out", "cancelled")]
    if not failed:
        return None, "no job of this attempt failed"
    failed_keys: set[str] = set()
    for job in failed:
        found = keys(job)
        if not found or not found <= under:
            return None, f"{job.get('name') or job.get('id')} does not need {NIGHTLY_BUILD_PICKER}"
        failed_keys |= found
    retried = failed_keys.union(*(descendants(key) for key in failed_keys))
    for job in current:
        found = keys(job)
        if job is picker or not found or not found <= under or found <= retried or job.get("conclusion") == "skipped":
            continue
        for key in found:
            for step in spec[key].get("steps") or []:
                if not isinstance(step, Mapping) or "actions/upload-artifact@" not in str(step.get("uses") or ""):
                    continue
                if str((step.get("with") or {}).get("overwrite", "")).strip().lower() != "true":
                    return None, (f"{job.get('name') or key} would upload "
                                  f"{(step.get('with') or {}).get('name') or 'an artifact'} again without overwrite")
    return int(picker["id"]), f"every failed job of this attempt needs {NIGHTLY_BUILD_PICKER}"


# nightly-next's app build, which runs on pick-nightly-build-runner's `owned` or `blacksmith` output (nightly.yml).
NIGHTLY_APP_BUILD = "build-nightly-app"


def nightly_build_unfinished(jobs: Sequence[Mapping[str, Any]]) -> bool:
    """Whether this attempt lists build-nightly-app and it did not succeed: nothing after the build has run, so the
    build picker may choose again (the jobs that verify a built app take their own alternates instead)."""
    builds = [job for job in jobs if str(job.get("name") or "") == NIGHTLY_APP_BUILD
              or str(job.get("name") or "").startswith(NIGHTLY_APP_BUILD + " (")]
    return bool(builds) and any(job.get("conclusion") != "success" for job in builds)


# A nightly build's deterministic compile error (compile_error()). The Release compile step of build-nightly-app, the
# shell's exit status GitHub records when xcodebuild exits 65 (EX_DATAERR: the build failed, as opposed to a signal,
# a lost runner or a timeout), and the swiftc diagnostic xcodebuild's output leaves as a failure annotation on a
# Swift source line.
NIGHTLY_COMPILE_STEP = "Build nightly app (Release)"
XCODEBUILD_FAILED = "Process completed with exit code 65."
COMPILE_SOURCE = re.compile(r"[^\s]+\.swift")


def nightly_build_jobs(jobs: Sequence[Mapping[str, Any]]) -> list[Mapping[str, Any]]:
    """The attempt's build-nightly-app jobs (one, or a matrix's legs)."""
    return [job for job in jobs if str(job.get("name") or "") == NIGHTLY_APP_BUILD
            or str(job.get("name") or "").startswith(NIGHTLY_APP_BUILD + " (")]


def compile_error(job: Mapping[str, Any], annotations: Sequence[Mapping[str, Any]]) -> str:
    """Why a finished build-nightly-app job failed on a compile error its source will repeat, or "".

    Conservative: only a job that failed (not cancelled or timed out), whose first failed step is the Release compile
    (NIGHTLY_COMPILE_STEP), with GitHub's "exit code 65" annotation and a failure annotation on a .swift line (the
    swiftc `error:` xcodebuild printed). A lost runner (no steps), a refusal at setup, a signal (exit 128 and up), a
    timeout, an unreadable job or any other failure is "": it may pass on another runner, so it stays retryable."""
    if job.get("status") != "completed" or job.get("conclusion") != "failure":
        return ""
    steps = [step for step in job.get("steps") or [] if isinstance(step, Mapping)]
    failed = [step for step in steps if step.get("conclusion") == "failure"]
    if not failed or failed[0].get("name") != NIGHTLY_COMPILE_STEP:
        return ""
    failures = [note for note in annotations if isinstance(note, Mapping) and note.get("annotation_level") == "failure"]
    if not any(str(note.get("message") or "").strip() == XCODEBUILD_FAILED for note in failures):
        return ""
    for note in failures:
        path = str(note.get("path") or "")
        line = note.get("start_line")
        if COMPILE_SOURCE.fullmatch(path) and isinstance(line, int) and not isinstance(line, bool) and line >= 1:
            message = " ".join(str(note.get("message") or "").split())[:200]
            return f"{job.get('name') or NIGHTLY_APP_BUILD} failed to compile: {path}:{line}: {message}"
    return ""


def nightly_compile_red(api: Any, target: "Target", sleep: Callable[[float], None],
                        log: Callable[[str], None]) -> str:
    """For a nightly, why its head cannot compile (compile_error() on the newest attempt that ran build-nightly-app),
    else "".

    A re-run of the same commit compiles the same source, so it fails the same way and only burns a Mac: on
    2026-10-30 run 40989498281 (00c873b5, with #27223's `'async' call in a function that does not support
    concurrency`) was re-run to attempt 4 by this rescue, each attempt rebuilding the broken commit. The fix is a
    newer commit, which the nightly-next tick promotes (its rolling rule) once it lands.

    Attempts are read from the newest down: one whose build was skipped, not finished, cancelled before a runner took
    it or not yet created says nothing, so the next older one is read; the first build that ran decides, and only a
    failure that compile_error() classifies makes the head compile-red (a timeout or a started cancel stays
    retryable). Any read error is "": a failed
    read never stops a re-run (the classification is conservative)."""
    if not target.nightly:
        return ""
    try:
        for attempt in range(target.attempt, 0, -1):
            builds = nightly_build_jobs(read(lambda: api.jobs(target.run_id, attempt), sleep, log))
            # A build that ran in any way decides (a timeout, or a cancel after a runner took it, is retryable); only
            # one that never ran (skipped, not yet finished, cancelled before any runner) falls through.
            ran = [job for job in builds if job.get("conclusion") in ("success", "failure", "timed_out")
                   or job.get("conclusion") == "cancelled" and job.get("runner_name")]
            if not ran:
                continue
            for job in ran:
                if job.get("conclusion") != "failure" or not job.get("id"):
                    continue
                why = compile_error(job, read(lambda: api.annotations(int(job["id"])), sleep, log))
                if why:
                    return f"attempt {attempt}'s {why}"
            return ""
    except (*READ_ERRORS, AnnotationsCapped) as error:
        log(f"could not read whether run {target.run_id}'s build failed to compile ({error}); treated as retryable")
    return ""


# rescue()'s and resume_rerun()'s answer for a nightly whose head does not compile (nightly_compile_red()).
COMPILE_RED = "not rescued: the run's head does not compile, so a re-run would fail the same way"


def compile_red_answer(why: str) -> str:
    return (f"{COMPILE_RED} ({why}); the nightly-next tick builds the next landing that fixes it, "
            "and nothing of this run is cancelled")


def rerun_failed_or_repick(api: GitHub, target: Target, sleep: Callable[[float], None],
                           log: Callable[[str], None], *, refusal: bool = False) -> str:
    """Re-run a finished attempt's failed jobs; for a nightly-next run, re-run its build picker and the jobs that
    need it instead when repick_job() allows, so the next attempt picks its runner fresh.

    Attempt 1 repicks whatever moved it. Any attempt whose app build was moved off a queue (not a refusal) repicks
    too: nightly_build_runner.py queues the build on a busy owned label when every Blacksmith label is stalled, and a
    re-run of failed jobs would send it to the stalled Blacksmith label that same pick named, where no owned watch
    follows it, so the build could wait there as long as the label stalls. When repick_job() declines there, the
    whole run is re-run (nothing past the build has run, and a started nightly is never cancelled), so the pickers
    still choose again. Such a move comes only after the queue budget and the stall hold (hold_for_destination()),
    so these re-runs are spaced that far apart, and an attempt the picker puts on an owned label is marked and
    watched again (owned_rerun()). A refusal from attempt 2 on keeps the re-run of failed jobs onto that attempt's
    Blacksmith pick: a fresh pick could send the job to the refusing Mac again, round after round."""
    if target.nightly and target.push_branch == "nightly-next" and (target.attempt == 1 or not refusal):
        try:
            jobs = read(lambda: api.jobs(target.run_id, target.attempt), sleep, log)
            text = read(lambda: api.workflow_file(NIGHTLY_WORKFLOW_PATH, target.head_sha), sleep, log)
        except READ_ERRORS as error:
            jobs, text = [], None
            log(f"could not read the run for a fresh runner pick ({error}); re-running its failed jobs")
        build_moved = not refusal and nightly_build_unfinished(jobs)
        if target.attempt > 1 and not build_moved:
            log(f"no fresh runner pick: attempt {target.attempt}'s app build was not moved off a queue")
        elif text:
            picker, why = repick_job(text, jobs)
            if picker is not None:
                try:
                    api.rerun_job(target.run_id, picker, target.attempt + 1)
                except urllib.error.HTTPError as error:
                    # Refused (GitHub declines a job it cannot re-run): the failed jobs, as before. If the job
                    # re-run did start, the run is no longer finished and this re-run is refused in turn.
                    log(f"the re-run of {NIGHTLY_BUILD_PICKER} was refused ({error.code}); re-running the failed jobs")
                    api.rerun_failed(target.run_id, target.attempt + 1)
                    return f"re-ran the failed jobs of run {target.run_id}; {next_attempt(target)}"
                return (f"re-ran {NIGHTLY_BUILD_PICKER} of run {target.run_id} and every job that needs it ({why}), "
                        f"so attempt {target.attempt + 1} picks its runner fresh")
            log(f"no fresh runner pick: {why}")
            if build_moved:
                api.rerun(target.run_id, target.attempt + 1)
                return (f"re-ran every job of run {target.run_id}: its app build was moved off a queue before it "
                        f"started, so attempt {target.attempt + 1}'s pickers choose again instead of the label "
                        f"attempt {target.attempt} picked")
    api.rerun_failed(target.run_id, target.attempt + 1)
    return f"re-ran the failed jobs of run {target.run_id}; {next_attempt(target)}"


# Looks nightly_cancel()'s guard makes for a jobs read no rate-limit wait made stale.
NIGHTLY_GUARD_TRIES = 3
# A run read slower than this (a token mint, a slow API) leaves the jobs read before it stale too.
NIGHTLY_GUARD_FRESH_SECONDS = 15
# rescue()'s answer when a nightly it was about to cancel had a job running: follow() then watches the run again.
NIGHTLY_BUSY = "not rescued: started nightly work is running"


class NightlyBusy(Aborted):
    """A nightly's job started during a rate-limit wait before a retried cancel (nightly_cancel())."""


def nightly_cancel(api: GitHub, target: Target, sleep: Callable[[float], None], log: Callable[[str], None],
                   before_cancel: Callable[[], None] | None = None) -> None:
    """api.cancel. For a nightly, its guard runs right before the cancel is sent and before every re-send
    (GitHub.cancel()'s before_send): it drops the cancel once the run moved to another attempt or finished, and
    raises NightlyBusy once a job of it runs. `before_cancel` (rescue()'s own guard) runs first."""
    def check() -> None:
        if before_cancel is not None:
            before_cancel()
        if not is_delivery_target(target):
            return
        for _ in range(NIGHTLY_GUARD_TRIES):
            # The jobs first, then the run: a jobs read that waited (a rate limit, a retried error) may return
            # the old attempt's jobs after someone re-ran the run, and the run read after it shows that attempt.
            busy = started_delivery_work(api, target, sleep, log)
            waited, began = getattr(api, "rate_limit_waited", 0.0), time.monotonic()
            run = api.run(target.run_id) or {}
            attempt = int(run.get("run_attempt") or 0)
            if attempt != target.attempt:
                # Someone re-ran it meanwhile: the cancel would hit that newer attempt's running jobs.
                raise Aborted(f"nightly run {target.run_id} is at attempt {attempt}, not {target.attempt}; "
                              "not cancelled")
            if run.get("status") == "completed":
                raise Aborted(f"nightly run {target.run_id} has finished; nothing to cancel")
            if busy:
                raise NightlyBusy(busy)
            if getattr(api, "rate_limit_waited", 0.0) == waited and \
                    time.monotonic() - began < NIGHTLY_GUARD_FRESH_SECONDS:
                return
            # The run read itself waited (a rate limit, a token mint): a job may have started since the jobs
            # read. Look again.
        raise NightlyBusy(f"slow reads kept the jobs of run {target.run_id} unconfirmed")
    if before_cancel is None and not is_delivery_target(target):
        api.cancel(target.run_id)
        return
    api.cancel(target.run_id, before_send=check)


class OpenHeadStarted(Aborted):
    """A job of an open-head run the failover meant to move started before the cancel went out."""


# The placement jobs a run must finish before its Mac jobs exist (path routing, the macOS placement, the head
# preflight, ci.yml's `changes` picker: dep-fleet's ruling). They run on Linux in seconds and a full re-run repeats them, so they are the only
# finished jobs an open-head failover allows (unstarted_failover()); any other job that ran keeps OPEN_HEAD_RULE.
PLACEMENT_JOBS = frozenset({
    PICKER_JOB, "cmux-next path routing", "cmux-next macOS placement",
    "cmux-next push head preflight",
})


# The workflows whose delivery runs the open-head failover never touches, named explicitly (dep-fleet's ruling):
# nightly, DEV and promote builds and their sign, verify, publish and rollback runs. Every delivery workflow
# (delivery_workflows.is_delivery_run()) is excluded as well. The ruling covers delivery runs only: a pull request's
# test run of one of these (nightly-next-canary.yml, nightly-next-launch-smoke.yml) is an ordinary pull request run.
NEVER_FAILOVER_PATHS = frozenset({
    NIGHTLY_WORKFLOW_PATH, CMUX_NEXT_DEV_DAILY_WORKFLOW_PATH,
    ".github/workflows/cmux-next-dev-daily-dispatch.yml", ".github/workflows/release.yml",
    ".github/workflows/nightly-sign.yml", ".github/workflows/nightly-next-train.yml",
    ".github/workflows/nightly-next-tick.yml", ".github/workflows/nightly-next-canary.yml",
    ".github/workflows/nightly-next-launch-smoke.yml", ".github/workflows/nightly-next-rollback.yml",
    ".github/workflows/nightly-next-verdict.yml", ".github/workflows/nightly-next-feed-watch.yml",
})


def is_delivery_target(target: Target) -> bool:
    """Runs that build or publish a feed must not lose started work to queue rescue."""
    if target.nightly:
        return True
    if target.path in (NIGHTLY_WORKFLOW_PATH, CMUX_NEXT_DEV_DAILY_WORKFLOW_PATH):
        return not target.event or target.event not in {"pull_request", "pull_request_target", "merge_group"}
    return target.e2e and target.path == CMUX_NEXT_WORKFLOW_PATH and target.event in TRUSTED_SIDE_EVENTS


def never_fails_over(path: str, event: str | None) -> bool:
    """A delivery run: a nightly, DEV, promote, release, sign or rollback workflow's (NEVER_FAILOVER_PATHS, or
    delivery_workflows.is_delivery_run()) from an event that can deliver (delivery_workflows.is_delivery_event(): any
    event but a pull request's; an unread one counts)."""
    return is_delivery_event(event) and (path in NEVER_FAILOVER_PATHS or is_delivery_run(path))


def job_started(job: Mapping[str, Any]) -> bool:
    """Whether a cancel could lose this job (dep-fleet's ruling): every job must be queued or waiting with no runner
    assigned, except a PLACEMENT_JOBS job finished with conclusion success. A job GitHub skipped never ran and was
    never assigned a runner. Anything else, a runner assigned, running, or finished any other way, is started."""
    status, conclusion = job.get("status"), job.get("conclusion")
    assigned = bool(job.get("runner_name") or job.get("runner_id"))
    if status in ("queued", "waiting", "pending", "requested") and not assigned:
        return False
    if status == "completed" and conclusion == "skipped" and not assigned:
        return False
    return not (status == "completed" and conclusion == "success" and str(job.get("name") or "") in PLACEMENT_JOBS)


# cmux-next.yml's macOS placement (its job key and its name). An open-head failover of a cmux-next pull request
# run's first attempt re-runs this job and the jobs that need it (placement_rerun()), not the whole run: GitHub
# re-runs a job's dependents with it, the placement runs again on the bot's attempt 2 (its `if`) and reads the
# routes afresh, and every finished job outside it keeps its result.
CMUX_NEXT_PLACEMENT_KEY = "macos-placement"
CMUX_NEXT_PLACEMENT_JOB = "cmux-next macOS placement"


@dataclasses.dataclass(frozen=True)
class PlacementRerun:
    """What an open-head failover re-runs of a cmux-next pull request run (placement_rerun())."""

    job_id: int  # this attempt's CMUX_NEXT_PLACEMENT_JOB
    below: frozenset[str]  # the workflow jobs that need it, directly or through others
    patterns: tuple[tuple[str, re.Pattern[str]], ...]  # each workflow job's API names (_job_name_pattern())

    def keys(self, job: Mapping[str, Any]) -> set[str]:
        name = str(job.get("name") or "")
        return {key for key, pattern in self.patterns if pattern.fullmatch(name)}

    def reruns(self, job: Mapping[str, Any]) -> bool:
        """Whether re-running the placement re-runs `job` too. A name that maps to no workflow job, or to one
        that need not the placement, is kept only when every job it could be is outside; else it re-runs."""
        if job.get("id") is not None and job.get("id") == self.job_id:
            return True
        found = self.keys(job)
        return not found or bool(found & self.below)

    def brings_back(self, job: Mapping[str, Any]) -> bool:
        """Whether re-running the placement surely runs `job` again (an unfinished job the cancel stops): the
        placement itself, or a name every workflow job it could be needs the placement. A name that maps to no
        workflow job, or to one outside the placement's subtree too, may be left cancelled: no."""
        if job.get("id") is not None and job.get("id") == self.job_id:
            return True
        found = self.keys(job)
        return bool(found) and found <= self.below


def placement_rerun(workflow_text: str | None, jobs: Sequence[Mapping[str, Any]]) -> tuple[PlacementRerun | None, str]:
    """(the placement re-run, why) for a cmux-next pull request run's open-head failover, or (None, why) when the
    workflow file at the head cannot show it (unread, unparsable, no CMUX_NEXT_PLACEMENT_KEY job) or the attempt has
    no single finished, successful placement job with an id. With None the failover keeps the full re-run rule."""
    if not workflow_text:
        return None, "the workflow file at the head could not be read"
    try:
        document = owned_pool_sources._load(workflow_text)
    except Exception as error:  # noqa: BLE001 - an unreadable file keeps the full re-run rule
        return None, f"the workflow file could not be read ({type(error).__name__})"
    spec = {str(key): job for key, job in (document.get("jobs") or {}).items() if isinstance(job, Mapping)}
    if CMUX_NEXT_PLACEMENT_KEY not in spec:
        return None, f"the workflow has no {CMUX_NEXT_PLACEMENT_KEY} job"
    needs: dict[str, set[str]] = {}
    for key, job in spec.items():
        wanted = job.get("needs") or []
        needs[key] = {str(item) for item in ([wanted] if isinstance(wanted, str) else wanted)} & set(spec)
    below: set[str] = set()
    frontier = {CMUX_NEXT_PLACEMENT_KEY}
    while frontier:
        frontier = {child for child, parents in needs.items() if parents & frontier and child not in below}
        below |= frontier
    patterns = tuple((key, _job_name_pattern(key, job)) for key, job in spec.items())
    placement = _job_name_pattern(CMUX_NEXT_PLACEMENT_KEY, spec[CMUX_NEXT_PLACEMENT_KEY])
    found = [job for job in jobs if placement.fullmatch(str(job.get("name") or ""))]
    if len(found) != 1 or found[0].get("id") is None:
        return None, f"this attempt has no single {CMUX_NEXT_PLACEMENT_JOB} job"
    if found[0].get("status") != "completed" or found[0].get("conclusion") != "success":
        return None, f"{CMUX_NEXT_PLACEMENT_JOB} has not succeeded"
    return PlacementRerun(int(found[0]["id"]), frozenset(below), patterns), \
        f"{CMUX_NEXT_PLACEMENT_JOB} and the {len(below)} jobs that need it"


def failover_loses(job: Mapping[str, Any], plan: PlacementRerun | None) -> bool:
    """Whether the open-head failover's cancel and re-run could lose `job`. Without a placement re-run (`plan`), as
    job_started() rules (dep-fleet's ruling for a full re-run). With one, a job still waiting with no runner loses
    nothing if the re-run surely runs it again (every workflow job its name could be needs the placement,
    PlacementRerun.brings_back(); an unmatched or ambiguous name is not shown to come back), and a finished job
    loses nothing if the re-run
    keeps it (it need not the placement: a Linux check, a red `checks` included, keeps its result and is not
    repeated) or if it was skipped (it ran nothing). A running or runner-assigned job, a waiting one the re-run would
    leave cancelled, or a finished one the re-run would repeat, could be lost."""
    if plan is None:
        return job_started(job)
    status, conclusion = job.get("status"), job.get("conclusion")
    assigned = bool(job.get("runner_name") or job.get("runner_id"))
    if status != "completed":
        return status not in ("queued", "waiting", "pending", "requested") or assigned or not plan.brings_back(job)
    if conclusion == "skipped" and not assigned:
        return False
    if job.get("id") is not None and job.get("id") == plan.job_id:
        return False  # the placement itself: placement_rerun() found it succeeded
    return plan.reruns(job)


def failover_plan(api: GitHub, target: Target, jobs: Sequence[Mapping[str, Any]], sleep: Callable[[float], None],
                  log: Callable[[str], None]) -> PlacementRerun | None:
    """The placement re-run for a cmux-next pull request run's first attempt (placement_rerun()), or None: another
    workflow, a later attempt (the placement runs again on the bot's attempt 2 only) or a file that cannot show it,
    when the failover keeps the full re-run and its rule that nothing has finished."""
    if target.path != CMUX_NEXT_WORKFLOW_PATH or target.attempt != 1 or not target.pr_number:
        return None
    reader = getattr(api, "workflow_file", None)
    if reader is None:
        return None
    try:
        text = read(lambda: reader(target.path, target.head_sha), sleep, log)
    except READ_ERRORS as error:
        log(f"could not read {target.path} at {target.head_sha[:12]} ({error}); the failover re-runs every job")
        return None
    plan, why = placement_rerun(text, jobs)
    if plan is None:
        log(f"no placement re-run: {why}; the failover keeps the full re-run")
    return plan


def job_key(job: Mapping[str, Any]) -> Any:
    """A job's key in a watcher's first_seen map: its id, else its name."""
    return job.get("id") if job.get("id") is not None else str(job.get("name") or "")


def started_nothing(pools: Mapping[str, Any], label: str) -> bool:
    """Whether the janitor's snapshot shows `label` with nothing running on it. A label the snapshot does not
    list proves nothing, so it is not taken as started nothing."""
    entry = pools.get(label)
    if not isinstance(entry, Mapping):
        return False
    try:
        return int(entry.get("running", 0)) == 0
    except (TypeError, ValueError):
        return False


# The janitor snapshot's map of each macOS runner label to its newest job start (queue_janitor.label_started()).
LABEL_STARTED_KEY = "label_started"


def label_quiet(snapshot: Mapping[str, Any], label: str, since: dt.datetime | None) -> bool:
    """Whether the janitor's snapshot shows `label` started nothing since `since` (when a job began waiting on it),
    though its pool count shows a job running (started_nothing() covers none running): a runner last took a job
    asking for exactly that label before `since`, and the snapshot was made at least UNSTARTED_STALL_SECONDS after
    `since`, so it covers that much of the wait. A label the snapshot does not list, or a snapshot without
    LABEL_STARTED_KEY (an older janitor), proves nothing. A label listed with no start (no in-flight job a runner
    took asked for it) started nothing either. Run 40993742146's fast tier waited five hours on
    glaeda-side-std-xcode-26.6 while the one job running there had started before it queued (2026-10-30)."""
    pools = snapshot.get("pools")
    starts = snapshot.get(LABEL_STARTED_KEY)
    generated = parse_time(snapshot.get("generated_at"))
    if since is None or generated is None or not isinstance(pools, Mapping) or not isinstance(starts, Mapping):
        return False
    if not isinstance(pools.get(label), Mapping):
        return False
    if (generated - since).total_seconds() < UNSTARTED_STALL_SECONDS:
        return False
    last = parse_time(starts.get(label)) if starts.get(label) else None
    return last is None or last < since


def mac_route(job: Mapping[str, Any]) -> str | None:
    """The macOS label a job asked for: an owned or lane label (job_pool()), else a Blacksmith macOS label."""
    owned = job_pool(job)
    if owned:
        return owned
    return next((str(label) for label in job.get("labels") or () if BLACKSMITH_MACOS_LABEL.fullmatch(str(label))),
                None)


def unstarted_failover(api: GitHub, target: Target, *, now: Callable[[], dt.datetime],
                       sleep: Callable[[float], None], log: Callable[[str], None],
                       first_seen: Mapping[Any, dt.datetime] | None = None) -> str:
    """Why an unfinished run at its open head may be cancelled and re-run, or "" when OPEN_HEAD_RULE keeps it (see
    the module docstring and open_head_failover())."""
    return open_head_failover(api, target, now=now, sleep=sleep, log=log, first_seen=first_seen).why


def job_running(job: Mapping[str, Any]) -> bool:
    """Whether a cancel would kill work of this job: it is unfinished and a runner holds it (assigned, in its setup
    or running). A finished job keeps its result through a cancel, and a job still waiting for a runner has none."""
    if job.get("status") == "completed":
        return False
    return bool(job.get("runner_name") or job.get("runner_id")) or job.get("status") not in (
        "queued", "waiting", "pending", "requested")


@dataclasses.dataclass(frozen=True)
class Failover:
    """open_head_failover()'s answer. `why` is "" when OPEN_HEAD_RULE keeps the run. `plan` is the cmux-next placement
    re-run (else every job is re-run). `settled` is the settled-sibling failover: only the attempt's one waiting job
    and the jobs that need it (`only_job`) are re-run."""

    why: str
    plan: PlacementRerun | None = None
    settled: bool = False
    only_job: int | None = None

    def __bool__(self) -> bool:
        return bool(self.why)


NO_FAILOVER = Failover("")


def open_head_failover(api: GitHub, target: Target, *, now: Callable[[], dt.datetime],
                       sleep: Callable[[float], None], log: Callable[[str], None],
                       first_seen: Mapping[Any, dt.datetime] | None = None) -> Failover:
    """Why an unfinished run at its open head may be cancelled and re-run, and what is re-run (a Failover), or
    NO_FAILOVER when OPEN_HEAD_RULE keeps it. The re-run is the cmux-next placement and the jobs that need it when
    failover_plan() finds one (a cmux-next pull request run's first attempt), else every job. All of these must hold:

    - the run is a pull request's and no nightly, DEV or promote build (nightly, the feed workflows, a dispatch);
    - nothing the cancel and re-run do can lose a job (failover_loses()): no job runs or has a runner, and every
      finished job is a placement job that succeeded, a skipped one, or (with a placement re-run) one the re-run
      keeps. A cmux-next pull request run always has finished Linux jobs by the time a Mac job has waited
      UNSTARTED_STALL_SECONDS (its checks, the cargo fast tier, the web bundles), so before the placement re-run
      the failover never moved one (runs 40993742146, 41021261503, 2026-10-30). A job listing that may be cut short
      (MAX_JOB_PAGES full pages) proves nothing;
    - a job has waited UNSTARTED_STALL_SECONDS or more for a runner on a label that started nothing: the janitor's
      fresh snapshot shows nothing running there (started_nothing()), or nothing started there since the job began
      waiting (label_quiet()). A job's wait starts at the later of its created_at and when a watch first saw it
      queued (`first_seen`, the watcher's; else this look's). A job that has waited less is looked at again once it
      has waited that long (one bounded sleep), not given up on.

    Where the re-run would lose a finished job (it would repeat it, or the run has a finished job and no placement
    re-run) but no job of the run is running or held by a runner (job_running()), the settled-sibling failover
    applies instead (`settled`), when the stalled job is the attempt's one unfinished job: the cancel stops only that
    job, which never ran, every finished job keeps its result, red ones included, and only that job and the jobs
    that need it run again (`only_job`). With another job still queued (a Linux job, a second Mac job) OPEN_HEAD_RULE
    holds: GitHub re-runs one job and its dependents, or the failed and cancelled ones, and no single re-run is shown
    to bring back every job the cancel stops; a later look, once the others finished, moves it. Run 40997814347 (PR #27853,
    2026-10-30) had 28 of 29 jobs finished, its swift test and daemon tests red below the placement, and its Release
    compile queued on glaeda-std-xcode-26.6 for over four hours while that label ran nothing.
    """
    if not target.pr_number or target.nightly or target.main or target.push_branch \
            or (target.e2e and target.path != IOS_KIT_WORKFLOW_PATH) \
            or target.path in FEED_TIMEOUT_PATHS or never_fails_over(target.path, target.event):
        return NO_FAILOVER
    reader = getattr(api, "pool_snapshot", None)
    if reader is None:
        return NO_FAILOVER
    plan: PlacementRerun | None = None
    planned = False
    seen: dict[Any, dt.datetime] = dict(first_seen or {})
    for look in (1, 2):
        try:
            snapshot = reader(now())
        except Aborted:
            raise
        except Exception as error:  # noqa: BLE001 - an unread snapshot proves nothing, so OPEN_HEAD_RULE holds
            log(f"could not read the pool snapshot ({type(error).__name__}: {error}); the open head keeps the run")
            return NO_FAILOVER
        pools = snapshot.get("pools") if isinstance(snapshot, Mapping) else None
        if not isinstance(pools, Mapping) or not pools:
            return NO_FAILOVER
        jobs = read(lambda: api.jobs(target.run_id, target.attempt), sleep, log)
        if len(jobs) >= MAX_JOB_PAGES * 100:
            log(f"run {target.run_id} lists {len(jobs)} jobs, maybe more; the open head keeps the run")
            return NO_FAILOVER
        at = now()
        waiting = [(job, str(mac_route(job))) for job in jobs if waiting_for_runner(job) and mac_route(job)]
        for job, _ in waiting:
            if parse_time(job.get("created_at")) is None:
                # No created_at to date it: this look is the earliest proof it was queued.
                seen.setdefault(job_key(job), at)
        dead = [(job, label) for job, label in waiting if started_nothing(pools, label)
                or label_quiet(snapshot, label, wait_start(job, seen.get(job_key(job))))]
        if not dead:
            return NO_FAILOVER
        # The workflow file only now, once a label runs nothing (one read per look at most).
        if not planned:
            plan, planned = failover_plan(api, target, jobs, sleep, log), True
        settled = any(failover_loses(job, plan) for job in jobs)
        if settled and any(job_running(job) for job in jobs):
            return NO_FAILOVER
        left = [each for each in jobs if each.get("status") != "completed"]
        if settled and (len(left) != 1 or not isinstance(left[0].get("id"), int)):
            log(f"run {target.run_id} has {len(left)} unfinished jobs, and a re-run of the failed jobs would leave "
                "a cancelled queued one behind; the open head keeps the run until only the stalled job is left")
            return NO_FAILOVER

        def wait(job: Mapping[str, Any]) -> float:
            return queued_seconds(job, at, seen.get(job_key(job)))
        job, label = max(dead, key=lambda pair: wait(pair[0]))
        waited = wait(job)
        if waited >= UNSTARTED_STALL_SECONDS:
            idle = "runs nothing" if started_nothing(pools, label) else "has started nothing since it queued"
            stuck = f"{job.get('name') or job.get('id')} has waited {int(waited // 60)} min on `{label}`, which {idle}"
            if settled:
                return Failover(f"no job of attempt {target.attempt} is running ({len(jobs) - 1} of {len(jobs)} "
                                f"finished), and {stuck}", settled=True, only_job=int(left[0]["id"]))
            done = (f"no job of attempt {target.attempt} has started" if plan is None else
                    f"no job a re-run of {CMUX_NEXT_PLACEMENT_JOB} would repeat has run")
            return Failover(f"{done}, and {stuck}", plan)
        if look == 2:
            return NO_FAILOVER
        sleep(UNSTARTED_STALL_SECONDS - waited)
    return NO_FAILOVER


def failover_receipt(api: GitHub, target: Target, why: str, sleep: Callable[[float], None],
                     log: Callable[[str], None], plan: PlacementRerun | None = None, *,
                     settled: bool = False) -> Callable[[], None]:
    """The re-dispatch receipt of an open-head failover: what was cancelled and why, as a notice annotation on the
    rescue's run and a line in its log (and step summary). Read from the jobs before the cancel, and given by the
    returned call once the cancel went out: a guard or deadline that drops the cancel leaves no receipt. Never
    raises: a failed read only shortens it."""
    try:
        jobs = read(lambda: api.jobs(target.run_id, target.attempt), sleep, log)
    except Exception:  # noqa: BLE001 - the receipt never stops the failover
        jobs = []
    queued = sorted(f"{job.get('name')} on {mac_route(job) or 'linux'}" for job in jobs
                    if not failover_loses(job, plan) and job.get("status") != "completed")
    placed = sorted(str(job.get("name")) for job in jobs if str(job.get("name") or "") in PLACEMENT_JOBS
                    and job.get("conclusion") == "success" and (plan is None or plan.reruns(job)))
    how = "re-run in full" if plan is None else f"re-run from {CMUX_NEXT_PLACEMENT_JOB}"
    kept = "" if plan is None else "; finished jobs kept: " + (", ".join(sorted(
        str(job.get("name")) for job in jobs if job.get("status") == "completed"
        and job.get("conclusion") != "skipped" and not plan.reruns(job))) or "none")
    line = (f"run {target.run_id} attempt {target.attempt} of PR #{target.pr_number} at {target.head_sha[:12]}: "
            f"cancelled and {how} because {why}. Queued jobs cancelled: {', '.join(queued) or 'none'}; "
            f"placement jobs repeated: {', '.join(placed) or 'none'}{kept}")
    if settled:
        # The settled-sibling failover: the finished jobs keep their results, and only what waited runs again.
        waiting = sorted(f"{job.get('name')} on {mac_route(job) or 'linux'}" for job in jobs
                         if job.get("status") != "completed")
        done = sum(1 for job in jobs if job.get("status") == "completed")
        line = (f"run {target.run_id} attempt {target.attempt} of PR #{target.pr_number} at {target.head_sha[:12]}: "
                f"cancelled because {why}; only what waited is re-run. Queued jobs cancelled: "
                f"{', '.join(waiting) or 'none'}; finished jobs kept: {done}")

    def emit() -> None:
        log(f"{OPEN_HEAD_FAILOVER} receipt: {line}")
        print(f"::notice title=Open-head failover::{line}", flush=True)
    return emit


def open_head_guard(api: GitHub, target: Target, sleep: Callable[[float], None], log: Callable[[str], None],
                    before_cancel: Callable[[], None] | None,
                    plan: PlacementRerun | None = None) -> Callable[[], None]:
    """rescue()'s before_cancel for an open-head failover, right before the cancel and every re-send of it: the run
    must still be this attempt and unfinished (a cancel hits the run's current attempt, which another watch's re-run
    may have started), and no job of it may have started since (failover_loses(), with the failover's `plan`). Else
    the cancel is dropped (OpenHeadStarted). The jobs are read last, after the run, as in settled_guard(): a run read
    slowed by a rate limit or a retry must not leave a jobs read from before it, in which a job that started or
    queued meanwhile (one the re-run would leave cancelled) is missing."""
    def check() -> None:
        if before_cancel is not None:
            before_cancel()
        run = read(lambda: api.run(target.run_id), sleep, log) or {}
        attempt = int(run.get("run_attempt") or 0)
        if attempt != target.attempt:
            raise OpenHeadStarted(f"the run is at attempt {attempt}, not {target.attempt}")
        if run.get("status") == "completed":
            raise OpenHeadStarted("the run has finished")
        jobs = read(lambda: api.jobs(target.run_id, target.attempt), sleep, log)
        if len(jobs) >= MAX_JOB_PAGES * 100:
            raise OpenHeadStarted(f"the run lists {len(jobs)} jobs, maybe more, so none can be shown unstarted")
        taken = sorted(str(job.get("name") or job.get("id")) for job in jobs if failover_loses(job, plan))
        if taken:
            raise OpenHeadStarted(f"{', '.join(taken)} started before the cancel")
    return check


def settled_guard(api: GitHub, target: Target, sleep: Callable[[float], None], log: Callable[[str], None],
                  before_cancel: Callable[[], None] | None, only_job: int) -> Callable[[], None]:
    """rescue()'s before_cancel for a settled-sibling failover (open_head_failover()'s `settled`), right before the
    cancel and every re-send of it: the run must still be this attempt and unfinished, no job of it may be running
    or held by a runner (job_running()), and `only_job` must still be listed, unfinished and its one unfinished job
    (the one the re-run brings back). Else the cancel is dropped (OpenHeadStarted)."""
    def check() -> None:
        if before_cancel is not None:
            before_cancel()
        run = read(lambda: api.run(target.run_id), sleep, log) or {}
        attempt = int(run.get("run_attempt") or 0)
        if attempt != target.attempt:
            raise OpenHeadStarted(f"the run is at attempt {attempt}, not {target.attempt}")
        if run.get("status") == "completed":
            raise OpenHeadStarted("the run has finished")
        # The jobs after the run: a run read slowed by a rate limit or a retry must not leave a jobs read from
        # before it, in which a job that started meanwhile still looks queued.
        jobs = read(lambda: api.jobs(target.run_id, target.attempt), sleep, log)
        if len(jobs) >= MAX_JOB_PAGES * 100:
            raise OpenHeadStarted(f"the run lists {len(jobs)} jobs, maybe more, so none can be shown idle")
        taken = sorted(str(job.get("name") or job.get("id")) for job in jobs if job_running(job))
        if taken:
            raise OpenHeadStarted(f"{', '.join(taken)} started before the cancel")
        stalled = next((job for job in jobs if job.get("id") == only_job), None)
        if stalled is None:
            raise OpenHeadStarted(f"job {only_job} is no longer listed")
        if stalled.get("status") == "completed":
            raise OpenHeadStarted(f"{stalled.get('name') or only_job} finished before the cancel")
        others = sorted(str(job.get("name") or job.get("id")) for job in jobs
                        if job.get("status") != "completed" and job.get("id") != only_job)
        if others:
            raise OpenHeadStarted(f"{', '.join(others)} queued before the cancel, and the re-run of job {only_job} "
                                  "would leave it cancelled")
    return check


_DELIVERY_CONTROL_JOBS = frozenset({
    "decide", "runner", "changes", "pick-nightly-app-runner", "pick-nightly-build-runner", "pick-nightly-sign-runner",
    "pick-classic-sign-runner", "pick-classic-prepare-runner", "resolve-nightly-cmux-tui-client",
    "resolve-nightly-ghostty-cli-helper", "find-nightly-next-recovery", "probe-nightly-tag-permission",
})


def _started_delivery_job(job: Mapping[str, Any]) -> bool:
    """Whether a delivery job has started work (or has a runner assigned).

    A jobs listing can be behind the workflow graph: a later signing job may
    not exist until an earlier build has completed.  Looking only for current
    ``in_progress`` jobs therefore lets a queue rescue cancel a started
    nightly between those two listings.  Unassigned queued/waiting jobs and
    skipped or never-acquired cancellations are the only non-started states.
    """
    name = str(job.get("name") or "").split("(", 1)[0].strip()
    if name in _DELIVERY_CONTROL_JOBS:
        return False
    status = job.get("status")
    assigned = bool(job.get("runner_name") or job.get("runner_id"))
    if status in ("queued", "waiting", "pending", "requested") and not assigned:
        return False
    if status == "completed" and not assigned and job.get("conclusion") in ("skipped", "cancelled", "action_required"):
        return False
    return True


def _started_delivery_jobs(jobs: Sequence[Mapping[str, Any]]) -> str:
    """Names of delivery jobs that have run, in stable order."""
    started = sorted(str(job.get("name") or job.get("id")) for job in jobs if _started_delivery_job(job))
    return ", ".join(started)


def started_nightly_work(api: GitHub, target: Target, sleep: Callable[[float], None],
                         log: Callable[[str], None]) -> str:
    """For a nightly, read just before a cancel whether any work has started.

    Completed build/sign/publish jobs count as started too: a later queued
    sibling may only appear after them.  A nightly is never cancelled for a
    queue alarm once that work exists.  ``""`` means no work (or not a
    nightly).  ``assess()`` checked the same on its look, but a sibling can
    appear between that look and the cancel.
    """
    if not target.nightly:
        return ""
    jobs = read(lambda: api.jobs(target.run_id, target.attempt), sleep, log)
    return _started_delivery_jobs(jobs)


def started_delivery_work(api: GitHub, target: Target, sleep: Callable[[float], None],
                          log: Callable[[str], None]) -> str:
    """Read a delivery run's jobs before a queue rescue and fail closed.

    ``cmux-next.yml`` carries the DEV source/promote dispatch under a shared
    path, so its trusted push/dispatch runs are included explicitly.  Pull
    request test runs remain ordinary CI and keep their existing rescue path.
    """
    delivery = target.nightly or never_fails_over(target.path, target.event) or (
        target.e2e and target.path == CMUX_NEXT_WORKFLOW_PATH and target.event in TRUSTED_SIDE_EVENTS)
    if not delivery:
        return ""
    jobs = read(lambda: api.jobs(target.run_id, target.attempt), sleep, log)
    return _started_delivery_jobs(jobs)


def rescue(api: GitHub, target: Target, *, now: Callable[[], dt.datetime], sleep: Callable[[float], None],
           log: Callable[[str], None], failed_only: bool = False,
           deadline: dt.datetime | None = None, refused: bool | None = None, refusal: bool = False,
           before_cancel: Callable[[], None] | None = None,
           first_seen: Mapping[Any, dt.datetime] | None = None) -> str:
    """Cancel and re-run, unless the pull request has moved on. Returns what happened.

    `first_seen` (the watcher's: job id -> when it first saw the job queued) dates a job's wait for the open-head
    failover (unstarted_failover()) when GitHub's job record has no created_at.

    `before_cancel` runs right before the cancel is sent and before every re-send of it (GitHub.cancel()), and
    raises to leave the run alone (rescue_stalled_signing()).

    `failed_only` (a refused job) re-runs only the failed and cancelled jobs,
    keeping what passed, and needs no cancel when the run already finished.
    `refused` (default `failed_only`) is whether a run that already finished
    may be re-run: an E2E run stuck in the queue that then finished was
    likely cancelled by a newer dispatch, which re-running it would cancel.
    `refusal` is whether the fleet refused a job (not merely left it queued).
    """
    # Main's run is re-run after a refusal whether or not main moved: the
    # refusal is the fleet's, and a red run would open main's red-CI issue.
    # A stuck later attempt re-runs its failed jobs too, but is no refusal.
    keep_main = target.main and refusal
    # Before anything that cancels or re-runs (the moved-head cancel below included): a nightly whose build failed
    # to compile is left as GitHub has it (nightly_compile_red()).
    red = nightly_compile_red(api, target, sleep, log)
    if red:
        return compile_red_answer(red)
    moved = "" if keep_main else pull_moved(api, target, sleep, log)
    if moved and target.push_branch and target.path == CMUX_NEXT_WORKFLOW_PATH:
        # cmux-next.yml queues each push Mac job in a group per branch (one
        # runs, one waits, a newer push replaces only the waiting one), so a
        # newer push never makes this run cancel. Cancelling here killed every
        # tip run's running jobs at one push a minute (2026-10-07: no tip swift
        # test completed from 00:20Z to 01:05Z). Not re-run either: a re-run
        # would join the branch group and replace the newer run's waiting job.
        return f"not rescued: {moved}; a cmux-next push run is never cancelled for a newer push"
    if moved and (target.main or target.nightly or target.push_branch):
        # Main's stuck run holds its concurrency group, so nothing newer can
        # start until it finishes: cancel it, and its completion dispatches
        # the new HEAD. A superseded push run only holds a slot the newer run needs.
        run = read(lambda: api.run(target.run_id), sleep, log)
        if not run:
            return f"not rescued: the run could not be read ({moved})"
        if int(run.get("run_attempt") or 0) != target.attempt:
            return "not rescued: someone else already re-ran the run"
        if run.get("status") == "completed":
            return f"not rescued: {moved}"
        busy = started_delivery_work(api, target, sleep, log)
        if busy:
            return f"{NIGHTLY_BUSY} ({busy}); {moved}, but started delivery work is never cancelled"
        try:
            nightly_cancel(api, target, sleep, log)
        except NightlyBusy as busy_now:
            return f"{NIGHTLY_BUSY} ({busy_now}); {moved}, but started delivery work is never cancelled"
        return f"cancelled run {target.run_id}, not re-run: {moved}"
    if moved:
        return f"not rescued: {moved}"
    run = read(lambda: api.run(target.run_id), sleep, log)
    if int(run.get("run_attempt") or 0) != target.attempt:
        return "not rescued: someone else already re-ran the run"
    failover = ""
    plan: PlacementRerun | None = None
    only_job: int | None = None
    receipt: Callable[[], None] | None = None
    if run.get("status") != "completed" and target.pr_number:
        # pull_moved() just read the pull request open at this head. Run 40398277457 (PR #25446)
        # attempt 1 was cancelled here and re-run in-process; nothing automatic cancels such a run now,
        # except the stall-aware failover where nothing is lost (open_head_failover()).
        found = open_head_failover(api, target, now=now, sleep=sleep, log=log, first_seen=first_seen)
        failover, plan = found.why, found.plan
        if not failover:
            return f"not rescued: PR #{target.pr_number} is open at the run's head; {OPEN_HEAD_RULE}"
    if failover and found.settled:
        only_job = found.only_job
        log(f"{OPEN_HEAD_FAILOVER}: {failover}; cancelling run {target.run_id} to re-run only what waited")
        receipt = failover_receipt(api, target, failover, sleep, log, settled=True)
        # Only what waited runs again: every finished job keeps its result.
        failed_only = True
        before_cancel = settled_guard(api, target, sleep, log, before_cancel, found.only_job)
    elif failover:
        log(f"{OPEN_HEAD_FAILOVER}: {failover}; cancelling run {target.run_id} to re-run "
            + ("every job" if plan is None else f"{CMUX_NEXT_PLACEMENT_JOB} and the jobs that need it")
            + " at its head")
        receipt = failover_receipt(api, target, failover, sleep, log, plan)
        # The placement runs again and checks the routes afresh (a re-run of failed jobs would keep its old
        # outputs): with every job, or (cmux-next) with the jobs that need it, keeping the rest's results.
        failed_only = False
        before_cancel = open_head_guard(api, target, sleep, log, before_cancel, plan)
    if run.get("status") != "completed" and deadline is not None and \
            (deadline - now()).total_seconds() < CANCEL_WAIT_SECONDS + RERUN_MARGIN_SECONDS + max(
                0.0, RATE_LIMIT_WAIT_SECONDS - getattr(api, "rate_limit_waited", RATE_LIMIT_WAIT_SECONDS)):
        # (The rate-limit waits this watch may still make count too: they do not shorten the settle.)
        # A job killed between the cancel and the re-run would leave the
        # pull request's run cancelled for good; leave it as GitHub has it.
        return "not rescued: too little of the job left to cancel and re-run"
    if run.get("status") == "completed" and run.get("conclusion") == "cancelled":
        # This rescue sent no cancel. One someone made after the watch looked (a person, the queue janitor, a newer
        # dispatch) is final, even beside a refusal; a job timeout names no canceller and is re-run as before.
        by = canceller(api, read(lambda: api.jobs(target.run_id, target.attempt), sleep, log), sleep, log)
        if by is None:
            return "not rescued: the run was cancelled, and who cancelled it could not be read; left cancelled"
        if by:
            return f"not rescued: the run was cancelled by @{by} meanwhile; left cancelled"
    if run.get("status") == "completed":
        should_rerun = failed_only if refused is None else refused
        if not should_rerun:
            return "not rescued: the run already finished"
        if not failed_only:
            api.rerun(target.run_id, target.attempt + 1)
            return f"re-ran every job of run {target.run_id}; {next_attempt(target)}"
        if e2e_build_unfinished(api, target, sleep, log):
            api.rerun(target.run_id, target.attempt + 1)
            return f"re-ran every job of run {target.run_id}, so its sibling wait runs again; {next_attempt(target)}"
        return rerun_failed_or_repick(api, target, sleep, log, refusal=refusal)
    if target.path == CMUX_NEXT_WORKFLOW_PATH:
        # Only cmux-next.yml places jobs on the freshness slot (macos-placement's fresh_runner).
        jobs = read(lambda: api.jobs(target.run_id, target.attempt), sleep, log)
        slot = started_dev_compile(jobs)
        if slot:
            return f"not rescued: a DEV feed compile started on {slot}; a started dev build is never cancelled"
    busy = started_delivery_work(api, target, sleep, log)
    if busy:
        return f"{NIGHTLY_BUSY} ({busy}); started delivery work is never cancelled"
    try:
        nightly_cancel(api, target, sleep, log, before_cancel)
    except NightlyBusy as busy_now:
        return f"{NIGHTLY_BUSY} ({busy_now}); it started just before the cancel, and started delivery work is never cancelled"
    except OpenHeadStarted as started_now:
        return f"not rescued: PR #{target.pr_number} is open at the run's head; {OPEN_HEAD_RULE} ({started_now})"
    if receipt is not None:
        receipt()
    # The re-run to follow, for a successor if this job stops first (rerun_intended()): one job and its dependents
    # (a placement failover's placement job, a settled-sibling failover's waiting job), every job, or the failed ones.
    one = only_job if only_job is not None else plan.job_id if failover and plan is not None else None
    tail = ONE_JOB.format(one) if one is not None else EVERY_JOB if not failed_only else ""
    log(f"{CANCEL_SENT} run {target.run_id} attempt {target.attempt}{tail}")
    try:
        result = settle_and_rerun(api, target, now=now, sleep=sleep, log=log, failed_only=failed_only,
                                  keep_main=keep_main, refusal=refusal, placement=plan, only_job=only_job)
    except Exception:
        # An error ends this rescue for good (gave_up()); the run's attempt is as GitHub has it, not a stopped job's.
        # An open-head failover's cancel is a pull request's run at its head: leave CANCEL_SENT unsettled, so a
        # successor finishes the re-run (rerun_intended()) instead of leaving the run cancelled.
        if not failover:
            settled_here(api, target, log)
        raise
    # Not on a KeyboardInterrupt or SystemExit (GitHub cancelling the rescue job, its timeout): that job stopped here,
    # and CANCEL_SENT alone tells its successor so.
    settled_here(api, target, log)
    return result


# The (run id, attempt) pairs this process logged CANCEL_SETTLED for. Its own log is unreadable until its job
# ends (rescue_jobs() skips the reader's own run), so a later watch in the same sweeper reads this instead.
SETTLED_HERE: set[tuple[int, int]] = set()


def settled_here(api: Any, target: Target, log: Callable[[str], None]) -> None:
    """Logs CANCEL_SETTLED for the target's attempt and remembers it for this process."""
    with _SETTLED_LOCK:
        SETTLED_HERE.add((target.run_id, target.attempt))
    log(f"{CANCEL_SETTLED} run {target.run_id} attempt {target.attempt}")


def resume_rerun(api: GitHub, target: Target, *, now: Callable[[], dt.datetime], sleep: Callable[[float], None],
                 log: Callable[[str], None], every_job: bool, only_job: int | None = None) -> str:
    """The re-run a stopped rescue meant after its cancel (rerun_intended()), with its own CANCEL_SETTLED mark.
    `only_job` (a settled-sibling failover's mark) re-runs that job and its dependents, never the failed jobs.
    A nightly whose head does not compile (nightly_compile_red()) is settled without it."""
    red = nightly_compile_red(api, target, sleep, log)
    if red:
        settled_here(api, target, log)
        return compile_red_answer(red)
    try:
        result = settle_and_rerun(api, target, now=now, sleep=sleep, log=log, failed_only=not every_job,
                                  keep_main=False, only_job=only_job)
    except Exception:
        # A pull request's run (cancelled by an open-head failover, unstarted_failover()) stays unsettled when its
        # re-run fails, so the next successor tries again instead of leaving the run cancelled at its open head.
        if not target.pr_number:
            settled_here(api, target, log)
        raise
    settled_here(api, target, log)
    return result


def settle_and_rerun(api: GitHub, target: Target, *, now: Callable[[], dt.datetime], sleep: Callable[[float], None],
                     log: Callable[[str], None], failed_only: bool, keep_main: bool, refusal: bool = False,
                     placement: PlacementRerun | None = None, only_job: int | None = None) -> str:
    """rescue() after its cancel went out: wait for the run to settle, then re-run it unless its head moved.
    `refusal` is rescue()'s (rerun_failed_or_repick()). `placement` (an open-head failover of a cmux-next run)
    re-runs that job and the jobs that need it instead of every job; GitHub refusing that re-run is reported, never
    widened to every job, which would repeat the finished jobs the placement failover keeps. `only_job` (a settled-sibling failover's one waiting job,
    open_head_failover()) re-runs that job and every job that needs it instead of the failed jobs."""
    log(f"cancelled run {target.run_id}")
    started = now()
    # Time spent waiting through rate limits (GitHub.request) is not the run's settling time:
    # counting it could end the settle window before the re-run (the job timeout has room for it).
    limited_at_cancel = getattr(api, "rate_limit_waited", 0.0)
    forced_at: float | None = None
    while True:
        sleep(10)
        run = read(lambda: api.run(target.run_id), sleep, log)
        if int(run.get("run_attempt") or 0) != target.attempt:
            return "not rescued: someone else already re-ran the run"
        if run.get("status") == "completed":
            break
        waited = (now() - started).total_seconds() - (getattr(api, "rate_limit_waited", 0.0) - limited_at_cancel)
        if (forced_at is None and waited >= FORCE_CANCEL_AFTER_SECONDS) or \
                (forced_at is not None and waited - forced_at >= FORCE_CANCEL_AGAIN_SECONDS):
            forced_at = waited
            try:
                api.force_cancel(target.run_id)
                log(f"force-cancelled run {target.run_id} ({round(waited)}s after cancel)")
            except urllib.error.HTTPError as error:
                # Most likely the run settled since the read; the next read
                # sees it. Aborting here would leave it cancelled for good.
                log(f"force-cancel of run {target.run_id} refused ({error.code}); still waiting")
        if waited >= CANCEL_WAIT_SECONDS:
            raise Aborted(f"run {target.run_id} did not finish {CANCEL_WAIT_SECONDS}s after cancel; not re-run")
    # A push during the cancel starts the new head's run; re-running the old
    # head now would join its concurrency group and cancel it.
    moved = "" if keep_main else pull_moved(api, target, sleep, log)
    if moved:
        return f"cancelled but not re-run: {moved}"
    if failed_only and only_job is not None:
        try:
            api.rerun_job(target.run_id, only_job, target.attempt + 1)
        except urllib.error.HTTPError as error:
            # Refused (GitHub declines a job it cannot re-run): no fallback. A re-run of the failed jobs would repeat
            # the finished failures the settled-sibling failover keeps; the run stays as GitHub has it.
            return (f"not re-run: GitHub refused the re-run of job {only_job} of run {target.run_id} "
                    f"({error.code}); its finished jobs keep their results")
        return (f"re-ran job {only_job} of run {target.run_id} and every job that needs it, keeping every finished "
                f"job; {next_attempt(target)}")
    if failed_only:
        if e2e_build_unfinished(api, target, sleep, log):
            api.rerun(target.run_id, target.attempt + 1)
            return f"re-ran every job of run {target.run_id}, so its sibling wait runs again; {next_attempt(target)}"
        return rerun_failed_or_repick(api, target, sleep, log, refusal=refusal)
    if placement is not None:
        try:
            api.rerun_job(target.run_id, placement.job_id, target.attempt + 1)
        except urllib.error.HTTPError as error:
            # Refused (GitHub declines a job it cannot re-run): no fallback. A re-run of every job would repeat the
            # finished Linux jobs, a red check included, that the placement failover keeps; the run stays as GitHub
            # has it.
            return (f"not re-run: GitHub refused the re-run of {CMUX_NEXT_PLACEMENT_JOB} (job {placement.job_id}) "
                    f"of run {target.run_id} ({error.code}); its finished jobs keep their results")
        return (f"re-ran {CMUX_NEXT_PLACEMENT_JOB} of run {target.run_id} and every job that needs it; attempt "
                f"{target.attempt + 1} places its Mac jobs afresh and keeps every other finished job")
    api.rerun(target.run_id, target.attempt + 1)
    if target.attempt + 1 <= LAST_OWNED_ATTEMPT and not target.e2e:
        return (f"re-ran run {target.run_id}; attempt {target.attempt + 1} picks again, the owned machines "
                "free now first, and the sweeper watches it")
    return f"re-ran run {target.run_id}; attempt {target.attempt + 1} takes an ephemeral pool"


# rescue_stalled_signing()'s answer when its own last look found the run changed; follow() watches on after it.
SIGN_NOT_YET = "not rescued yet: "


class SignStallChanged(Aborted):
    """A signing stall no longer holds at the look right before its cancel (rescue_stalled_signing())."""


def rescue_stalled_signing(api: GitHub, target: Target, *, now: Callable[[], dt.datetime],
                           sleep: Callable[[float], None], log: Callable[[str], None],
                           deadline: dt.datetime | None, sign_seen: Mapping[Any, dt.datetime] | None = None,
                           workflow_text: str | None = None) -> str:
    """Cancel a nightly-next run whose only unfinished jobs are signing jobs stalled on Blacksmith macOS, then
    re-run it. Attempt 1 re-runs its failed jobs: only those jobs (and what needs them) run again, on their
    alternate label. A later attempt is re-run in full (signing_rerun_full()), so its pickers choose again.

    The jobs are read again first, with the watch's first-seen times and the gate (gated_signing_stall()), so
    a job that started, a sibling that came back or a job without the alternate leaves the run alone, and
    rescue() reads the run's attempt and status before it cancels. The same look runs again right before
    the cancel is sent, after any token mint, and before every re-send of it (a rate-limit wait can last
    minutes), so a job that started in the meantime leaves the run alone; only the cancel request itself
    remains between that look and GitHub acting on it, in which a job a runner just took has done no work. A cancel whose re-run fails
    leaves the run cancelled, which gave_up() annotates and nightly-next-tick.yml re-runs
    (scripts/ci/nightly_next_cancelled_tip.sh).
    """
    seen: dict[Any, dt.datetime] = {} if sign_seen is None else sign_seen

    # A compiler diagnostic is the explicit "certain to fail" exception: do
    # not let the queue guard hide the useful compile-red explanation.
    compile_red = nightly_compile_red(api, target, sleep, log)
    if compile_red:
        return compile_red_answer(compile_red)

    def look() -> Look | None:
        jobs = read(lambda: api.jobs(target.run_id, target.attempt), sleep, log)
        at = now()
        for job in jobs:
            # A job first seen queued here counts from now, as in watch(): it is not stalled yet.
            if sign_job_key(job) and waiting_for_runner(job):
                seen.setdefault(job.get("id"), at)
        return gated_signing_stall(jobs, at, seen, workflow_text)

    def still_stalled() -> None:
        # The cancel acts on the run's current attempt: never one someone else started since.
        run = read(lambda: api.run(target.run_id), sleep, log) or {}
        if int(run.get("run_attempt") or 0) != target.attempt or run.get("status") == "completed":
            raise SignStallChanged(f"the run is at attempt {run.get('run_attempt')} "
                                   f"({run.get('status') or 'unknown'}), not attempt {target.attempt} in progress")
        started = started_delivery_work(api, target, sleep, log)
        if started:
            raise SignStallChanged(f"started delivery work ({started}); a queued signing job is left alone")
        found = look()
        if found is None or found.action != "stalled":
            raise SignStallChanged(found.reason if found else "no signing job is stalled any more")

    try:
        still_stalled()
        full = signing_rerun_full(target.attempt)
        result = rescue(api, target, now=now, sleep=sleep, log=log, failed_only=not full, deadline=deadline,
                        refused=False, before_cancel=still_stalled)
    except SignStallChanged as changed:
        # Raised before the cancel was sent (or re-sent): the run is as GitHub has it.
        return f"{SIGN_NOT_YET}{changed}"
    if result.startswith("re-ran the failed jobs"):
        result += "; its signing jobs take their alternate macOS label on that attempt"
    elif result.startswith("re-ran run"):
        result = (f"re-ran every job of run {target.run_id}: attempt {target.attempt}'s own pick is the label that "
                  f"stalled, so attempt {target.attempt + 1}'s pickers choose its signing labels again, never a "
                  "stalled one")
    return result


def gave_up(target: Target, error: BaseException) -> str:
    """The give-up line; for a nightly an error annotation, since its run may now sit cancelled.

    nightly-next-tick.yml re-runs a nightly-next tip whose newest run is cancelled, so the
    tip still builds; the annotation says why it needed to."""
    text = f"gave up: {error}"
    if target.nightly:
        text = (f"::error title=nightly rescue::run {target.run_id} {text}; if it was cancelled, "
                "the nightly-next tick re-runs it (nightly-next-tick.yml)")
    return text


def main(argv: Sequence[str] | None = None, env: Mapping[str, str] | None = None, *,
         api: GitHub | None = None, now: Callable[[], dt.datetime] | None = None,
         sleep: Callable[[float], None] = time.sleep) -> int:
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.parse_args(argv)
    clock = now or (lambda: dt.datetime.now(dt.timezone.utc))
    lines: list[str] = []

    def log(text: str) -> None:
        print(text, flush=True)
        lines.append(text)

    clients: list[Any] = []

    def finish(outcome: str) -> int:
        log(outcome)
        if clients and hasattr(clients[0], "usage"):
            log(clients[0].usage())  # this job's REST spend, for the per-workflow budget
        if env.get("GITHUB_STEP_SUMMARY"):
            with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
                handle.write("### Persistent-pool rescue\n\n" + "\n".join(f"- {line}" for line in lines) + "\n")
        return 0

    if (env.get("POOL_OWNED") or "").strip() != "1":
        return finish("owned pools are off (CI_PR_POOL_OWNED is not 1); nothing to watch")
    if int((env.get("GITHUB_RUN_ATTEMPT") or "1").strip() or 1) > 1:
        # A re-run of a rescue run keeps the first attempt's creation time, so rescue_jobs() (which lists rescue runs
        # by creation) could miss the CANCEL_SETTLED it would log: it logs none. The next sweeper (every
        # schedule tick) adopts whatever it would have watched.
        return finish("a re-run of the rescue workflow acts on nothing; the next sweeper adopts the runs it watches")
    seconds = budget(env.get("RESCUE_SECONDS"))
    if seconds is None:
        return finish(f"CI_OWNED_POOL_RESCUE_SECONDS must be {MIN_BUDGET_SECONDS} to {MAX_BUDGET_SECONDS}; "
                      "nothing to watch")
    side_seconds = side_budget(env.get("SIDE_RESCUE_SECONDS"))
    if side_seconds is None:
        return finish(f"SIDE_RESCUE_SECONDS must be {MIN_BUDGET_SECONDS} to {MAX_BUDGET_SECONDS}; "
                      "nothing to watch")
    repository = env.get("GITHUB_REPOSITORY") or ""
    client = api or GitHub(env.get("GH_TOKEN") or env.get("GITHUB_TOKEN") or "", repository,
                           read_token=env.get("READ_TOKEN") or "")
    if hasattr(client, "own_run"):
        client.own_run = int((env.get("GITHUB_RUN_ID") or "0").strip() or 0)
    if api is None and env.get("BOT_APP_ID") and env.get("BOT_APP_KEY"):
        # GH_TOKEN is the App's: its replacement is minted before the hour is up (GitHub._fresh_token()).
        client.mint = app_token_minter(env["BOT_APP_ID"], env["BOT_APP_KEY"], repository)
    clients.append(client)
    if (env.get("SWEEP") or "").strip() == "1":
        # One job for every marked run (sweep()); its per-run lines go to the log only.
        outcomes = sweep(client, repository, seconds=seconds, queue_rounds=env.get("QUEUE_ROUNDS"),
                         now=clock, log=lambda text: print(text, flush=True), side_seconds=side_seconds)
        return finish("swept: " + (", ".join(f"{count} {outcome}" for outcome, count in sorted(outcomes.items()))
                                   or "no run needed a watch"))
    run_id = (env.get("WATCH_RUN_ID") or "").strip()
    if run_id:
        # Dispatched by the picker's job: read the run it names and check it
        # exactly as a workflow_run event's run would be.
        if not run_id.isdigit():
            return finish(f"not watched: run id {run_id!r} is not a number")
        try:
            event = {"workflow_run": read(lambda: client.run(int(run_id)), sleep, log)}
        except READ_ERRORS as error:
            skip = quota_skip(error)
            if skip:
                return finish(skip)
            finish(f"gave up: could not read run {run_id}: {error}")
            return 1
    else:
        with open(env["GITHUB_EVENT_PATH"], encoding="utf-8") as handle:
            event = json.load(handle)
    target = completed_target(event, repository) if event.get("action") == "completed" else \
        target_from_event(event, repository)
    if isinstance(target, str):
        return finish(f"not watched: {target}")
    if ((env.get("LATE_PLACEMENT") or "").strip() == "1" and target.attempt == 1
            and not (target.e2e or target.main or target.side)):
        target = dataclasses.replace(target, late=True)
    if hasattr(client, "end_on_spent"):
        # A nightly's watch still waits for the reset (nightly work comes first on the fleet); any other single watch
        # ends as an infra skip rather than hold its runner for up to an hour (GitHub.pace()).
        client.end_on_spent = not target.nightly
    try:
        return finish(follow(client, target, seconds=seconds, queue_rounds=env.get("QUEUE_ROUNDS"),
                             now=clock, sleep=sleep, log=log, side_seconds=side_seconds))
    except (*READ_ERRORS, Aborted) as error:
        # A failed watch leaves the run exactly as GitHub scheduled it. One that ran out of API budget is an infra
        # skip, green with a warning: nothing about the run was wrong, and the next sweeper looks again.
        skip = quota_skip(error)
        if skip:
            if target.nightly:
                skip += f"; if run {target.run_id} was cancelled, the nightly-next tick re-runs it (nightly-next-tick.yml)"
            return finish(skip)
        finish(gave_up(target, error))
        return 1


def follow(client: GitHub, target: Target, *, seconds: int, queue_rounds: str | None,
           now: Callable[[], dt.datetime], sleep: Callable[[float], None], log: Callable[[str], None],
           rescue_sleep: Callable[[float], None] | None = None, latest: dt.datetime | None = None,
           light_retry: bool = False, side_seconds: int | None = None) -> str:
    """Watch one run and rescue it when it needs it. Returns the outcome; raises READ_ERRORS or Aborted.

    The sweeper stops a watch by making `sleep` raise; a rescue paces itself
    with `rescue_sleep` (default `sleep`) so a cancel it started is always
    followed by its re-run, and `latest` caps the rescue deadline at the
    sweeper's end plus its grace.
    """
    rescue_sleep = rescue_sleep or sleep
    clock = now
    effective_seconds = side_seconds if target.path == CMUX_NEXT_WORKFLOW_PATH and side_seconds is not None else seconds
    if target.path == IOS_KIT_WORKFLOW_PATH:
        effective_seconds = min(effective_seconds, 180)

    def capped(deadline: dt.datetime) -> dt.datetime:
        return min(deadline, latest) if latest is not None else deadline

    subject = (f"pull request #{target.pr_number}'s {target.path}" if target.pr_number else
               "an E2E dispatch" if target.path == E2E_WORKFLOW_PATH else f"a dispatch of {target.path}") \
        if target.e2e else f"main's full-suite dispatch at {target.head_sha[:12]}" if target.main \
        else f"{target.push_branch or MAIN_BRANCH}'s nightly build at {target.head_sha[:12]}" if target.nightly \
        else f"pull request #{target.pr_number}" if target.pr_number else f"a run of {target.path}"
    if target.side and not target.nightly:
        subject += " (side lane)"
    # ci.yml's, test-ios.yml's and test-e2e.yml's pickers queue on purpose, within the queue
    # rounds: their owned jobs may wait up to the pool's expected wait (see the docstring).
    # A nightly build's wait for its reserved runner is never stuck (reserved_runner()), so it needs no
    # allowance here; a nightly job without one gets the configured budget like any side lane.
    queue_extra = queue_seconds(queue_rounds) if target.path in QUEUEING_WORKFLOW_PATHS else 0
    log(f"watching run {target.run_id} of {subject} (budget {effective_seconds + queue_extra}s"
        + (f": {effective_seconds}s past the {queue_extra}s an owned job may expect to wait)" if queue_extra else ")"))
    # A rescue may run past the watch deadline, within the job's own timeout,
    # so a cancel is never started without the time to settle and re-run.
    started = clock()
    deadline = started + dt.timedelta(seconds=target.watch_limit)
    rescue_deadline = capped(deadline + dt.timedelta(seconds=RESCUE_GRACE_SECONDS))
    # Every attempt gets the queue allowance: a re-run's owned jobs queue on the owned labels like attempt 1's.
    first_budget = effective_seconds + queue_extra
    seen: dict[Any, dt.datetime] = {}
    sign_seen: dict[Any, dt.datetime] = {}
    sign_text: list[str | None] = []
    outcome, reason = watch(client, target, budget_seconds=first_budget, now=clock, sleep=sleep,
                            log=log, deadline=deadline, floor_seconds=effective_seconds, seen=seen,
                            sign_seen=sign_seen, sign_text=sign_text)

    def settle(outcome: str, reason: str) -> tuple[str, str, str, str]:
        """The stall hold and the signing-stall rescue on a look's outcome, watching on as they need:
        (outcome, reason, held, done), where `done` is follow()'s answer once one of them ended the watch."""
        held = ""
        while True:
            if outcome == "rescue" and not target.refusals_only:
                outcome, reason, held = hold_for_destination(
                    client, target, outcome, reason, budget_seconds=first_budget, floor_seconds=effective_seconds,
                    deadline=deadline, now=clock, sleep=sleep, log=log, seen=seen, sign_seen=sign_seen,
                    sign_text=sign_text)
            if outcome == "resume":
                result = resume_rerun(client, target, now=clock, sleep=rescue_sleep, log=log, every_job=reason == "all",
                                      only_job=int(reason[4:]) if reason.startswith("job:") else None)
                log(result)
                return outcome, reason, held, "done"
            if outcome != "stalled":
                return outcome, reason, held, ""
            log(f"stalled: {reason}")
            result = rescue_stalled_signing(client, target, now=clock, sleep=rescue_sleep, log=log,
                                            deadline=rescue_deadline, sign_seen=sign_seen,
                                            workflow_text=sign_text[0] if sign_text else None)
            log(result)
            # The run changed since the look (a job started, a sibling came back, a nightly job began running
            # just before the cancel): watch on, the next look decides.
            if not (result.startswith(SIGN_NOT_YET) or result.startswith(NIGHTLY_BUSY)):
                return outcome, reason, held, "done"
            if clock() >= deadline:
                return outcome, reason, held, ("stopped: watch limit reached with a started nightly still running"
                                               if result.startswith(NIGHTLY_BUSY) else "done")
            sleep(POLL_SECONDS)
            outcome, reason = watch(client, target, budget_seconds=first_budget, now=clock, sleep=sleep,
                                    log=log, deadline=deadline, floor_seconds=effective_seconds, seen=seen,
                                    sign_seen=sign_seen, sign_text=sign_text)

    outcome, reason, held, done = settle(outcome, reason)
    if done:
        return done
    # watch() found the open-head failover for a job left queued (a red sibling, a refusals-only watch, a hold):
    # rescue() checks it again and makes it, with no hold for a Blacksmith slot (its label runs nothing).
    offered = outcome == "failover"
    if offered:
        outcome = "rescue"
    if outcome not in ("rescue", "refused"):
        return f"stopped: {reason}" + (f"; kept on the owned pool: {held}" if held else "")
    # The stall-aware failover (unstarted_failover()) moves even a refusals-only attempt: its label runs nothing, so
    # the attempt is not waiting its turn in a queue, and a re-run places it again with the routes checked afresh.
    failover_now = offered or bool(
        target.refusals_only and outcome == "rescue" and target.pr_number
        and open_head_failover(client, target, now=clock, sleep=sleep, log=log, first_seen=seen))
    if target.refusals_only and outcome == "rescue" and not failover_now:
        # A refusals-only cmux-next attempt deliberately stays on its owned
        # label while it waits for the hook to refuse the job. A queue alarm
        # is not the refusal: keep the watch alive until the job fails or the
        # run finishes, otherwise the later refusal has no rescue owner.
        remaining = max(0, int((deadline - clock()).total_seconds()))
        if remaining == 0:
            return f"stopped: {reason}; attempt {target.attempt} stays on the minis (refusals only)"
        log(f"queue alarm while refusals-only; continuing until refusal or run finish ({remaining}s left)")
        outcome, reason = watch(client, target, budget_seconds=max(effective_seconds, remaining),
                                now=clock, sleep=sleep, log=log, deadline=deadline,
                                floor_seconds=effective_seconds)
        if outcome == "resume":
            # A rescue stopped between its cancel and its re-run while this watch waited: finish its re-run.
            return settle(outcome, reason)[3]
        if outcome == "failover":
            outcome, failover_now = "rescue", True
    if target.refusals_only and outcome != "refused" and not failover_now:
        return f"stopped: {reason}; attempt {target.attempt} stays on the minis (refusals only)"
    refusal_jobs: list[Mapping[str, Any]] | None = None
    dev_compile = False
    if outcome == "refused" and target.path == CMUX_NEXT_WORKFLOW_PATH:
        refusal_jobs = read(lambda: client.jobs(target.run_id, target.attempt), sleep, log)
        dev_compile = any(str(job.get("name") or "") in {
            "cmux NEXT DEV Release compile", "cmux-scheme-compile"
        } for job in refusal_jobs)
    # A refusal re-runs the run's failed jobs. A side lane (found by the failed-run listing, sweep()) or a
    # refusals-only run that also failed on its own would re-run that failure on the minis too, so it is
    # left red; a nightly keeps its re-run (its build is the product).
    if outcome == "refused" and (target.refusals_only or target.side and not target.nightly):
        jobs = refusal_jobs if refusal_jobs is not None else read(
            lambda: client.jobs(target.run_id, target.attempt), sleep, log)
        other = [str(job.get("name")) for job in jobs if job.get("conclusion") in ("failure", "timed_out")
                 and not carried(job, target.attempt_started_at) and not refused(job)]
        if other:
            # An `if: always()` aggregator that failed only because a job it needs was refused is
            # re-run with that job (downstream_of_refusals()); its `needs` come from the run's own file.
            excused: set[str] = set()
            try:
                text = read(lambda: client.workflow_file(target.path, target.head_sha), sleep, log)
                if text:
                    excused = downstream_of_refusals(text, jobs, target.attempt_started_at)
                else:
                    log(f"{target.path} is not at {target.head_sha[:12]}; no failure is put down to a refusal")
            except Aborted:
                raise  # the sweeper is handing over (Stopping)
            except Exception as error:  # noqa: BLE001 - an unreadable or invalid file only excuses nothing
                log(f"could not read {target.path}'s needs at {target.head_sha[:12]} "
                    f"({type(error).__name__}: {error}); no failure is put down to a refusal")
            if excused:
                log(f"{', '.join(sorted(excused))} failed only because a job it needs was refused; "
                    "the re-run of failed jobs re-runs it too")
            other = [name for name in other if name not in excused]
        if other:
            # A re-run of failed jobs would re-run these too: a real failure is never retried here.
            return (f"not rescued: attempt {target.attempt} also failed for a reason that is not a refusal "
                    f"({', '.join(sorted(other))})")
    log(f"{'rescue' if outcome == 'rescue' else 'refused'}: {reason}")
    while True:
        # From attempt 2 on, keep what passed: only the owned jobs are moved.
        # An E2E run always keeps what passed (see the module docstring).
        failed_only = (outcome == "refused" or target.attempt > 1 or target.e2e or target.side) and not dev_compile
        result = rescue(client, target, now=clock, sleep=rescue_sleep, log=log, failed_only=failed_only,
                        deadline=rescue_deadline,
                        refused=(outcome == "refused") if target.e2e or target.side else None,
                        refusal=outcome == "refused", first_seen=seen)
        log(result)
        if result.startswith(NIGHTLY_BUSY):
            # A sibling started after the look: watch on, as before, until nothing else runs or the watch ends.
            if clock() >= deadline:
                return "stopped: watch limit reached with a started nightly still running"
            outcome, reason = watch(client, target, budget_seconds=first_budget, now=clock, sleep=sleep, log=log,
                                    deadline=deadline, floor_seconds=effective_seconds, seen=seen,
                                    sign_seen=sign_seen, sign_text=sign_text)
            outcome, reason, held, done = settle(outcome, reason)
            if done:
                return done
            if outcome == "failover":
                outcome = "rescue"
            if outcome not in ("rescue", "refused"):
                return f"stopped: {reason}" + (f"; kept on the owned pool: {held}" if held else "")
            log(f"{'rescue' if outcome == 'rescue' else 'refused'}: {reason}")
            continue
        # Only an E2E full re-run picks a new runner in this watch. Other CI
        # re-runs are resumed by the sweeper through owned_reruns().
        if not target.e2e or not result.startswith("re-ran every job") or target.attempt + 1 > LAST_OWNED_ATTEMPT:
            return "done"
        full_rerun = True
        target = dataclasses.replace(target, attempt=target.attempt + 1, full_rerun=full_rerun, late=False)
        deadline = min(clock() + dt.timedelta(seconds=target.watch_limit), started + dt.timedelta(
            seconds=JOB_TIMEOUT_SECONDS - RESCUE_GRACE_SECONDS - JOB_TIMEOUT_MARGIN_SECONDS))
        rescue_deadline = capped(deadline + dt.timedelta(seconds=RESCUE_GRACE_SECONDS))
        seen = {}
        outcome, reason = watch(client, target, budget_seconds=effective_seconds, now=clock, sleep=sleep, log=log,
                                deadline=deadline, seen=seen)
        if outcome == "resume":
            # The next attempt was cancelled by a rescue that stopped before its re-run: finish that re-run.
            return settle(outcome, reason)[3]
        outcome, reason, held = hold_for_destination(
            client, target, outcome, reason, budget_seconds=effective_seconds, floor_seconds=None,
            deadline=deadline, now=clock, sleep=sleep, log=log, seen=seen)
        if outcome == "resume":
            # The hold watches on, and can find the same stopped rescue.
            return settle(outcome, reason)[3]
        if outcome not in ("rescue", "refused"):
            return f"stopped watching attempt {target.attempt}: {reason}" + (
                f"; kept on the owned pool: {held}" if held else "")
        log(f"attempt {target.attempt}: {'rescue' if outcome == 'rescue' else 'refused'}: {reason}")


# The sweeper (SWEEP=1). The pickers of ci.yml, test-e2e.yml and test-ios.yml
# upload an artifact named WATCH_MARKER when they place attempt 1 on an owned
# pool, and ci-macos.yml's late-placement uploads LATE_WATCH_MARKER when it
# moves jobs onto one. Listing each name repository-wide is one request that
# names every such run, finished or not, so one job watches them all: each
# run gets a thread running follow(), the per-run watch. The side lanes,
# which upload no marker, are found by one listing of failed runs a tick
# (GitHub.failed_runs()) and one of queued runs (GitHub.queued_side_runs()).
WATCH_MARKER = "owned-pool-watch"
LATE_WATCH_MARKER = "owned-pool-watch-late"
# cmux-next.yml's placement uploads this instead of WATCH_MARKER when it found
# no free Blacksmith slot: a re-run would only rejoin the same owned queue, so
# the run (and every re-run of it) is watched for refusals only (run
# 39615562861 was cancelled and re-run twice while it waited, 2026-10-21).
REFUSALS_WATCH_MARKER = "owned-pool-watch-refusals"
SWEEP_TICK_SECONDS = 60
# A sweeper adopts runs this long, then stops its watches and gives any rescue
# it started RESCUE_GRACE_SECONDS. ci-owned-pool-rescue.yml's two-hourly cron
# queues the next one in the concurrency group, so it starts as this one
# ends, and one dropped cron still leaves one queued.
SWEEP_SECONDS = 5 * 60 * 60
# Older runs are left alone: their watch would be past its limit. A run that
# finished (a refusal) during a handover is still inside it, so the next
# sweeper re-runs it.
SWEEP_MAX_AGE_SECONDS = E2E_WATCH_LIMIT_SECONDS
# A marker listing page covers this many runs, newest first by artifact id.
# One page held about two hours of owned placements on 2026-09-25 but only one
# on 2026-09-27 (87 an hour), and an artifact's id trails its upload time by
# up to 78 minutes (measured over 400 markers that day): six markers uploaded
# 11:51 to 12:15 took ids among markers an hour older, never reached page
# one, and two of their runs failed unrescued. So the sweeper pages back until
# a page ends MARKER_ORDER_SKEW past SWEEP_MAX_AGE_SECONDS, at most
# SWEEP_LISTING_PAGES.
SWEEP_LISTING = 100
SWEEP_LISTING_PAGES = 5
# The failed side-lane runs are listed every this many ticks: a refused job is re-run within about
# that many minutes, for at most SWEEP_LISTING_PAGES requests each time.
SIDE_FAILURE_TICKS = 5
MARKER_ORDER_SKEW = dt.timedelta(minutes=90)


class Stopping(Aborted):
    pass


# A run that finished this long before a sweeper started is left alone: the
# sweeper before it was running then and has already acted on it.
SWEEP_FINISHED_SECONDS = 30 * 60


def sweep_target(run: Mapping[str, Any], repository: str, *, late: bool, full_rerun: bool = False,
                 since: dt.datetime | None = None) -> Target | str:
    """The target for a marked run, resuming the attempt its rescue re-ran (LAST_OWNED_ATTEMPT at most).

    A finished run is only worth a look when it failed or was cancelled after `since`: a refusal nobody
    re-ran yet, or a rescue's cancel whose re-run never came (watch() re-runs it only when GitHub's
    the rescue logged its cancel and never settled it, rerun_intended()). `full_rerun` says the re-run ran the picker
    again (a stuck run's re-run, or a person's full one), so its own markers
    decide, the picker's and then late-placement's.
    """
    attempt = int(run.get("run_attempt") or 0)
    if attempt < 1 or attempt > LAST_OWNED_ATTEMPT and not owned_rerun(run):
        return f"attempt {attempt}"
    if run.get("status") == "completed":
        if run.get("conclusion") not in ("failure", "cancelled"):
            return f"finished ({run.get('conclusion')})"
        finished = parse_time(run.get("updated_at"))
        if since is not None and finished is not None and finished < since:
            return "finished before this sweeper's predecessor stopped"
    target = target_from_event({"workflow_run": {**run, "run_attempt": 1}}, repository)
    if isinstance(target, str):
        return target
    if attempt > 1:
        # A re-run (a rescue, the failure attribution, or a person): follow its owned jobs, if any.
        actor = str((run.get("triggering_actor") or {}).get("login") or "")
        return dataclasses.replace(target, attempt=attempt, full_rerun=full_rerun,
                                   late=full_rerun and not (target.e2e or target.main or target.side),
                                   refusals_only=(run.get("path") == CMUX_NEXT_WORKFLOW_PATH and actor in RESCUE_ACTORS
                                                  and attempt == REFUSAL_RESCUE_ATTEMPT))
    if late and not (target.e2e or target.main or target.side):
        return dataclasses.replace(target, late=True)
    return target


# A sweeper runs the code main had when it started for up to SWEEP_SECONDS. Every CODE_CHECK_TICKS ticks it
# compares that code (this script and the scripts/ci modules it imports) with main's; once main's differs it
# hands over early, as at SWEEP_SECONDS: no new adoptions, the rescues under way finish, and a fresh sweeper
# (dispatched, or the cron's pending one) starts on the new code. Run 40488669087 (2026-10-27) kept rescuing
# DEV daily runs with the code #26047 replaced for 3 hours after it merged.
CODE_DIRECTORY = "scripts/ci"
CODE_FILES = ("owned_pool_rescue.py", "pr_runner_pool.py", "simple_pool_picker.py", "owned_pool_sources.py",
              "ui_tests_dispatch.py")
CODE_CHECK_TICKS = 5
RESCUE_WORKFLOW_FILE = "ci-owned-pool-rescue.yml"
# A handover dispatches a sweeper only when none waits already (GitHub.waiting_sweeper()). The sweeper
# concurrency group holds one running and one pending run, and a newer pending run cancels the older one:
# the handover's dispatch cancelled the cron's pending sweeper before it ran (run 41071107039, cancelled
# at 14:56:46Z on 2026-10-30 by the dispatch of run 41076139116 three seconds earlier; 41055530432 at
# 14:08Z the same way). The waiting one checks out main when it starts, so it already runs the new code.
SWEEPER_TITLE = "owned-pool-sweeper"
SWEEPER_WAITING_STATUSES = ("pending", "queued")


def blob_sha(data: bytes) -> str:
    """Git's blob id for `data`, as the contents API reports it."""
    import hashlib

    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def running_code_shas(directory: Path | None = None) -> dict[str, str]:
    """The blob shas of CODE_FILES as this process loaded them ("" for one that is missing)."""
    root = directory or Path(__file__).resolve().parent
    shas: dict[str, str] = {}
    for name in CODE_FILES:
        try:
            shas[name] = blob_sha((root / name).read_bytes())
        except OSError:
            shas[name] = ""
    return shas


def code_changed(client: Any, running: Mapping[str, str], log: Callable[[str], None]) -> list[str]:
    """CODE_FILES whose blob on main differs from the running one; [] when unchanged or unreadable."""
    reader = getattr(client, "code_shas", None)
    if reader is None:
        return []
    try:
        current = reader(CODE_FILES)
    except Exception as error:  # noqa: BLE001 - a failed check must never end the sweep; the next one decides
        log(f"could not read main's {CODE_DIRECTORY} ({type(error).__name__}: {error}); next check")
        return []
    if not any(current.values()):
        return []  # an empty listing says nothing about the code
    return sorted(name for name in CODE_FILES if (current.get(name) or "") != (running.get(name) or ""))


def sweep(client: GitHub, repository: str, *, seconds: int, queue_rounds: str | None,
          now: Callable[[], dt.datetime], log: Callable[[str], None],
          sweep_seconds: int = SWEEP_SECONDS, tick_seconds: float = SWEEP_TICK_SECONDS,
          wait: Callable[[float], None] = time.sleep, light_retry: bool = False,
          side_seconds: int | None = None, running_code: Mapping[str, str] | None = None) -> dict[str, int]:
    """Watch every marked run until `sweep_seconds` pass, or main's code changes (code_changed()).
    Returns outcome counts."""
    # The sweeper's own listings raise on a rate limit as before (a failed read is tried next
    # tick); only the watch threads, which cancel and re-run, wait (RESCUE_GRACE_SECONDS has room).
    if hasattr(client, "no_rate_limit_waits"):
        client.no_rate_limit_waits()
    stopping = threading.Event()
    lock = threading.Lock()
    outcomes: dict[str, int] = {}
    seen: set[int] = set()
    rerun_seen: set[tuple[int, int]] = set()  # re-runs, once per attempt (owned_reruns())
    failed_seen: set[tuple[int, int]] = set()  # failed side-lane runs, once per attempt (failed_runs())
    queued_seen: set[tuple[int, int]] = set()  # queued side-lane runs, once per attempt (queued_side_runs())
    ticks = 0
    refusals_runs: set[int] = set()  # runs with REFUSALS_WATCH_MARKER, re-runs included
    threads: list[threading.Thread] = []
    # The watch thread of each adopted run: a side lane's watch stops once the fleet accepted its jobs,
    # and a runner stopped after that fails the run later, so the failed-run listing takes it up again.
    watching: dict[int, threading.Thread] = {}
    started = now()
    latest = started + dt.timedelta(seconds=sweep_seconds + RESCUE_GRACE_SECONDS)
    since = started - dt.timedelta(seconds=SWEEP_FINISHED_SECONDS)

    def watch_sleep(delay: float) -> None:
        if stopping.wait(delay):
            raise Stopping("the sweeper is handing over")

    def one(target: Target) -> None:
        def say(text: str) -> None:
            log(f"[run {target.run_id}] {text}")
        try:
            outcome = follow(client, target, seconds=seconds, queue_rounds=queue_rounds,
                             now=now, sleep=watch_sleep, log=say, rescue_sleep=wait, latest=latest,
                             light_retry=light_retry, side_seconds=side_seconds)
        except Stopping:
            outcome = "handed over"
        except QuotaSpent as error:
            outcome = "quota spent"
            say(f"stopped: {error.why}")
        except (*READ_ERRORS, Aborted) as error:
            outcome = "gave up"
            say(f"gave up: {error}")
            if target.nightly:
                log(gave_up(target, error))  # unprefixed, so the runner reads the annotation
        except Exception as error:  # noqa: BLE001 - one run's bug must not end every other watch
            outcome = "error"
            say(f"error: {type(error).__name__}: {error}")
        else:
            say(outcome)
        with lock:
            key = outcome.split(":")[0]
            outcomes[key] = outcomes.get(key, 0) + 1

    def adopt(run_id: int, late: bool, *, refusals_known: bool = True) -> bool:
        """Watch the run if it needs it. False when it could not be judged yet (a read failed): try later."""
        was_seen = run_id in seen
        seen.add(run_id)
        try:
            run = read(lambda: client.run(run_id), wait, log)
        except READ_ERRORS as error:
            seen.discard(run_id)  # the next tick tries again
            log(f"[run {run_id}] could not read the run ({error})")
            return False
        if not refusals_known and run.get("path") == CMUX_NEXT_WORKFLOW_PATH:
            # Without this tick's refusals listing a cmux-next re-run could lose its mark.
            if not was_seen:
                seen.discard(run_id)
            log(f"[run {run_id}] not adopted yet: the refusals markers were not listed; next tick")
            return False
        rerun_seen.add((run_id, int(run.get("run_attempt") or 0)))
        full_rerun = False
        if int(run.get("run_attempt") or 0) > 1:
            # A full re-run ran the picker again; a re-run of failed jobs kept attempt 1's.
            try:
                jobs = read(lambda: client.jobs(run_id, int(run["run_attempt"])), wait, log)
            except READ_ERRORS as error:
                seen.discard(run_id)
                # The re-run listing skips a pair in rerun_seen: forget it too, so the next tick adopts it.
                rerun_seen.discard((run_id, int(run.get("run_attempt") or 0)))
                log(f"[run {run_id}] could not read attempt {run['run_attempt']} ({error})")
                return False
            picker = E2E_PICKER_JOB if run.get("path") in DISPATCH_WORKFLOW_PATHS else PICKER_JOB
            attempt_started = parse_time(run.get("run_started_at") or run.get("created_at"))
            full_rerun = any(job.get("name") == picker and int(job.get("run_attempt") or 0) > 1
                             and not carried(job, attempt_started) for job in jobs)
        target = sweep_target(run, repository, late=late, full_rerun=full_rerun, since=since)
        if isinstance(target, str):
            log(f"[run {run_id}] not watched: {target}")
            return True
        if run_id in refusals_runs:
            target = dataclasses.replace(target, refusals_only=True)
        thread = threading.Thread(target=one, args=(target,), name=f"run-{run_id}", daemon=True)
        thread.start()
        threads.append(thread)
        watching[run_id] = thread
        return True

    code = dict(running_code_shas() if running_code is None else running_code)
    replaced: list[str] = []
    looks = 0
    while (now() - started).total_seconds() < sweep_seconds:
        if looks % CODE_CHECK_TICKS == 0:
            replaced = code_changed(client, code, log)
            if replaced:
                break
        looks += 1
        oldest = now() - dt.timedelta(seconds=SWEEP_MAX_AGE_SECONDS)
        # The picker's marker first: a run with both is watched the ordinary way.
        # Refusals-only runs are listed before the re-runs, which inherit the mark.
        refusals_listed = False
        for name, late in ((REFUSALS_WATCH_MARKER, False), (WATCH_MARKER, False), (LATE_WATCH_MARKER, True)):
            try:
                marked = client.marked_runs(name, SWEEP_LISTING, oldest, SWEEP_LISTING_PAGES, log=log)
            except READ_ERRORS as error:
                log(f"could not list {name} markers ({error}); next tick")
                continue
            refusals_listed = refusals_listed or name == REFUSALS_WATCH_MARKER
            for run_id, created in marked:
                if name == REFUSALS_WATCH_MARKER:
                    refusals_runs.add(run_id)  # at any age: a later re-run inherits it
                if run_id in seen or (created is not None and created < oldest):
                    continue
                adopt(run_id, late)
        # A re-run of failed jobs goes back to the minis with no marker of its own; two listings a tick.
        try:
            reruns = client.owned_reruns(SWEEP_LISTING)
        except READ_ERRORS as error:
            log(f"could not list re-runs ({error}); next tick")
            reruns = []
        if ticks % SIDE_FAILURE_TICKS == 0 and hasattr(client, "nightly_reruns"):
            # nightly-next's re-runs on Blacksmith (no marker), every SIDE_FAILURE_TICKS ticks: a signing stall
            # takes SIGN_STALL_SECONDS to call, so a few minutes' delay costs nothing.
            try:
                reruns = [*reruns, *client.nightly_reruns(SWEEP_LISTING)]
            except READ_ERRORS as error:
                log(f"could not list nightly-next re-runs ({error}); a later tick")
        for run_id, attempt in reruns:
            if (run_id, attempt) not in rerun_seen:
                adopt(run_id, False, refusals_known=refusals_listed)
        # A side lane uploads no marker: its run is found once a refused job has failed it, every
        # SIDE_FAILURE_TICKS ticks (paging through every workflow's failures costs a few requests).
        failed: list[tuple[int, int]] = []
        remaining = (client.budget_left()[0] if hasattr(client, "budget_left") else None)
        low = remaining is not None and remaining < BUDGET_FLOOR
        if ticks % SIDE_FAILURE_TICKS == 0 and low:
            log(f"{remaining} API requests left: the failed side-lane runs wait for a later tick")
            ticks -= 1  # listed on the first tick with the budget back
        elif ticks % SIDE_FAILURE_TICKS == 0:
            try:
                failed = client.failed_runs(SWEEP_LISTING, oldest, since, SWEEP_LISTING_PAGES)
            except READ_ERRORS as error:
                log(f"could not list failed runs ({error}); next tick")
                ticks -= 1  # try again on the next tick
            # A side-lane job waiting on a label that starts nothing never fails its run: list the queued ones
            # too, so the watch's open-head failover sees them. Run 41055587932 (nightly-next-launch-smoke.yml,
            # a pull request) waited over five hours on glaeda-side-std-xcode-26.6 on 2026-10-30, never watched.
            if hasattr(client, "queued_side_runs"):
                try:
                    queued = client.queued_side_runs(SWEEP_LISTING, oldest, SWEEP_LISTING_PAGES)
                except READ_ERRORS as error:
                    log(f"could not list queued side-lane runs ({error}); a later tick")
                    queued = []
                for run_id, attempt in queued:
                    if (run_id, attempt) in queued_seen or (run_id, attempt) in rerun_seen \
                            or attempt <= 1 and run_id in seen:
                        continue
                    if adopt(run_id, False, refusals_known=refusals_listed):
                        queued_seen.add((run_id, attempt))  # not before: a read that failed is tried again
        ticks += 1
        for run_id, attempt in failed:
            # A marked run's own watch (or the re-run listing) already follows it. One whose watch has
            # ended (it stopped once the fleet accepted the jobs, before a runner was stopped mid-job)
            # is taken up again, once per attempt.
            ended = run_id in watching and not watching[run_id].is_alive()
            followed = (run_id, attempt) in rerun_seen or attempt <= 1 and run_id in seen
            if (run_id, attempt) in failed_seen or followed and not ended:
                continue
            if adopt(run_id, False, refusals_known=refusals_listed):
                failed_seen.add((run_id, attempt))  # not before: a read that failed is tried again
        threads = [thread for thread in threads if thread.is_alive()]
        usage = f"; {client.usage()}" if hasattr(client, "usage") else ""
        log(f"tick: {len(threads)} run(s) watched, {remaining if remaining is not None else client.remaining or '?'} of "
            f"{client.limit or '?'} API requests left this hour{usage}")
        # Below BUDGET_FLOOR a tick every IDLE_POLL_SECONDS; spent, the next one after the reset.
        pause = client.pace(tick_seconds) if hasattr(client, "pace") else tick_seconds
        wait(min(pause, max(tick_seconds, sweep_seconds - (now() - started).total_seconds())))
    if replaced:
        log(f"main's {', '.join(replaced)} changed since this sweeper started; handing over to a sweeper on the "
            "new code")
        with lock:
            outcomes["code changed"] = outcomes.get("code changed", 0) + 1
        waiting = None
        try:
            waiting = client.waiting_sweeper() if hasattr(client, "waiting_sweeper") else None
        except Exception as error:  # noqa: BLE001 - unknown: dispatch as before, so a sweeper surely follows
            log(f"could not list waiting sweepers ({type(error).__name__}: {error}); dispatching one")
        try:
            if waiting:
                # A second dispatch would cancel it in the concurrency group before it ran.
                log(f"sweeper run {waiting} already waits to start; it runs main's new code, so none is dispatched")
            else:
                # It waits in the sweeper concurrency group (never cancel-in-progress) until this one exits.
                client.dispatch_sweeper()
        except Exception as error:  # noqa: BLE001 - the cron's next sweeper starts on the new code anyway
            log(f"could not start a sweeper ({type(error).__name__}: {error}); the cron's next one takes over")
    log("handing over: stopping watches; rescues under way finish")
    stopping.set()
    # One grace for all of them: a rescue started before the stop settles
    # within it (CANCEL_WAIT_SECONDS plus the re-run; rescue() checks `latest`).
    end = time.monotonic() + RESCUE_GRACE_SECONDS
    for thread in threads:
        thread.join(max(0.0, end - time.monotonic()))
    return outcomes

if __name__ == "__main__":
    raise SystemExit(main())
