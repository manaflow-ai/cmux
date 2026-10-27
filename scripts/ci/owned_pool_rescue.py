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

An owned runner can also refuse a job it was handed: glaeda's job-started
hook exits 1 when the host is busy (its lock is held), and the job fails
within seconds, before any step of the workflow succeeds. GitHub does not
retry it, so the pull request would stay red until someone re-ran it. A job
on the persistent pool that failed within REFUSAL_SECONDS of starting, with
its runner setup step failed or no workflow step succeeded, counts as refused
(compile admission's `always()` metrics steps still succeed after a refusal).
A failed job that ran no step at all counts too, whatever its length: GitHub
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
are re-run then. A failed job of such a run that is not a refusal keeps it
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
39329116254, 2026-10-19). Only a refusal is acted on. A nightly job with no
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

nightly-next's signing jobs, and the jobs that verify, recover or follow them
(NIGHTLY_SIGN_ALTERNATES), stay on Blacksmith macOS. One queued there with no
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
import owned_pool_sources  # noqa: E402
import pr_runner_pool  # noqa: E402
import simple_pool_picker  # noqa: E402
import ui_tests_dispatch  # noqa: E402

CI_WORKFLOW_PATH = ".github/workflows/ci.yml"
E2E_WORKFLOW_PATH = ".github/workflows/test-e2e.yml"
IOS_TEST_WORKFLOW_PATH = ".github/workflows/test-ios.yml"
IOS_SCREENSHOTS_WORKFLOW_PATH = ".github/workflows/ios-screenshots.yml"
IROH_RELEASE_GATE_WORKFLOW_PATH = ".github/workflows/iroh-release-gate.yml"
# The cmux NEXT DEV publisher's `runner` job offers its secret-free verify job
# to an owned Mac free now, like iroh-release-gate.yml's.
CMUX_NEXT_DEV_DAILY_WORKFLOW_PATH = ".github/workflows/cmux-next-dev-daily.yml"
# workflow_dispatch runs watched like an E2E run: each has a `runner` job that
# picks the pool and uploads the marker.
DISPATCH_WORKFLOW_PATHS = (E2E_WORKFLOW_PATH, IOS_TEST_WORKFLOW_PATH, IOS_SCREENSHOTS_WORKFLOW_PATH,
                           IROH_RELEASE_GATE_WORKFLOW_PATH, CMUX_NEXT_DEV_DAILY_WORKFLOW_PATH)
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
LANE_LABEL = re.compile(
    r"glaeda-(?:aws-)?(?:session-|fast-|dev-|nightly-)(?:xl|std|light)-xcode-[0-9]+(?:\.[0-9]+)*")
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
    ".github/workflows/cmux-tui-artifacts.yml",
    ".github/workflows/cmux-tui.yml",
    ".github/workflows/iroh-v2.yml",
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
    ".github/workflows/app-ffi-release.yml":
        "feat-cmux-next only; builds and publishes the FFI xcframework every app build links on the trusted "
        "promote mini: a release step, so a person re-runs it",
    ".github/workflows/cmux-tui-nightly.yml":
        "feat-cmux-next only; builds (on a side label it passes cmux-tui-build-package.yml) and publishes the "
        "cmux-tui nightly packages: a release step, so a person re-runs it",
    ".github/workflows/ios-internal-nightly.yml":
        "feat-cmux-next only; signs and uploads the internal iOS build: a release step, so a person re-runs it",
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
# covers that), so a refusal is the hook's other checks, which answer at once.
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


def owned_rerun(run: Mapping[str, Any]) -> bool:
    """A re-run of a CI run whose owned jobs go back to the minis, so it is watched like attempt 1: attempt 2,
    or a later one of a pull request someone other than the bot (CI_RESCUE_ACTOR; cmux-next: RESCUE_ACTORS) started."""
    attempt = int(run.get("run_attempt") or 0)
    if attempt <= 1:
        return False
    if run.get("path") == NIGHTLY_WORKFLOW_PATH:
        # nightly-next's picker places any attempt that runs it again (a person's full re-run) on an idle owned
        # Mac and marks it; a re-run of failed jobs keeps the earlier pick and takes Blacksmith, so its watch
        # ends at its first look. The sweeper adopts it only by that marker.
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


