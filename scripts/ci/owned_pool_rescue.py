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
re-runs it. The re-run is attempt 2, and pr_runner_pool.py never gives a
retry attempt the std pool, so every macOS job of the re-run lands on
Blacksmith together, unless CI_OWNED_LIGHT_RETRY is 1 (passed here as
OWNED_LIGHT_RETRY). Then that full re-run runs `changes` again and may take
the `light` owned pool, so the watch follows attempt 2 the way it follows
attempt 1: it waits for `changes` and looks for attempt 2's own marker (the
marker name carries the attempt), because a macOS job gets its label only
after the picker has chosen. A job stuck or refused on light has its failed
and cancelled jobs re-run on attempt 3, which always takes Blacksmith. With
the variable off, the full re-run is not watched.

An owned runner can also refuse a job it was handed: glaeda's job-started
hook exits 1 when the host is busy (its lock is held), and the job fails
within seconds, before any step of the workflow succeeds. GitHub does not
retry it, so the pull request would stay red until someone re-ran it. A job
on the persistent pool that failed within REFUSAL_SECONDS of starting, with
its runner setup step failed or no workflow step succeeded, counts as refused
(compile admission's `always()` metrics steps still succeed after a refusal).
A failed job that ran no step at all counts too, whatever its length: GitHub
fails a job whose runner went away only after 10 minutes ("The self-hosted
runner lost communication with the server"). The watcher lets the rest of the
run finish, since GitHub re-runs no job of a run in progress and cancelling
it would kill every healthy sibling, then confirms the head has not moved and
re-runs its failed jobs. Only a run still going at the watch's end, or main's
full-suite run (whose failure would open main's red-CI issue), is cancelled
first.
That attempt 2 reuses attempt 1's outputs, so every macOS job in it takes
retry_runner, the Blacksmith pool the picker named, and what already passed
(compile admission, say) is kept. A run on an owned pool is split across pools
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

A refused job never goes back to the fleet: this rescue re-runs as
github-actions[bot], and every runs-on sends the bot's re-run to retry_runner
(Blacksmith), so it cannot land on the mini that refused it, and one re-run
is all a refusal costs. So the watch ends with that re-run. A person's re-run
of a pull request (a code failure) goes back to the minis on any attempt with
no marker of its own; the sweeper finds it among the in-progress CI runs
(person_reruns()) and watches it like attempt 1, and a job stuck or refused
there gets the bot's re-run onto Blacksmith.

E2E runs (test-e2e.yml) are watched the same way. Its `runner` job runs
e2e_runner_pool.py, which may pick an owned pool, and uploads the same marker
(with 1 job). An E2E run is a workflow_dispatch, not a pull request, so there
is no head to re-check, and its build and test jobs are not a split that can
break: from attempt 2 on both take the runner job's retry_label, a macOS 26
Blacksmith pool on the same Xcode build. So a stuck or refused E2E job gets
its failed and cancelled jobs re-run, keeping a build that passed, and the
follow-on watch of attempt 2 finds no owned job and stops. A UI run's
retry_label stays on its owned pool, since Blacksmith cannot run UI tests
(e2e_runner_pool.py), so the watch of attempt 2 may re-run it once more;
no attempt past 2 is watched, so it still never loops. A queued UI run
moved that way only rejoins the same owned queue, costing its place in it;
the watch stays for the refusals, which a re-run does clear. When the build
itself did not succeed, every job is re-run instead, so the `sibling` job
looks again for another run compiling the same revision
(e2e_build_unfinished). A stuck E2E run
that finished some other way (a newer dispatch in its concurrency group
cancelled it) is not re-run, since that would cancel the newer one. Its
watch lasts E2E_WATCH_LIMIT_SECONDS, since its test job queues only after a
sibling wait and a build.

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

Dispatches of iroh-release-gate.yml are watched the same way. Its `runner`
job runs e2e_runner_pool.py for the Tailscale version-skew job alone, and
only takes an owned pool with a machine free now (no queue rounds), so that
job rarely waits. Its simulator-e2e jobs stay on Blacksmith, but they run in
the same run: a stuck owned job's rescue cancels them with it, and a refused
one's waits for them until the watch ends. The re-run of failed and
cancelled jobs keeps the modes that passed and puts everything on Blacksmith.

Side-lane workflows (SIDE_WORKFLOW_PATHS) have no picker. On attempt 1 of a
trusted run (a same-repository pull request, or a push, schedule or
workflow_dispatch, whose code is this repository's own branch; see
TRUSTED_SIDE_EVENTS), their small macOS jobs take vars.CI_LIGHT_LANE_RUNNER
(the light minis' side label) or vars.CI_SIDE_LANE_RUNNER (the std minis'),
both glaeda-side-* labels that only the minis' non-root runners carry. Attempt
2 and later take the job's Blacksmith default. So the first job on an owned label marks the run as on a persistent
pool (a job behind a Linux gate appears once the gate ends), and the watch
stops once every owned job has been accepted, which a side lane's few short
jobs reach in minutes. A refused side-lane job gets the run's failed jobs
re-run; a stuck one gets the run cancelled and its failed and cancelled jobs
re-run, keeping the jobs that had already finished. That re-run (attempt 2)
takes the lane's Blacksmith default, so the watch ends there. A
stuck run that finished some other way (a newer push cancelled it) is not
re-run. Its watch lasts SIDE_WATCH_LIMIT_SECONDS. A side-lane run that is not
a pull request has no head to move, like a dispatch.

Nightly builds (NIGHTLY_WORKFLOW_PATH) are watched like a side lane: there is
no picker, and attempt 1 of a push or schedule run on main puts
build-nightly-app on vars.CI_SEED_TRUSTED_POOL, the trusted owned pool
(glaeda-trusted-<class>-xcode-<version>, TRUSTED_LABEL), while every later
attempt takes Blacksmith. The trusted minis also seed DerivedData on every
push, so the job may wait behind a seed: its budget adds one QUEUE_ROUND_SECONDS
round. A stuck job gets the run cancelled and its failed and cancelled jobs
re-run; a refused one waits for the run to finish (the signing job is skipped
behind it) and then gets its failed jobs re-run. The run is not a pull request,
so in place of a head it checks for a newer nightly run on main that has not
finished: nightly.yml's concurrency group holds that run pending behind this
one, and a re-run would join the group and cancel it. With one, a stuck run is
cancelled and not re-run (so the newer run starts), and a refused one is left
as it is; the newer run builds main's newer HEAD.

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
- on the attempt 2 it re-ran from failed jobs, no job runs on an owned label;
- on the attempt 2 it re-ran in full, `changes` finished without that
  attempt's marker, or CI_OWNED_LIGHT_RETRY is off (not watched at all);
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
gets the same allowance. The configured budget alone is an iOS screenshots
or side-lane run's (#14391: no picker; the side lanes share the
runners PR runs queue on, so they are moved to Blacksmith more often), and a
re-run of failed jobs'.
"""
from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import http.client
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pr_runner_pool import MAX_QUEUE_ROUNDS, QUEUE_ROUND_MINUTES, parse_queue_rounds, persistent  # noqa: E402
import ui_tests_dispatch  # noqa: E402

CI_WORKFLOW_PATH = ".github/workflows/ci.yml"
E2E_WORKFLOW_PATH = ".github/workflows/test-e2e.yml"
IOS_TEST_WORKFLOW_PATH = ".github/workflows/test-ios.yml"
IOS_SCREENSHOTS_WORKFLOW_PATH = ".github/workflows/ios-screenshots.yml"
IROH_RELEASE_GATE_WORKFLOW_PATH = ".github/workflows/iroh-release-gate.yml"
# workflow_dispatch runs watched like an E2E run: each has a `runner` job that
# picks the pool and uploads the marker.
DISPATCH_WORKFLOW_PATHS = (E2E_WORKFLOW_PATH, IOS_TEST_WORKFLOW_PATH, IOS_SCREENSHOTS_WORKFLOW_PATH,
                           IROH_RELEASE_GATE_WORKFLOW_PATH)
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
# The trusted owned pool's labels: minis with no pull request runners, whose
# job-started hook admits only main's push and schedule jobs. Only nightly.yml's
# app build asks for one through this watch.
TRUSTED_LABEL = re.compile(r"glaeda-(?:root-)?trusted-(?:xl|std|light)-xcode-[0-9]+(?:\.[0-9]+)*")
SIDE_WORKFLOW_PATHS = frozenset({
    ".github/workflows/app-host-test-rerun.yml",
    ".github/workflows/auth-refresh-tests.yml",
    ".github/workflows/cloud-command-deadlines.yml",
    ".github/workflows/cloud-machine-tests.yml",
    ".github/workflows/cloud-task-local-tests.yml",
    ".github/workflows/cmux-tui.yml",
    ".github/workflows/iroh-v2.yml",
    ".github/workflows/relay-tls.yml",
    ".github/workflows/reload-build.yml",
    ".github/workflows/remote-daemon.yml",
    ".github/workflows/terminal-hang-diagnostics.yml",
})
# Events whose code is this repository's own: a push or schedule runs a branch
# of it, and a workflow_dispatch needs write access. A side-lane run of one of
# these is owned-eligible like a same-repository pull request. merge_group,
# workflow_run and pull_request_target are not: they can carry fork code.
TRUSTED_SIDE_EVENTS = frozenset({"push", "schedule", "workflow_dispatch"})
# test-e2e.yml's job that runs e2e_runner_pool.py (and the iOS workflows' job
# that runs ios_runner_pool.py).
E2E_PICKER_JOB = "runner"
# ci.yml's job that runs the pool picker; its jobs-API name (no `name:` override).
PICKER_JOB = "changes"
DEFAULT_BUDGET_SECONDS = 90
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
READ_ATTEMPTS = 3
READ_RETRY_SECONDS = 10
MARKER_PREFIX = "macos-pool-persistent"
# ci-macos.yml's late-placement moved jobs after compile admission onto idle
# owned root runners (late_placement.py), and started this watch itself.
LATE_MARKER_PREFIX = "macos-pool-late"
LATE_JOB = "macos / late-placement"
# A cancelled run is only useful re-run: giving up leaves the pull request's
# run cancelled for good. A Mac job mid-compile has taken over 5 minutes to
# settle after a force-cancel (run 36074561333, 2026-09-24), so wait long, and
# force-cancel again while waiting.
CANCEL_WAIT_SECONDS = 20 * 60
FORCE_CANCEL_AFTER_SECONDS = 90
FORCE_CANCEL_AGAIN_SECONDS = 5 * 60
# A rescue may run this long past the watch's end, so a refusal found late
# in the watch still gets its cancel settled and its re-run.
RESCUE_GRACE_SECONDS = 25 * 60
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
# The last attempt of the bot's own re-runs that may run on an owned pool: a
# stuck run's full re-run on the light tier (CI_OWNED_LIGHT_RETRY). A person's
# re-run of a pull request (a code failure: pr_runner_pool.host_fault_retry())
# goes back to the minis on any attempt and is watched whatever its attempt
# (person_rerun()); the rescue's re-run of it is the bot's, on Blacksmith.
LAST_OWNED_ATTEMPT = 2
RESCUE_ACTOR = "github-actions[bot]"


def person_rerun(run: Mapping[str, Any]) -> bool:
    """A re-run of a pull request's CI run someone other than github-actions[bot] started: its owned jobs go
    back to the minis, so it is watched like attempt 1."""
    return (int(run.get("run_attempt") or 0) > 1 and run.get("path") == CI_WORKFLOW_PATH
            and run.get("event") == "pull_request"
            and str((run.get("triggering_actor") or {}).get("login") or "") != RESCUE_ACTOR)
# The runner's own steps, which run before glaeda's hook decides.
SETUP_STEPS = frozenset({"Set up job", "Set up runner"})
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
        if persistent(str(label)) or TRUSTED_LABEL.fullmatch(str(label)):
            return str(label)
    return None


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


def refused(job: Mapping[str, Any]) -> bool:
    """A job the owned runner refused at job start (see the module docstring), or whose runner was lost."""
    if not job_pool(job) or job.get("status") != "completed" or job.get("conclusion") != "failure":
        return False
    steps = [step for step in job.get("steps") or [] if isinstance(step, Mapping)]
    if not steps:
        # The runner ran nothing, not even "Set up job": GitHub failed a job whose
        # runner went away ("The self-hosted runner lost communication with the
        # server"), which it reports only after 10 minutes, so no length applies
        # (run 36420353579).
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


def accepted(job: Mapping[str, Any], now: dt.datetime) -> bool:
    """An owned job its runner took and has not refused: past its setup and started over REFUSAL_SECONDS ago,
    or done."""
    if job.get("status") == "completed":
        return not refused(job)
    started = parse_time(job.get("started_at"))
    return job.get("status") == "in_progress" and not in_setup(job) and started is not None and \
        (now - started).total_seconds() > REFUSAL_SECONDS


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
           floor_seconds: int | None = None) -> Look:
    """One look at the jobs of a run on a persistent pool (each job's budget: job_budget())."""
    seen = first_seen or {}
    waiting = [job for job in jobs if job_pool(job) and waiting_for_runner(job)]
    budgets = {id(job): job_budget(job, budget_seconds, deadline=deadline, floor_seconds=floor_seconds,
                                   first_seen=seen.get(job.get("id"))) for job in waiting}
    stuck = [job for job in waiting if queued_seconds(job, now, seen.get(job.get("id"))) >= budgets[id(job)]]
    if stuck:
        names = ", ".join(sorted(str(job.get("name") or job.get("id")) for job in stuck))
        return Look("rescue", f"{names} queued on {job_pool(stuck[0])} for at least "
                              f"{min(budgets[id(job)] for job in stuck)}s with no runner")
    settling = [job for job in jobs if job_pool(job) and in_setup(job)]
    held = [job for job in settling if setup_seconds(job, now) >= setup_budget(job, now, budget_seconds, deadline)]
    # Cancelling the run would kill siblings still running (run 36198335113 lost five
    # shards that way to a refusal), so a job held in setup waits for them, as a
    # refusal does, until the watch is about to end.
    running = [job for job in jobs if job.get("status") == "in_progress" and not in_setup(job)]
    closing = deadline is not None and now >= deadline - dt.timedelta(seconds=END_MARGIN_SECONDS)
    if held and (not running or closing):
        names = ", ".join(sorted(str(job.get("name") or job.get("id")) for job in held))
        return Look("rescue", f"{names} waited in {job_pool(held[0])}'s runner setup for capacity for at least "
                              f"{SETUP_WAIT_SECONDS}s")
    turned_away = [job for job in jobs if refused(job)]
    if turned_away:
        names = ", ".join(sorted(str(job.get("name") or job.get("id")) for job in turned_away))
        return Look("refused", f"{names} refused by {job_pool(turned_away[0])} at job start")
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

    def request(self, method: str, path: str, *, own_token: bool = False, body: Mapping | None = None) -> Any:
        headers = self.read_headers if method == "GET" and not own_token else self.headers
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(f"{API}/repos/{self.repo}{path}", method=method, headers=headers, data=data)
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                body = response.read()
                seen = getattr(response, "headers", None) or {}
                self.remaining = seen.get("X-RateLimit-Remaining") or self.remaining
                self.limit = seen.get("X-RateLimit-Limit") or self.limit
        except urllib.error.HTTPError as error:
            if error.code not in (401, 403) or headers is self.headers:
                raise
            if error.code == 403:
                # The installation lacks this read's permission: this one read goes on GITHUB_TOKEN.
                return self.request(method, path, own_token=True)
            self.read_headers = self.headers
            return self.request(method, path)
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

    def person_reruns(self, count: int) -> list[tuple[int, int]]:
        """(run id, attempt) of in-progress CI runs a person re-ran (person_rerun()): a re-run of failed jobs
        uploads no marker."""
        data = self.request("GET", f"/actions/workflows/ci.yml/runs?status=in_progress&per_page={count}")
        return [(int(run["id"]), int(run["run_attempt"])) for run in (data or {}).get("workflow_runs") or []
                if isinstance(run, Mapping) and run.get("id") and person_rerun(run)]

    def jobs(self, run_id: int, attempt: int) -> list[Mapping[str, Any]]:
        found: list[Mapping[str, Any]] = []
        for page in range(1, MAX_JOB_PAGES + 1):
            data = self.request("GET", f"/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100&page={page}")
            batch = [job for job in (data or {}).get("jobs") or [] if isinstance(job, Mapping)]
            found.extend(batch)
            if len(batch) < 100:
                break
        return found

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

    def branch_head(self, branch: str) -> str:
        return str(((self.request("GET", f"/branches/{branch}") or {}).get("commit") or {}).get("sha") or "")

    def cancel(self, run_id: int) -> None:
        self.request("POST", f"/actions/runs/{run_id}/cancel")

    def force_cancel(self, run_id: int) -> None:
        self.request("POST", f"/actions/runs/{run_id}/force-cancel")

    def rerun(self, run_id: int, next_attempt: int) -> None:
        self.request("POST", f"/actions/runs/{run_id}/rerun")
        self.request_ui_tests(run_id, next_attempt)

    def rerun_failed(self, run_id: int, next_attempt: int) -> None:
        self.request("POST", f"/actions/runs/{run_id}/rerun-failed-jobs")
        self.request_ui_tests(run_id, next_attempt)

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

    @property
    def picker_job(self) -> str:
        return E2E_PICKER_JOB if self.e2e else PICKER_JOB

    @property
    def watch_limit(self) -> int:
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
        return Target(int(run["id"]), attempt, str(run.get("head_sha") or ""), 0, e2e=True, path=str(path))
    if on_main:
        return Target(int(run["id"]), attempt, str(run.get("head_sha") or ""), 0, path=str(path), main=True)
    if side_trusted:
        # No pull request: no head to re-check (pull_moved), like a dispatch.
        return Target(int(run["id"]), attempt, str(run.get("head_sha") or ""), 0, side=True, path=str(path))
    pulls = [pr for pr in run.get("pull_requests") or [] if isinstance(pr, Mapping) and pr.get("number")]
    if len(pulls) != 1:
        return "the run does not name exactly one pull request"
    return Target(int(run["id"]), attempt, str(run.get("head_sha") or ""), int(pulls[0]["number"]),
                  e2e=e2e, side=side, path=str(path))


def nightly_target(run: Mapping[str, Any], repository: str) -> Target | str:
    """A nightly.yml run to watch, or why not: only attempt 1 of main's own push or schedule run."""
    if run.get("event") not in NIGHTLY_EVENTS:
        return f"a {run.get('event') or 'unknown'} run of {NIGHTLY_WORKFLOW_PATH}, not a push or schedule"
    if run.get("head_branch") != MAIN_BRANCH:
        return f"a run of {NIGHTLY_WORKFLOW_PATH} on {run.get('head_branch') or 'an unknown branch'}, not {MAIN_BRANCH}"
    head = (run.get("head_repository") or {}).get("full_name") or ""
    if head.casefold() != repository.casefold():
        return "a fork head; forks never take a persistent pool"
    attempt = int(run.get("run_attempt") or 0)
    if attempt != 1:
        return f"attempt {attempt}; its first attempt's watch follows it"
    return Target(int(run["id"]), attempt, str(run.get("head_sha") or ""), 0, path=NIGHTLY_WORKFLOW_PATH,
                  side=True, nightly=True)


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
          floor_seconds: int | None = None) -> tuple[str, str]:
    """Watch until a stop, a rescue or `deadline`. Returns (outcome, reason).

    A job's budget is cut to end before `deadline`, never below
    `floor_seconds` (job_budget()).

    One deadline covers every attempt a job watches (main()), so attempt 2
    cannot stretch the job past its timeout.
    """
    if deadline is None:
        deadline = now() + dt.timedelta(seconds=target.watch_limit)
    sleep(FIRST_LOOK_SECONDS)
    looks = 0
    on_persistent = False
    picker_marker: bool | None = None
    first_seen: dict[Any, dt.datetime] = {}
    while True:
        looks += 1
        jobs = read(lambda: api.jobs(target.run_id, target.attempt), sleep, log)
        if not on_persistent and target.side:
            # No picker: a job that asks for an owned label is the choice. A
            # gated job (cloud-machine-tests) appears once its Linux gate ends.
            if any(job_pool(job) for job in jobs):
                on_persistent = True
                log("a side-lane job asked for a persistent pool")
            elif run_finished(jobs):
                return "stop", "no job of the run asked for a persistent pool"
        elif not on_persistent and target.attempt > 1 and not target.full_rerun:
            # A re-run of failed jobs: no `changes` job, no marker, and every
            # job is created with the re-run. Follow it only if one asks for
            # an owned pool; the first look that lists jobs decides.
            if any(job_pool(job) for job in jobs):
                on_persistent = True
                log("a re-run job asked for a persistent pool")
            elif jobs:
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
            finished = run_finished(jobs) and \
                read(lambda: api.run(target.run_id), sleep, log).get("status") == "completed"
            if finished and not any(refused(job) for job in jobs):
                return "stop", "the run finished"
            seen_at = now()
            for job in jobs:
                if job_pool(job) and waiting_for_runner(job):
                    first_seen.setdefault(job.get("id"), seen_at)
            look = assess(jobs, now=seen_at, budget_seconds=budget_seconds, first_seen=first_seen,
                          deadline=deadline, floor_seconds=floor_seconds)
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
                sleep(IDLE_POLL_SECONDS)
                continue
            log(f"look {looks}: {look.reason}")
            if look.action in ("rescue", "refused"):
                return look.action, look.reason
            if not look.waiting:
                interval = IDLE_POLL_SECONDS
                owned = [job for job in jobs if job_pool(job)]
                # A full re-run's shards exist only after its admission, so
                # its watch goes on until the run finishes.
                if (target.attempt > 1 and not target.full_rerun and owned
                        and all(accepted(job, seen_at) for job in owned)):
                    # The fleet took the retry; later attempts never come back to it.
                    return "stop", "the fleet accepted the retry"
                if target.side and owned and all(accepted(job, seen_at) for job in owned):
                    # A side lane's jobs are all created by now, and none can be refused any more.
                    return "stop", "the fleet accepted the side-lane jobs"
        if now() >= deadline:
            return "stop", "watch limit reached"
        sleep(interval)


def next_attempt(target: Target) -> str:
    """Where a re-run of failed jobs goes next."""
    following = target.attempt + 1
    if target.side:
        return f"attempt {following} takes the side lane's Blacksmith default"
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
    if target.nightly:
        # nightly.yml's concurrency group never cancels in progress: a newer
        # run waits behind this one, and a re-run of this one would join the
        # group and cancel that pending run. Leave the revision to it.
        newer = read(lambda: api.newer_unfinished_runs(target.path, target.run_id, MAIN_BRANCH), sleep, log)
        if newer:
            return f"a newer nightly run on {MAIN_BRANCH} ({newer[0]}) has not finished and builds instead"
        return ""
    if (target.e2e or target.side) and not target.pr_number:
        return ""  # a dispatch, push or schedule has no head to move; a newer run cancels it by concurrency
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


def rescue(api: GitHub, target: Target, *, now: Callable[[], dt.datetime], sleep: Callable[[float], None],
           log: Callable[[str], None], failed_only: bool = False,
           deadline: dt.datetime | None = None, refused: bool | None = None, refusal: bool = False) -> str:
    """Cancel and re-run, unless the pull request has moved on. Returns what happened.

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
    if moved and (target.main or target.nightly):
        # Main's stuck run holds its concurrency group, so nothing newer can
        # start until it finishes: cancel it, and its completion dispatches
        # the new HEAD.
        run = read(lambda: api.run(target.run_id), sleep, log)
        if not run:
            return f"not rescued: the run could not be read ({moved})"
        if int(run.get("run_attempt") or 0) != target.attempt:
            return "not rescued: someone else already re-ran the run"
        if run.get("status") == "completed":
            return f"not rescued: {moved}"
        api.cancel(target.run_id)
        return f"cancelled run {target.run_id}, not re-run: {moved}"
    if moved:
        return f"not rescued: {moved}"
    run = read(lambda: api.run(target.run_id), sleep, log)
    if int(run.get("run_attempt") or 0) != target.attempt:
        return "not rescued: someone else already re-ran the run"
    if run.get("status") != "completed" and deadline is not None and \
            (deadline - now()).total_seconds() < CANCEL_WAIT_SECONDS + RERUN_MARGIN_SECONDS:
        # A job killed between the cancel and the re-run would leave the
        # pull request's run cancelled for good; leave it as GitHub has it.
        return "not rescued: too little of the job left to cancel and re-run"
    if run.get("status") == "completed":
        if not (failed_only if refused is None else refused):
            return "not rescued: the run already finished"
        if e2e_build_unfinished(api, target, sleep, log):
            api.rerun(target.run_id, target.attempt + 1)
            return f"re-ran every job of run {target.run_id}, so its sibling wait runs again; {next_attempt(target)}"
        api.rerun_failed(target.run_id, target.attempt + 1)
        return f"re-ran the failed jobs of run {target.run_id}; {next_attempt(target)}"
    api.cancel(target.run_id)
    log(f"cancelled run {target.run_id}")
    started = now()
    forced_at: float | None = None
    while True:
        sleep(10)
        run = read(lambda: api.run(target.run_id), sleep, log)
        if int(run.get("run_attempt") or 0) != target.attempt:
            return "not rescued: someone else already re-ran the run"
        if run.get("status") == "completed":
            break
        waited = (now() - started).total_seconds()
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
        api.rerun_failed(target.run_id, target.attempt + 1)
        return f"re-ran the failed jobs of run {target.run_id}; {next_attempt(target)}"
    api.rerun(target.run_id, target.attempt + 1)
    return (f"re-ran run {target.run_id}; attempt {target.attempt + 1} takes an ephemeral pool, "
            "or the light tier when CI_OWNED_LIGHT_RETRY is 1 and it is free")


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

    def finish(outcome: str) -> int:
        log(outcome)
        if env.get("GITHUB_STEP_SUMMARY"):
            with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
                handle.write("### Persistent-pool rescue\n\n" + "\n".join(f"- {line}" for line in lines) + "\n")
        return 0

    if (env.get("POOL_OWNED") or "").strip() != "1":
        return finish("owned pools are off (CI_PR_POOL_OWNED is not 1); nothing to watch")
    seconds = budget(env.get("RESCUE_SECONDS"))
    light_retry = (env.get("OWNED_LIGHT_RETRY") or "").strip() == "1"
    if seconds is None:
        return finish(f"CI_OWNED_POOL_RESCUE_SECONDS must be {MIN_BUDGET_SECONDS} to {MAX_BUDGET_SECONDS}; "
                      "nothing to watch")
    repository = env.get("GITHUB_REPOSITORY") or ""
    client = api or GitHub(env.get("GH_TOKEN") or env.get("GITHUB_TOKEN") or "", repository,
                           read_token=env.get("READ_TOKEN") or "")
    if (env.get("SWEEP") or "").strip() == "1":
        # One job for every marked run (sweep()); its per-run lines go to the log only.
        outcomes = sweep(client, repository, seconds=seconds, queue_rounds=env.get("QUEUE_ROUNDS"),
                         light_retry=light_retry, now=clock, log=lambda text: print(text, flush=True))
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
    target = target_from_event(event, repository)
    if isinstance(target, str):
        return finish(f"not watched: {target}")
    if ((env.get("LATE_PLACEMENT") or "").strip() == "1" and target.attempt == 1
            and not (target.e2e or target.main or target.side)):
        target = dataclasses.replace(target, late=True)
    try:
        return finish(follow(client, target, seconds=seconds, queue_rounds=env.get("QUEUE_ROUNDS"),
                             light_retry=light_retry, now=clock, sleep=sleep, log=log))
    except (*READ_ERRORS, Aborted) as error:
        # A failed watch leaves the run exactly as GitHub scheduled it.
        finish(f"gave up: {error}")
        return 1


def follow(client: GitHub, target: Target, *, seconds: int, queue_rounds: str | None, light_retry: bool,
           now: Callable[[], dt.datetime], sleep: Callable[[float], None], log: Callable[[str], None],
           rescue_sleep: Callable[[float], None] | None = None, latest: dt.datetime | None = None) -> str:
    """Watch one run and rescue it when it needs it. Returns the outcome; raises READ_ERRORS or Aborted.

    The sweeper stops a watch by making `sleep` raise; a rescue paces itself
    with `rescue_sleep` (default `sleep`) so a cancel it started is always
    followed by its re-run, and `latest` caps the rescue deadline at the
    sweeper's end plus its grace.
    """
    rescue_sleep = rescue_sleep or sleep
    clock = now

    def capped(deadline: dt.datetime) -> dt.datetime:
        return min(deadline, latest) if latest is not None else deadline

    subject = (f"pull request #{target.pr_number}'s {target.path}" if target.pr_number else
               "an E2E dispatch" if target.path == E2E_WORKFLOW_PATH else f"a dispatch of {target.path}") \
        if target.e2e else f"main's full-suite dispatch at {target.head_sha[:12]}" if target.main \
        else f"main's nightly build at {target.head_sha[:12]}" if target.nightly \
        else f"pull request #{target.pr_number}" if target.pr_number else f"a run of {target.path}"
    if target.side and not target.nightly:
        subject += " (side lane)"
    # ci.yml's, test-ios.yml's and test-e2e.yml's pickers queue on purpose, within the queue
    # rounds: their owned jobs may wait up to the pool's expected wait (see the docstring).
    queue_extra = queue_seconds(queue_rounds) if target.path in QUEUEING_WORKFLOW_PATHS else 0
    if target.nightly:
        # The trusted minis seed DerivedData on every push to main, as this run
        # starts: let the app build wait one round behind a seed.
        queue_extra = QUEUE_ROUND_SECONDS
    log(f"watching run {target.run_id} of {subject} (budget {seconds + queue_extra}s"
        + (f": {seconds}s past the {queue_extra}s an owned job may expect to wait)" if queue_extra else ")"))
    # A watch deadline for attempt 1, and a fresh one (capped by the job's
    # timeout) for an attempt it re-ran and follows. A rescue may run past it,
    # within the job's own timeout, so a cancel is never started without the
    # time to settle and re-run.
    started = clock()
    deadline = started + dt.timedelta(seconds=target.watch_limit)
    rescue_deadline = capped(deadline + dt.timedelta(seconds=RESCUE_GRACE_SECONDS))
    first_budget = seconds + queue_extra if target.attempt == 1 else seconds
    outcome, reason = watch(client, target, budget_seconds=first_budget, now=clock, sleep=sleep,
                            log=log, deadline=deadline, floor_seconds=seconds if target.attempt == 1 else None)
    if outcome not in ("rescue", "refused"):
        return f"stopped: {reason}"
    log(f"{'rescue' if outcome == 'rescue' else 'refused'}: {reason}")
    while True:
        # From attempt 2 on, keep what passed: only the owned jobs are moved.
        # An E2E run always keeps what passed (see the module docstring).
        # A side-lane run too: its other jobs are on Blacksmith already.
        failed_only = outcome == "refused" or target.attempt > 1 or target.e2e or target.side
        result = rescue(client, target, now=clock, sleep=rescue_sleep, log=log, failed_only=failed_only,
                        deadline=rescue_deadline,
                        refused=(outcome == "refused") if target.e2e or target.side else None,
                        refusal=outcome == "refused")
        log(result)
        # A re-run of failed jobs runs every job on Blacksmith (retry_runner, or
        # a side lane's default), so there is nothing to follow. Only a stuck
        # run's full re-run may take the light tier (CI_OWNED_LIGHT_RETRY),
        # and that one is watched here.
        if target.nightly or not (result.startswith("re-ran") and target.attempt + 1 <= LAST_OWNED_ATTEMPT):
            return "done"
        if failed_only or not light_retry:
            return "done"
        target = dataclasses.replace(target, attempt=target.attempt + 1, full_rerun=not failed_only, late=False)
        # The followed attempt gets its own watch: a late rescue of attempt 1
        # would otherwise leave it the tail of attempt 1's, ending before its
        # owned jobs even queue. The job's timeout still caps watch plus grace.
        deadline = min(clock() + dt.timedelta(seconds=target.watch_limit), started + dt.timedelta(
            seconds=JOB_TIMEOUT_SECONDS - RESCUE_GRACE_SECONDS - JOB_TIMEOUT_MARGIN_SECONDS))
        rescue_deadline = capped(deadline + dt.timedelta(seconds=RESCUE_GRACE_SECONDS))
        outcome, reason = watch(client, target, budget_seconds=seconds, now=clock, sleep=sleep, log=log,
                                deadline=deadline)
        if outcome not in ("rescue", "refused"):
            return f"stopped watching attempt {target.attempt}: {reason}"
        log(f"attempt {target.attempt}: {'rescue' if outcome == 'rescue' else 'refused'}: {reason}")


# The sweeper (SWEEP=1). The pickers of ci.yml, test-e2e.yml and test-ios.yml
# upload an artifact named WATCH_MARKER when they place attempt 1 on an owned
# pool, and ci-macos.yml's late-placement uploads LATE_WATCH_MARKER when it
# moves jobs onto one. Listing each name repository-wide is one request that
# names every such run, finished or not, so one job watches them all: each
# run gets a thread running follow(), the per-run watch.
WATCH_MARKER = "owned-pool-watch"
LATE_WATCH_MARKER = "owned-pool-watch-late"
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
MARKER_ORDER_SKEW = dt.timedelta(minutes=90)


class Stopping(Aborted):
    pass


# A run that finished this long before a sweeper started is left alone: the
# sweeper before it was running then and has already acted on it.
SWEEP_FINISHED_SECONDS = 30 * 60


def sweep_target(run: Mapping[str, Any], repository: str, *, late: bool, full_rerun: bool = False,
                 since: dt.datetime | None = None) -> Target | str:
    """The target for a marked run, resuming the attempt its rescue re-ran (LAST_OWNED_ATTEMPT at most).

    A finished run is only worth a look when it failed after `since`: a
    refusal nobody re-ran yet. `full_rerun` says attempt 2 re-ran the picker
    (a stuck run's re-run under CI_OWNED_LIGHT_RETRY).
    """
    attempt = int(run.get("run_attempt") or 0)
    if attempt < 1 or attempt > LAST_OWNED_ATTEMPT and not person_rerun(run):
        return f"attempt {attempt}"
    if run.get("status") == "completed":
        if run.get("conclusion") != "failure":
            return f"finished ({run.get('conclusion')})"
        finished = parse_time(run.get("updated_at"))
        if since is not None and finished is not None and finished < since:
            return "finished before this sweeper's predecessor stopped"
    target = target_from_event({"workflow_run": {**run, "run_attempt": 1}}, repository)
    if isinstance(target, str):
        return target
    if attempt > 1:
        # A re-run (a rescue, or a person): follow its owned jobs, if any.
        return dataclasses.replace(target, attempt=attempt, full_rerun=full_rerun)
    if late and not (target.e2e or target.main or target.side):
        return dataclasses.replace(target, late=True)
    return target


def sweep(client: GitHub, repository: str, *, seconds: int, queue_rounds: str | None, light_retry: bool,
          now: Callable[[], dt.datetime], log: Callable[[str], None],
          sweep_seconds: int = SWEEP_SECONDS, tick_seconds: float = SWEEP_TICK_SECONDS,
          wait: Callable[[float], None] = time.sleep) -> dict[str, int]:
    """Watch every marked run until `sweep_seconds` pass. Returns outcome counts."""
    stopping = threading.Event()
    lock = threading.Lock()
    outcomes: dict[str, int] = {}
    seen: set[int] = set()
    rerun_seen: set[tuple[int, int]] = set()  # person re-runs, once per attempt (person_reruns())
    threads: list[threading.Thread] = []
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
            outcome = follow(client, target, seconds=seconds, queue_rounds=queue_rounds, light_retry=light_retry,
                             now=now, sleep=watch_sleep, log=say, rescue_sleep=wait, latest=latest)
        except Stopping:
            outcome = "handed over"
        except (*READ_ERRORS, Aborted) as error:
            outcome = "gave up"
            say(f"gave up: {error}")
        except Exception as error:  # noqa: BLE001 - one run's bug must not end every other watch
            outcome = "error"
            say(f"error: {type(error).__name__}: {error}")
        else:
            say(outcome)
        with lock:
            key = outcome.split(":")[0]
            outcomes[key] = outcomes.get(key, 0) + 1

    def adopt(run_id: int, late: bool) -> None:
        seen.add(run_id)
        try:
            run = read(lambda: client.run(run_id), wait, log)
        except READ_ERRORS as error:
            seen.discard(run_id)  # the next tick tries again
            log(f"[run {run_id}] could not read the run ({error})")
            return
        rerun_seen.add((run_id, int(run.get("run_attempt") or 0)))
        full_rerun = False
        if light_retry and int(run.get("run_attempt") or 0) > 1:
            # A full re-run ran the picker again; a re-run of failed jobs kept attempt 1's.
            try:
                jobs = read(lambda: client.jobs(run_id, int(run["run_attempt"])), wait, log)
            except READ_ERRORS as error:
                seen.discard(run_id)
                log(f"[run {run_id}] could not read attempt {run['run_attempt']} ({error})")
                return
            picker = E2E_PICKER_JOB if run.get("path") in DISPATCH_WORKFLOW_PATHS else PICKER_JOB
            full_rerun = any(job.get("name") == picker and int(job.get("run_attempt") or 0) > 1 for job in jobs)
        target = sweep_target(run, repository, late=late, full_rerun=full_rerun, since=since)
        if isinstance(target, str):
            log(f"[run {run_id}] not watched: {target}")
            return
        thread = threading.Thread(target=one, args=(target,), name=f"run-{run_id}", daemon=True)
        thread.start()
        threads.append(thread)

    while (now() - started).total_seconds() < sweep_seconds:
        oldest = now() - dt.timedelta(seconds=SWEEP_MAX_AGE_SECONDS)
        # The picker's marker first: a run with both is watched the ordinary way.
        for name, late in ((WATCH_MARKER, False), (LATE_WATCH_MARKER, True)):
            try:
                marked = client.marked_runs(name, SWEEP_LISTING, oldest, SWEEP_LISTING_PAGES, log=log)
            except READ_ERRORS as error:
                log(f"could not list {name} markers ({error}); next tick")
                continue
            for run_id, created in marked:
                if run_id in seen or (created is not None and created < oldest):
                    continue
                adopt(run_id, late)
        # A person's re-run of failed jobs goes back to the minis with no marker of its own; one listing a tick.
        try:
            reruns = client.person_reruns(SWEEP_LISTING)
        except READ_ERRORS as error:
            log(f"could not list re-runs ({error}); next tick")
            reruns = []
        for run_id, attempt in reruns:
            if (run_id, attempt) not in rerun_seen:
                adopt(run_id, False)
        threads = [thread for thread in threads if thread.is_alive()]
        log(f"tick: {len(threads)} run(s) watched, {client.remaining or '?'} of "
            f"{client.limit or '?'} API requests left this hour")
        wait(tick_seconds)
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