def job_pool(job: Mapping[str, Any]) -> str | None:
    """The owned pool a job asked for, if any: a pull request pool or the trusted one."""
    for label in job.get("labels") or []:
        if (persistent(str(label)) or TRUSTED_LABEL.fullmatch(str(label)) or LANE_LABEL.fullmatch(str(label))
                or nightly_dedicated(str(label))):
            return str(label)
    return None


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


# nightly-next's Blacksmith macOS jobs (nightly.yml on feat-cmux-next): the signing jobs, which hold the release
# keys, and the jobs that verify, recover or follow them. On 2026-10-27 build-sign-notarize-nightly and
# sign-nightly-identity-legacy sat 16 minutes (10:58 to 11:14Z) on a starved blacksmith-6vcpu-macos-26 in run
# 40489472569. From attempt 2 on, each job's runs-on reads `github.run_attempt > 1 && needs.<job>.outputs.<name>`:
# an alternate macOS 26 label nightly_sign_runner.py picked on attempt 1 (#26171), which a re-run of failed
# jobs keeps. Each job maps to its jobs-API name (a matrix leg adds ` (arm64)`) and that expression. The rescue
# acts on a job only when the run's own nightly.yml has the expression in the job's runs-on
# (sign_stall_gate()); without it a re-run would queue on the same stalled label, so the job is left alone.
_SIGN_ALTERNATE = "github.run_attempt > 1 && needs.pick-nightly-sign-runner.outputs.alternate"
_RECOVERY_ALTERNATE = "github.run_attempt > 1 && needs.find-nightly-next-recovery.outputs.sign_alternate"
_LEGACY_ALTERNATE = "github.run_attempt > 1 && needs.legacy-identity-target.outputs.sign_alternate"
NIGHTLY_SIGN_ALTERNATES: dict[str, tuple[str, str]] = {
    "build-sign-notarize-nightly": ("build-sign-notarize-nightly", _SIGN_ALTERNATE),
    "verify-signed-nightly": ("Verify signed nightly app", _SIGN_ALTERNATE),
    "verify-final-dmg-nightly": ("Verify final nightly DMG", _SIGN_ALTERNATE),
    "generate-nightly-deltas": ("generate-nightly-deltas", _SIGN_ALTERNATE),
    "recover-nightly-next-notarization": ("recover-nightly-next-notarization", _RECOVERY_ALTERNATE),
    "verify-recovered-nightly-next": ("verify-recovered-nightly-next", _RECOVERY_ALTERNATE),
    "sign-nightly-identity-legacy": ("sign-nightly-identity-legacy", _LEGACY_ALTERNATE),
    "verify-nightly-identity-legacy": ("verify-nightly-identity-legacy", _LEGACY_ALTERNATE),
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
    """The jobs among `keys` whose runs-on in `workflow_text` lacks their attempt-2 alternate label expression
    (NIGHTLY_SIGN_ALTERNATES). Fails closed: a missing or unreadable file, or a missing job, counts."""
    if not workflow_text:
        return sorted(keys)
    try:
        spec = owned_pool_sources._load(workflow_text).get("jobs") or {}
    except Exception:  # noqa: BLE001 - an unparseable file, or no PyYAML, takes no re-run
        return sorted(keys)
    missing = []
    for key in keys:
        runs_on = str((spec.get(key) or {}).get("runs-on") or "") if isinstance(spec.get(key), Mapping) else ""
        if NIGHTLY_SIGN_ALTERNATES[key][1] not in runs_on:
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
    started, completed = parse_time(job.get("started_at")), parse_time(job.get("completed_at"))
    if started is None or completed is None or (completed - started).total_seconds() > REFUSAL_SECONDS:
        return False
    # The hook runs inside the runner's own setup, so a failed setup step is a
    # refusal even when the job's `always()` steps still ran and succeeded.
    if any(step.get("name") in SETUP_STEPS and step.get("conclusion") == "failure" for step in steps):
        return True
    return not any(step.get("conclusion") == "success" and step.get("name") not in SETUP_STEPS
                   for step in steps)


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
                         r"(?=\s|$)( of every job)?")
# CANCEL_SENT's tail when the re-run to follow is of every job (rescue()'s failed_only off), not its failed ones.
EVERY_JOB = " of every job"
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
    to be re-run), "sent all" (every job) or "settled"."""
    found: dict[tuple[int, int], str] = {}
    for line in lines:
        if "owned-pool rescue: cancel" not in line:
            continue
        for mark in CANCEL_MARK.finditer(line):
            found[(int(mark.group(2)), int(mark.group(3)))] = (
                ("sent all" if mark.group(4) else "sent") if mark.group(1).startswith("cancel sent") else "settled")
    return found


def canceller(api: GitHub, jobs: Sequence[Mapping[str, Any]], sleep: Callable[[float], None],
              log: Callable[[str], None]) -> str | None:
    """Who cancelled the run, as GitHub's annotation on one of its cancelled jobs says ("" when none of them says;
    None when the annotations could not be read, or not all of them). Jobs no runner acquired first."""
    cancelled = sorted((job for job in jobs if job.get("conclusion") == "cancelled" and job.get("id")),
                       key=lambda job: not unacquired(job))
    for job in cancelled[:CANCELLED_BY_READS]:
        try:
            notes = read(lambda: api.annotations(int(job["id"])), sleep, log)
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
    """"failed" or "all" (the re-run it meant) when a rescue job that has ended logged CANCEL_SENT for this run's
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
    stuck = [job for job in waiting if queued_seconds(job, now, seen.get(job.get("id"))) >= budgets[id(job)]
             and not any(job is other for other in kept)]
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
        self.sleep: Callable[[float], None] = time.sleep
        # Each watch (the sweeper runs one per thread on this one client) has its own
        # RATE_LIMIT_WAIT_SECONDS, so one run's waits never spend another's.
        self._limits = threading.local()
        self._lock = threading.Lock()
        # GET answers by (token, path): (ETag, body, monotonic time read or confirmed).
        self._cache: dict[tuple[str, str], tuple[str, bytes, float]] = {}
        # Finished jobs' cancel marks by job id (job_marks()): a finished job's log no longer changes.
        self._logs: dict[int, dict[tuple[int, int], str] | None] = {}
        # This rescue job's own workflow run (GITHUB_RUN_ID), which rescue_jobs() never waits on.
        self.own_run = 0
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
            return max(interval, reset - time.time() + 5)
        return max(interval, IDLE_POLL_SECONDS)

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
        """Wait out a GITHUB_TOKEN request's rate-limit refusal; False when it is not one or the budget is spent."""
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
        """(run id, attempt) of unfinished nightly-next re-runs through SIGN_RESCUE_LAST_ATTEMPT. Only a re-run whose
        build picker chose an owned Mac leaves a marker, so a re-run on Blacksmith (a re-run of failed jobs, or a
        full one the picker placed there) is found here, for its signing jobs' stalls (signing_stall())."""
        name = NIGHTLY_WORKFLOW_PATH.rsplit("/", 1)[-1]
        found: list[tuple[int, int]] = []
        for status in ("queued", "in_progress"):
            data = self.request("GET", f"/actions/workflows/{name}/runs?status={status}&branch=nightly-next"
                                       f"&per_page={count}")
            found += [(int(run["id"]), int(run["run_attempt"])) for run in (data or {}).get("workflow_runs") or []
                      if isinstance(run, Mapping) and run.get("id") and run.get("head_branch") == "nightly-next"
                      and 1 < int(run.get("run_attempt") or 0) <= SIGN_RESCUE_LAST_ATTEMPT]
        return found

    def failed_runs(self, count: int, oldest: dt.datetime, since: dt.datetime | None = None,
                    pages: int = 1) -> list[tuple[int, int]]:
        """(run id, attempt) of the failed runs of SIDE_WORKFLOW_PATHS created since `oldest` and, when
        `since` is given, finished after it: newest first, `count` a page, at most `pages` pages.

        Those workflows upload no marker (sweep()), and a job the fleet refused fails its run, so a
        refusal shows here once the run ends, which is when its failed jobs can be re-run.
        """
        created = oldest.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
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
                        since is not None and finished is not None and finished < since):
                    found.append(entry)
            # A status-filtered page can come back short before the last one (queue_janitor.GitHub.
            # in_flight_runs()), so only an empty page ends the listing before `pages`.
            if not runs and status == "failure":
                listings = [listing for listing in listings if listing[0] != "failure"]
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
                jobs = self.request("GET", f"/actions/runs/{int(run['id'])}/attempts/{attempt}/jobs?per_page=20")
                found += [int(job["id"]) for job in (jobs or {}).get("jobs") or []
                          if isinstance(job, Mapping) and job.get("id") and job.get("status") == "completed"
                          and job.get("conclusion") != "skipped"]
        return found

    def job_marks(self, job_id: int) -> dict[tuple[int, int], str] | None:
        """cancel_marks() of a finished job's log, read as a stream (None past JOB_LOG_MAX_BYTES). GitHub answers
        with a redirect to the log's storage, fetched without our token."""
        if job_id in self._logs:
            return self._logs[job_id]

        class Stay(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args: Any, **kwargs: Any) -> None:
                return None
        request = urllib.request.Request(f"{API}/repos/{self.repo}/actions/jobs/{job_id}/logs",
                                         headers=dict(self.read_headers))
        def scan(response: Any) -> dict[tuple[int, int], str] | None:
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
            return cancel_marks(lines)
        try:
            with urllib.request.build_opener(Stay).open(request, timeout=20) as response:
                marks = scan(response)
        except urllib.error.HTTPError as error:
            location = error.headers.get("Location") if error.headers is not None else None
            if error.code not in (301, 302, 303, 307, 308) or not location:
                raise
            with urllib.request.urlopen(location, timeout=60) as response:
                marks = scan(response)
        if marks is not None:
            self._logs[job_id] = marks
        return marks

    def annotations(self, job_id: int) -> list[Mapping[str, Any]]:
        """The annotations of a job's check run (GitHub's "The run was canceled by @actor." among them)."""
        notes: list[Mapping[str, Any]] = []
        for page in range(1, ANNOTATION_PAGES + 1):
            data = self.request("GET", f"/check-runs/{job_id}/annotations?per_page=100&page={page}")
            batch = [note for note in data or [] if isinstance(note, Mapping)]
            notes += batch
            if len(batch) < 100:
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

    def pool_snapshot(self, now: dt.datetime) -> Mapping[str, Any] | None:
        """The queue janitor's newest trusted pool snapshot, or None when missing or stale (the pickers' read)."""
        snapshot = pr_runner_pool.GitHub(self._snapshot_token, self.repo).snapshot(now=now)
        if snapshot is None or pr_runner_pool.snapshot_problem(snapshot, now):
            return None
        return snapshot

    def code_shas(self, names: Sequence[str]) -> dict[str, str]:
        """The git blob shas of `names` in MAIN_BRANCH's scripts/ci (one request: the directory listing)."""
        listing = self.request("GET", f"/contents/{CODE_DIRECTORY}?ref={MAIN_BRANCH}")
        found = {str(item.get("name")): str(item.get("sha") or "") for item in listing or []
                 if isinstance(item, Mapping)}
        return {name: found.get(name, "") for name in names}

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

    @property
    def picker_job(self) -> str:
        return E2E_PICKER_JOB if self.e2e else PICKER_JOB

    @property
    def late_owned_jobs(self) -> bool:
        """nightly-next's nightly.yml puts prepare-nightly-variant on the side label after the app build."""
        return self.nightly and self.push_branch == "nightly-next"

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
    ios_pull = path == IOS_TEST_WORKFLOW_PATH and run.get("event") == "pull_request"
    expected = "workflow_dispatch" if e2e else "pull_request"
    # A side lane's trusted non-PR run (push, schedule, dispatch) is watched too.
    side_trusted = side and run.get("event") in TRUSTED_SIDE_EVENTS
    if run.get("event") != expected and not on_main and not ios_pull and not side_trusted:
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
                      path=str(path), attempt_started_at=attempt_started)
    if on_main:
        return Target(int(run["id"]), attempt, str(run.get("head_sha") or ""), 0, path=str(path), main=True,
                      attempt_started_at=attempt_started)
    if side_trusted:
        # No pull request: no head to re-check (pull_moved), like a dispatch.
        push_branch = str(run.get("head_branch") or "") if run.get("event") == "push" else ""
        return Target(int(run["id"]), attempt, str(run.get("head_sha") or ""), 0, side=True, path=str(path),
                      attempt_started_at=attempt_started, push_branch=push_branch)
    pulls = [pr for pr in run.get("pull_requests") or [] if isinstance(pr, Mapping) and pr.get("number")]
    if len(pulls) != 1:
        return "the run does not name exactly one pull request"
    return Target(int(run["id"]), attempt, str(run.get("head_sha") or ""), int(pulls[0]["number"]),
                  e2e=e2e, side=side, path=str(path), attempt_started_at=attempt_started)


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
                  side=True, nightly=True, push_branch=str(run["head_branch"]))


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
    while True:
        looks += 1
        jobs = read(lambda: api.jobs(target.run_id, target.attempt), sleep, log)
        if target.late_owned_jobs and target.attempt <= SIGN_RESCUE_LAST_ATTEMPT:
            # nightly-next's signing jobs on a stalled Blacksmith macOS label (signing_stall()).
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
            elif run_finished(jobs) and not (target.late_owned_jobs and read(
                    lambda: api.run(target.run_id), sleep, log).get("status") != "completed"):
                # nightly-next's signing jobs appear only once the jobs they need finish (signing_stall()), so
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
                        f"{'every job' if meant == 'all' else 'its failed jobs'} and stopped before the re-run")
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
    OWNED_WAIT_FLOOR_SECONDS. Re-picking another owned pool is no option here: a re-run never takes an
    owned label in the workflows this moves (cmux-next-dev-daily.yml's verify runs on its picker's label
    only on attempt 1), and a cancel would lose the job's place in the owned queue for a Blacksmith one.
    """
    held = ""
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
            # watch() reports a stuck job before its deadline check, so the hold ends here (after the
            # refusal look above, so a refusal on the last look still gets its re-run).
            return "stop", "watch limit reached", held
        verdict, label = move_verdict(client, target, now=now(), sleep=sleep, log=log)
        if verdict == "free" or verdict == "busy" and floor is not None and floor >= OWNED_WAIT_FLOOR_SECONDS:
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


def pull_moved(api: GitHub, target: Target, sleep: Callable[[float], None],
               log: Callable[[str], None]) -> str:
    """Why the pull request (or main) no longer wants this run, or "" when it still does."""
    if target.nightly and target.push_branch == "nightly-next":
        # Each nightly-next run builds and signs in groups of its own (nightly.yml
        # scopes them to github.run_id), so a newer tip builds alongside this one
        # and never makes it moot: a newer tip is never a reason to cancel a
        # nightly (Nightly freshness). publish-nightly's order check refuses a
        # build no newer than the feed, so re-running an older one never downgrades.
        return ""
    if target.nightly:
        # nightly.yml's concurrency group never cancels in progress: a newer
        # run waits behind this one, and a re-run of this one would join the
        # group and cancel that pending run. Leave the revision to it.
        branch = target.push_branch or MAIN_BRANCH
        newer = read(lambda: api.newer_unfinished_runs(target.path, target.run_id, branch), sleep, log)
        if newer:
            return f"a newer nightly run on {branch} ({newer[0]}) has not finished and builds instead"
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


def rerun_failed_or_repick(api: GitHub, target: Target, sleep: Callable[[float], None],
                           log: Callable[[str], None]) -> str:
    """Re-run a finished attempt's failed jobs; for attempt 1 of a nightly-next run, re-run its build picker
    and the jobs that need it instead when repick_job() allows (once: attempt 2's re-run keeps attempt 2's
    fresh pick, whose Blacksmith label it then takes)."""
    if target.nightly and target.push_branch == "nightly-next" and target.attempt == 1:
        try:
            jobs = read(lambda: api.jobs(target.run_id, target.attempt), sleep, log)
            text = read(lambda: api.workflow_file(NIGHTLY_WORKFLOW_PATH, target.head_sha), sleep, log)
        except READ_ERRORS as error:
            jobs, text = [], None
            log(f"could not read the run for a fresh runner pick ({error}); re-running its failed jobs")
        if text:
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
        if not target.nightly:
            return
        for _ in range(NIGHTLY_GUARD_TRIES):
            # The jobs first, then the run: a jobs read that waited (a rate limit, a retried error) may return
            # the old attempt's jobs after someone re-ran the run, and the run read after it shows that attempt.
            busy = started_nightly_work(api, target, sleep, log)
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
    if before_cancel is None and not target.nightly:
        api.cancel(target.run_id)
        return
    api.cancel(target.run_id, before_send=check)


def started_nightly_work(api: GitHub, target: Target, sleep: Callable[[float], None],
                         log: Callable[[str], None]) -> str:
    """For a nightly, the jobs of it running right now (any pool: owned, Blacksmith, Linux), read just before a
    cancel: a started nightly is never cancelled for a slow runner or a newer tip. "" when none (or not a nightly).

    assess() checked the same on its look, but a sibling can start between that look and the cancel."""
    if not target.nightly:
        return ""
    jobs = read(lambda: api.jobs(target.run_id, target.attempt), sleep, log)
    running = sorted(str(job.get("name") or job.get("id")) for job in jobs if job.get("status") == "in_progress")
    return ", ".join(running)


def rescue(api: GitHub, target: Target, *, now: Callable[[], dt.datetime], sleep: Callable[[float], None],
           log: Callable[[str], None], failed_only: bool = False,
           deadline: dt.datetime | None = None, refused: bool | None = None, refusal: bool = False,
           before_cancel: Callable[[], None] | None = None) -> str:
    """Cancel and re-run, unless the pull request has moved on. Returns what happened.

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
        busy = started_nightly_work(api, target, sleep, log)
        if busy:
            return f"{NIGHTLY_BUSY} ({busy}); {moved}, but a started nightly is never cancelled"
        try:
            nightly_cancel(api, target, sleep, log)
        except NightlyBusy as busy_now:
            return f"{NIGHTLY_BUSY} ({busy_now}); {moved}, but a started nightly is never cancelled"
        return f"cancelled run {target.run_id}, not re-run: {moved}"
    if moved:
        return f"not rescued: {moved}"
    run = read(lambda: api.run(target.run_id), sleep, log)
    if int(run.get("run_attempt") or 0) != target.attempt:
        return "not rescued: someone else already re-ran the run"
    if run.get("status") != "completed" and target.pr_number:
        # pull_moved() just read the pull request open at this head. Run 40398277457 (PR #25446)
        # attempt 1 was cancelled here and re-run in-process; nothing automatic cancels such a run now.
        return f"not rescued: PR #{target.pr_number} is open at the run's head; {OPEN_HEAD_RULE}"
    if run.get("status") != "completed" and deadline is not None and \
            (deadline - now()).total_seconds() < CANCEL_WAIT_SECONDS + RERUN_MARGIN_SECONDS + max(
                0.0, RATE_LIMIT_WAIT_SECONDS - getattr(api, "rate_limit_waited", RATE_LIMIT_WAIT_SECONDS)):
        # (The rate-limit waits this watch may still make count too: they do not shorten the settle.)
        # A job killed between the cancel and the re-run would leave the
        # pull request's run cancelled for good; leave it as GitHub has it.
        return "not rescued: too little of the job left to cancel and re-run"
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
        return rerun_failed_or_repick(api, target, sleep, log)
    if target.path == CMUX_NEXT_WORKFLOW_PATH:
        # Only cmux-next.yml places jobs on the freshness slot (macos-placement's fresh_runner).
        jobs = read(lambda: api.jobs(target.run_id, target.attempt), sleep, log)
        slot = started_dev_compile(jobs)
        if slot:
            return f"not rescued: a DEV feed compile started on {slot}; a started dev build is never cancelled"
    busy = started_nightly_work(api, target, sleep, log)
    if busy:
        return f"{NIGHTLY_BUSY} ({busy}); a started nightly is never cancelled"
    try:
        nightly_cancel(api, target, sleep, log, before_cancel)
    except NightlyBusy as busy_now:
        return f"{NIGHTLY_BUSY} ({busy_now}); it started just before the cancel, and a started nightly is never cancelled"
    log(f"{CANCEL_SENT} run {target.run_id} attempt {target.attempt}{'' if failed_only else EVERY_JOB}")
    try:
        result = settle_and_rerun(api, target, now=now, sleep=sleep, log=log, failed_only=failed_only,
                                  keep_main=keep_main)
    except Exception:
        # An error ends this rescue for good (gave_up()); the run's attempt is as GitHub has it, not a stopped job's.
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
                 log: Callable[[str], None], every_job: bool) -> str:
    """The re-run a stopped rescue meant after its cancel (rerun_intended()), with its own CANCEL_SETTLED mark."""
    try:
        result = settle_and_rerun(api, target, now=now, sleep=sleep, log=log, failed_only=not every_job,
                                  keep_main=False)
    except Exception:
        settled_here(api, target, log)
        raise
    settled_here(api, target, log)
    return result


def settle_and_rerun(api: GitHub, target: Target, *, now: Callable[[], dt.datetime], sleep: Callable[[float], None],
                     log: Callable[[str], None], failed_only: bool, keep_main: bool) -> str:
    """rescue() after its cancel went out: wait for the run to settle, then re-run it unless its head moved."""
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
    if failed_only:
        if e2e_build_unfinished(api, target, sleep, log):
            api.rerun(target.run_id, target.attempt + 1)
            return f"re-ran every job of run {target.run_id}, so its sibling wait runs again; {next_attempt(target)}"
        return rerun_failed_or_repick(api, target, sleep, log)
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
    try:
        return finish(follow(client, target, seconds=seconds, queue_rounds=env.get("QUEUE_ROUNDS"),
                             now=clock, sleep=sleep, log=log, side_seconds=side_seconds))
    except (*READ_ERRORS, Aborted) as error:
        # A failed watch leaves the run exactly as GitHub scheduled it.
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
                result = resume_rerun(client, target, now=clock, sleep=rescue_sleep, log=log, every_job=reason == "all")
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
    if outcome not in ("rescue", "refused"):
        return f"stopped: {reason}" + (f"; kept on the owned pool: {held}" if held else "")
    if target.refusals_only and outcome == "rescue":
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
    if target.refusals_only and outcome != "refused":
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
                        refusal=outcome == "refused")
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
        outcome, reason, held = hold_for_destination(
            client, target, outcome, reason, budget_seconds=effective_seconds, floor_seconds=None,
            deadline=deadline, now=clock, sleep=sleep, log=log, seen=seen)
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
# (GitHub.failed_runs()).
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
        try:
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
