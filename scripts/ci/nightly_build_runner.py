#!/usr/bin/env python3
"""Pick the route for the nightly-next app build: an idle owned Mac, else a moving Blacksmith label.

build-nightly-app used to read
vars.CI_NIGHTLY_NEXT_BUILD_RUNNER alone on nightly-next, for every attempt: one
label and no fallback. Time spent waiting for a runner does not count toward
timeout-minutes, so a label that serves nothing stalls the run for up to 24 h,
and a re-run went back to the same label. On 2026-10-27 runs 40446901975 and
40448164753 died at "Set up runner" on glaeda-dev-std-xcode-26.6, and run
40453543604's attempt 2 was refused at "Set up runner" on the side label it had
just been moved off. The routing order is Linux, then owned Macs, then
Blacksmith macOS last (Leo, 2026-10-24), and no job waits on one reserved
machine.

A Linux job runs this right before the macOS job queues and prints its labels:

- `dedicated`: DEDICATED_LABEL (vars.CI_NIGHTLY_NEXT_DEDICATED_LABEL, the dedicated
  nightly-next builder, pr_runner_pool.NIGHTLY_DEDICATED_LABEL; unset switches it off) while
  its runner is online and idle. It keeps a warm checkout and DerivedData and builds each new
  tip incrementally (nightly_build_state.py), so it comes first. While it is busy (the build
  of the previous tip, or a verify) this waits up to DEDICATED_WAIT_SECONDS (1 min) for it,
  reading the runners every 30 s; offline, unread or still busy after that, it is skipped.
  Leo, 2026-10-27: "what if we just dedicatd one, only, always, and it just
  incrementally... did the thing?"
  A builder that refused its newest build-nightly-app job at "Set up runner" within
  REFUSAL_HOLD (30 min) is skipped too, however idle GitHub lists it: its admission hook
  (nightly_builder.py admit, glaeda's --min-free-gib) refuses below the disk floor, and GitHub
  only sees an idle runner. On 2026-10-27/28 cmux7 sat at 27 to 35 GiB free under a 40 GiB
  floor and refused every push's attempt 1 for hours (run 40614043040), each push losing an
  attempt and a rescue re-run before it reached another pool (#25708). After the hold one run
  probes it again, so a builder with its disk back is used again without anyone's say.
- `owned`: the first of OWNED_LABELS (vars.CI_NIGHTLY_NEXT_BUILD_RUNNER, then
  vars.CI_SIDE_LANE_RUNNER) that the rescue watches, or the same label on a wider class
  (side_lane_placement.compatible_labels()), while an online runner carrying it
  is idle now (pr_runner_pool.live_owned_free(), the rule side lanes are placed
  with). When the runners cannot be read (no routing token, or its API budget
  spent) and the caller sets UNREAD_OWNED_FALLBACK=1 (nightly.yml's build and verify picks,
  only while vars.CI_PR_POOL_OWNED is on and the rescue watches the build), it is
  the first watched label itself, so the build still queues on the owned pool
  before Blacksmith (unread_owned_route()). Empty when no label is one the
  rescue watches, or when unread without that opt-in. A busy fleet is waited on only while every
  Blacksmith macOS label is stalled (owned_queue_route()): then the first of those
  labels an online runner carries, else one any registered runner carries, since
  the rescue watches a job there and re-runs this picker once a label moves.
- `blacksmith`: the Blacksmith macOS 26 label whose queue moves
  (nightly_sign_runner.pick(): vars.MACOS_RUNNER_26, then 6 vCPU, then 12 vCPU,
  past any stalled one). Never empty. EXCLUDE (a label another leg already
  waits on) is skipped while another candidate moves.

- `helper`: the owned route for build-nightly-ghostty-cli-helper, which the dedicated
  builder never admits: `owned` when that is not the dedicated builder, else a fresh
  owned_route() read (an idle side or nightly-slot Mac), else empty. Until 2026-10-30 the
  helper took `blacksmith` whenever the app build took the dedicated builder, and run
  40990112293 (373ec0cfaa2f, the first green tip after a two-hour Release compile red) queued
  its helper on blacksmith-6vcpu-macos-26 for 39 minutes until the run was cancelled unpublished.
- `attempt`: GITHUB_RUN_ATTEMPT, the attempt this pick was made for.

`owned` is `dedicated` when that is set. The workflow takes `owned` only while
`attempt` is the run's own attempt, so a fresh pick, and `blacksmith` otherwise.
Every run that reaches this job picks the same way: a push, a workflow_dispatch,
and a re-run whose re-run includes this job (a full re-run, or a re-run of failed
jobs after this job itself failed or was cancelled). Until 2026-10-27 only attempt
1 of a push got the routing token, so a dispatched or re-run tip nightly could
never build on an owned Mac and queued on a stalled Blacksmith label instead.

A re-run of failed jobs that keeps this job keeps its outputs too, and their
`attempt` is the earlier one: that re-run reads `blacksmith`. That is how a job
an owned runner refused at "Set up runner", or one stuck on an owned label
after an idle runner was taken by another job, leaves the label: the rescue
(ci-owned-pool-rescue.yml; owned_pool_rescue.py watches nightly-next push and
dispatch runs, and adopts any attempt by this job's owned-pool-watch marker)
re-runs its failed jobs, and the next pool takes it instead of the same label.

It never fails the job and never prints an empty `blacksmith`:

    ROUTE_TOKEN=<org runners: read> SNAPSHOT_TOKEN=<actions: read> OWNED_LABELS='<a> <b>' CANDIDATE=<vars.MACOS_RUNNER_26> \\
        DEDICATED_LABEL=<vars.CI_NIGHTLY_NEXT_DEDICATED_LABEL> \\
        nightly_build_runner.py   -> dedicated=..., owned=..., blacksmith=..., runner=..., attempt=... in $GITHUB_OUTPUT

`nightly_build_runner.py dedicated` prints only `dedicated`, with no wait.

`nightly_build_runner.py verify` prints only `owned`, never the dedicated builder (it keeps
that Mac for the next tip's build): pick-nightly-sign-runner's route for the secret-free
verify jobs (verify-signed-nightly, verify-final-dmg-nightly, signer-dmg-image),
by the same owned rule as the build. Until 2026-10-27 that step ran the pull request pool picker
(e2e_runner_pool.py), which named a Blacksmith macOS 15 label in run 40515681971 while owned
side runners were idle, so verify queued about 1.5 h on Blacksmith.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nightly_sign_runner as blacksmith_picker  # noqa: E402
import side_lane_placement as placement  # noqa: E402

pool = placement.pool
# Only labels ci-owned-pool-rescue.yml watches (pr_runner_pool.persistent, the rescue's job_pool()):
# a refusal or a stuck queue there is re-run as attempt 2, which takes Blacksmith. The DEV compile
# slot (glaeda-dev-*) is not one, so it is never offered: runs 40446901975 and 40448164753 died at
# "Set up runner" on glaeda-dev-std-xcode-26.6 and nothing re-ran them.
# glaeda's nightly slot (glaeda#1684, runner.nightlySlot): one runner per mini whose label no PR job asks for and
# whose hook takes only nightly jobs, ahead of every job waiting on that mini. A build queued on the shared side label
# waited behind every PR job queued there first (2026-10-27 14:08Z: run 40518198747 was never acquired on the light
# side label). main's rescue watches it (owned_pool_rescue.LANE_LABEL), so vars.CI_NIGHTLY_NEXT_BUILD_RUNNER may name it.
NIGHTLY_SLOT_LABEL = re.compile(r"glaeda-nightly-(?:xl|std|light)-xcode-[0-9]+(?:\.[0-9]+)*")


def owned_label(label: str) -> bool:
    return pool.persistent(label) or bool(NIGHTLY_SLOT_LABEL.fullmatch(label or ""))


# How long a run waits for the dedicated builder while it is busy, and how often it looks. With
# builds side by side (the 5-minute rolling window) the builder is usually busy with a whole
# 10-minute build, not a short tail: on 10-29 four picks waited the full 5 minutes and then built
# cold elsewhere anyway (runs 40924321847, 40930394811, 40935345693, 40936301031: 15.1-19.8 min
# builds after a 4.9-minute pick). One look a minute later, then an idle owned Mac.
DEDICATED_WAIT_SECONDS = 60
DEDICATED_LOOK_SECONDS = 30


# The builder admits only a push to nightly-next (nightly_builder.py admit). A dispatched run sent
# there is refused at "Set up runner" (run 40594111618, 2026-10-27: "event workflow_dispatch is not push").
DEDICATED_EVENTS = frozenset({"push"})

# A refusal at "Set up runner" holds the builder off this long; the next run after it probes it again.
# Inspect the newest RECENT_RUNS nightly-next runs together: an older-created run can execute later
# through a full rerun or delayed dependencies, so run creation order is not admission order.
BUILD_JOB = "build-nightly-app"
SETUP_STEP = "Set up runner"
REFUSAL_HOLD = dt.timedelta(minutes=30)
RECENT_RUNS = 6
JOB_PAGES = 4


def _stamp(value: Any) -> dt.datetime | None:
    try:
        return dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None


def _setup(job: Mapping[str, Any]) -> str:
    """The conclusion of the job's "Set up runner" step: 'success', 'failure', or '' while undecided."""
    for step in job.get("steps") or []:
        if isinstance(step, Mapping) and step.get("name") == SETUP_STEP:
            return str(step.get("conclusion") or "")
    return ""


def latest_admission(labels: str | Sequence[str], jobs: Sequence[Mapping[str, Any]]) -> Mapping[str, Any] | None:
    """The newest build-nightly-app job on any of `labels` whose "Set up runner" was decided (admitted or
    refused). The builder takes jobs by its dedicated label and, routed by the trusted pair, by its runner label."""
    wanted = {labels} if isinstance(labels, str) else set(labels)
    decided = [job for job in jobs if isinstance(job, Mapping) and job.get("name") == BUILD_JOB
               and wanted.intersection(job.get("labels") or []) and _setup(job) in ("success", "failure")
               and _stamp(job.get("started_at"))]
    return max(decided, key=lambda job: _stamp(job["started_at"]), default=None)


def refusal(label: str, job: Mapping[str, Any] | None, now: dt.datetime,
            hold: dt.timedelta = REFUSAL_HOLD) -> str:
    """Why the builder is held off: `job` (latest_admission()) was refused within `hold`; else ''."""
    if not job or _setup(job) != "failure":
        return ""
    at = _stamp(job.get("completed_at")) or _stamp(job.get("started_at"))
    if at is None or now - at > hold:
        return ""
    where = f" on {job['runner_name']}" if job.get("runner_name") else ""
    return (f"`{label}` refused run {job.get('run_id') or '?'}'s {BUILD_JOB} at \"{SETUP_STEP}\"{where} "
            f"{max(0, round((now - at).total_seconds() / 60))} min ago (its admission: disk floor or job shape); "
            f"held off for {round(hold.total_seconds() / 60)} min")


def read_admission(github: Any, label: str | Sequence[str], runs: int = RECENT_RUNS) -> Mapping[str, Any] | None:
    """latest_admission() across the newest `runs` nightly-next runs of nightly.yml."""
    listed = github.get(f"/actions/workflows/nightly.yml/runs?branch=nightly-next&per_page={runs}")
    admissions: list[Mapping[str, Any]] = []
    for run in (listed or {}).get("workflow_runs") or []:
        if not isinstance(run, Mapping) or not run.get("id"):
            continue
        # Every attempt's jobs (filter=all): a run on attempt 3 has more than one page of them.
        jobs: list[Mapping[str, Any]] = []
        for page in range(1, JOB_PAGES + 1):
            batch = (github.get(f"/actions/runs/{run['id']}/jobs?filter=all&per_page=100&page={page}")
                     or {}).get("jobs") or []
            jobs.extend(batch)
            if len(batch) < 100:
                break
        found = latest_admission(label, jobs)
        if found is not None:
            admissions.append(found)
    return latest_admission(label, admissions)


def dedicated_builder(runner: Mapping[str, Any]) -> bool:
    """A glaeda runner.dedicated runner: it registers with exactly its declared labels, so no `self-hosted`.

    A pool runner that also carries the dedicated label (cmux15's trusted runners did until
    2026-10-27, from runner.trustedNextNightly) applies the pool's capacity units and attempt-1
    rule, so an idle one is not the builder: run 40593692340 was refused there at "Set up runner"
    on attempts 1 and 2."""
    return "self-hosted" not in pool.runner_labels(runner)


def dedicated_state(label: str, runners: Sequence[Mapping[str, Any]] | None) -> str:
    """'idle', 'busy', 'offline', 'unread' or 'off' for the dedicated builder's label."""
    if not pool.nightly_dedicated(label):
        return "off"
    if runners is None:
        return "unread"
    online = [runner for runner in runners
              if runner.get("status") == "online" and label in pool.runner_labels(runner)
              and dedicated_builder(runner)]
    if not online:
        return "offline"
    return "idle" if any(not runner.get("busy") for runner in online) else "busy"


def dedicated_route(label: str, read: Callable[[], Sequence[Mapping[str, Any]] | None], *,
                    wait_seconds: float = DEDICATED_WAIT_SECONDS, look_seconds: float = DEDICATED_LOOK_SECONDS,
                    sleep: Callable[[float], None] = time.sleep,
                    clock: Callable[[], float] = time.monotonic) -> tuple[str, str]:
    """(the dedicated label while its runner is idle, waiting up to `wait_seconds` while it is busy, or "", why).

    Any attempt: the workflow reads the pick only when it was made for the run's own attempt."""
    if not pool.nightly_dedicated(label):
        return "", "no dedicated builder label" if not label else f"`{label}` is not the dedicated builder's label"
    deadline = clock() + wait_seconds
    while True:
        state = dedicated_state(label, read())
        if state == "idle":
            return label, f"`{label}` is online and idle"
        if state != "busy":
            return "", f"`{label}` is {state}"
        if clock() + look_seconds > deadline:
            return "", f"`{label}` stayed busy for {round(wait_seconds / 60)} min" if wait_seconds else f"`{label}` is busy now"
        sleep(look_seconds)


def owned_route(labels: str | Sequence[str], runners: Sequence[Mapping[str, Any]] | None) -> tuple[str, str]:
    """(the first watched owned label, or a wider class of it, with an idle runner now, or "", why).

    Any attempt: the workflow reads `owned` only when this pick was made for the run's own attempt."""
    wanted = [label for label in (labels.split() if isinstance(labels, str) else labels) if label]
    watched = [label for label in wanted if owned_label(label)]
    if not watched:
        return "", f"no owned label the rescue watches among {wanted or 'none'}"
    if runners is None:
        return "", "owned runners could not be read live, so no owned label is waited on"
    candidates = list(dict.fromkeys(c for label in watched for c in placement.compatible_labels(label)))
    free = pool.live_owned_free(runners, candidates)
    for candidate in candidates:
        if free[candidate] > 0:
            return candidate, f"`{candidate}` has {free[candidate]} idle runner(s) now"
    return "", f"no idle runner carries {', '.join(f'`{c}`' for c in candidates)} now"


def owned_queue_route(labels: str | Sequence[str], runners: Sequence[Mapping[str, Any]] | None) -> tuple[str, str]:
    """(the first watched owned label, or a wider class of it, that an online runner carries, else the first
    one any registered runner carries, or "", why).

    Taken only while every Blacksmith macOS label is stalled: a busy owned pool frees within one build,
    while a stalled Blacksmith label may not move for an hour. A job here is marked and watched: the rescue
    holds it while the Blacksmith label its re-run would take is stalled, for NIGHTLY_HOLD_SECONDS at most,
    then re-runs this picker (owned_pool_rescue.hold_for_destination(), rerun_failed_or_repick()). So a
    label whose runners are all offline still beats a stalled Blacksmith label, which nothing watches: the
    pick is made again each hold until a runner comes online or a Blacksmith label moves. Only a pool no
    registered runner carries goes to the stalled Blacksmith label. Run 40622241620 (2026-10-28) queued
    build-nightly-app on a stalled Blacksmith label from 02:40 to 02:55 while the nightly slots took the
    next two tips at 02:53 and 02:57."""
    wanted = [label for label in (labels.split() if isinstance(labels, str) else labels) if label]
    watched = [label for label in wanted if owned_label(label)]
    if not watched or runners is None:
        return "", "no watched owned label could be read"
    candidates = list(dict.fromkeys(c for label in watched for c in placement.compatible_labels(label)))
    for candidate in candidates:
        online = sum(1 for runner in runners if runner.get("status") == "online"
                     and pool.carries_office_pool_label(runner, candidate))
        if online:
            return candidate, f"`{candidate}` has {online} online runner(s), all busy, while every Blacksmith macOS label is stalled"
    for candidate in candidates:
        registered = sum(1 for runner in runners if pool.carries_office_pool_label(runner, candidate))
        if registered:
            return candidate, (f"`{candidate}` has {registered} registered runner(s), none online, while every "
                               "Blacksmith macOS label is stalled; the rescue watches it and picks again")
    return "", f"no registered runner carries {', '.join(f'`{c}`' for c in candidates)}"


def trusted_route(pool_label: str, runner_label: str, runners: Sequence[Mapping[str, Any]] | None,
                  *, event: str, ref: str) -> tuple[str, str]:
    """Return the configured trusted NEXT runner as a JSON runs-on selector.

    The trusted runner is the configured dedicated nightly Mac.  It is
    selected with both its pool and runner-name labels so seed
    work cannot claim the same runner.  A trusted pair is emitted only after
    the routing API confirms an idle matching runner; an unread API must fall
    through to the watched owned pool or bounded Blacksmith route rather than
    queue indefinitely on a single Mac.  Other events never inherit the NEXT
    reservation.
    """
    pool_label = (pool_label or "").strip()
    runner_label = (runner_label or "").strip()
    if not pool_label or not runner_label:
        return "", "trusted NEXT pool/runner is not configured"
    if event != "push" or ref != "refs/heads/nightly-next":
        return "", f"event {event or '<unset>'} on {ref or '<unset>'} is not a nightly-next push"
    selector = json.dumps([pool_label, runner_label], separators=(",", ":"))
    if runners is None:
        return "", f"trusted NEXT selector {selector} is unavailable because runner listing is unread"
    matching = [runner for runner in runners
                if runner.get("status") == "online"
                and not runner.get("busy")
                and pool_label in pool.runner_labels(runner)
                and runner_label in pool.runner_labels(runner)]
    if matching:
        return selector, f"trusted NEXT selector {selector} has an idle runner"
    return "", f"trusted NEXT selector {selector} has no idle runner"


def unread_owned_route(labels: str | Sequence[str]) -> tuple[str, str]:
    """(the first watched owned label, or "", why) for a pick that could not read the runners."""
    wanted = [label for label in (labels.split() if isinstance(labels, str) else labels) if label]
    watched = [label for label in wanted if owned_label(label)]
    if not watched:
        return "", f"no owned label the rescue watches among {wanted or 'none'}"
    return watched[0], (f"owned runners could not be read live, so the build queues on the owned pool "
                        f"`{watched[0]}`, which the rescue watches, before Blacksmith")


def blacksmith_stalled_everywhere(variable: str, snapshot: Mapping[str, Any] | None, now: dt.datetime) -> bool:
    """Whether a fresh snapshot sees every Blacksmith macOS 26 candidate stalled."""
    labels = blacksmith_picker.candidates(variable)
    stuck = blacksmith_picker.stalled(snapshot, labels, now)
    return bool(stuck) and all(label in stuck for label in labels)


def blacksmith_route(variable: str, snapshot: Mapping[str, Any] | None, now: dt.datetime,
                     exclude: str = "") -> tuple[str, str]:
    """(a moving Blacksmith macOS 26 label, why), skipping `exclude` while another label moves."""
    label, why = blacksmith_picker.pick(variable, snapshot, now)
    if exclude and label == exclude:
        others = [other for other in blacksmith_picker.candidates(variable) if other != exclude]
        # A stale snapshot still shows a dead label (blacksmith_picker.dead()): it is no moving alternative.
        stuck = (blacksmith_picker.stalled(snapshot, others, now) or set()) | blacksmith_picker.dead(snapshot, now)
        moving = [other for other in others if other not in stuck]
        if moving:
            return moving[0], f"`{moving[0]}`, since `{exclude}` already holds a waiting leg"
    return label, why


def write_output(env: Mapping[str, str], values: Mapping[str, str], lines: Sequence[str]) -> None:
    for line in lines:
        print(f"nightly build runner: {line}")
    if env.get("GITHUB_OUTPUT"):
        with open(env["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write("".join(f"{key}={value}\n" for key, value in values.items()))
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write("\nNightly build runner:\n" + "".join(f"- {line}\n" for line in lines))


def main(env: Mapping[str, str] = os.environ,
         read_runners: Callable[[str, str], Sequence[Mapping[str, Any]]] | None = None,
         read_snapshot: Callable[[str, str], Any] | None = None,
         now: dt.datetime | None = None, argv: Sequence[str] = (),
         sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic,
         read_admission_fn: Callable[[str, str], Mapping[str, Any] | None] | None = None) -> int:
    now = now or dt.datetime.now(dt.timezone.utc)
    repo = env.get("GITHUB_REPOSITORY", "")
    attempt = (env.get("GITHUB_RUN_ATTEMPT") or "").strip()
    labels = (env.get("OWNED_LABELS") or "").split()
    # A separately enrolled all-nightly mini is an explicit reservation, not an
    # idle-capacity guess. Its first-attempt route survives routing-App quota
    # failures and a busy preceding nightly job. Retries keep the existing picker.
    nightly_only = (env.get("NIGHTLY_ONLY_LABEL") or "").strip()
    if (not argv and repo == "manaflow-ai/cmux" and attempt == "1"
            and env.get("GITHUB_REF") == "refs/heads/nightly-next"
            and env.get("GITHUB_EVENT_NAME") in {"push", "workflow_dispatch"}
            and nightly_only == "glaeda-nightly-only-m4pro"):
        blacksmith, _ = blacksmith_route((env.get("CANDIDATE") or "").strip(), None, now,
                                         (env.get("EXCLUDE") or "").strip())
        write_output(env, {"dedicated": nightly_only, "trusted": "", "owned": nightly_only,
                           "blacksmith": blacksmith, "runner": nightly_only,
                           "helper": nightly_only, "attempt": attempt},
                     ["the explicitly reserved all-nightly mini takes the app and helper"])
        return 0
    dedicated_label = (env.get("DEDICATED_LABEL") or "").strip()
    only_dedicated = list(argv[:1]) == ["dedicated"]
    only_verify = list(argv[:1]) == ["verify"]
    if only_verify:
        dedicated_label = ""  # the verify jobs never take the dedicated builder: it keeps that Mac for the next build
    event = (env.get("GITHUB_EVENT_NAME") or "").strip()
    ref = (env.get("GITHUB_REF") or "").strip()
    off_event = bool(dedicated_label) and event not in DEDICATED_EVENTS
    if off_event:
        dedicated_label = ""

    route_token = env.get("ROUTE_TOKEN", "")

    def read() -> Sequence[Mapping[str, Any]] | None:
        if not (route_token and repo):
            return None
        try:
            return (read_runners or (lambda token, name: pool.GitHub(token, name).runners()))(route_token, repo)
        except Exception as error:  # noqa: BLE001 - never fail the job; the next pool takes it
            print(f"::warning title=nightly build runner::could not list owned runners ({str(error)[:200]})")
            return None

    # Before the busy wait: a builder that is refusing jobs is skipped at once, not waited on.
    # The trusted pair names the same Mac (trusted_route()), so its runner label's jobs are its admissions too.
    refused_why = ""
    admission_labels = [dedicated_label] + [label for label in [(env.get("TRUSTED_RUNNER") or "").strip()] if label]
    if pool.nightly_dedicated(dedicated_label) and env.get("SNAPSHOT_TOKEN") and repo:
        try:
            latest = (read_admission_fn or (lambda token, name: read_admission(pool.GitHub(token, name),
                                                                               admission_labels)))(
                env["SNAPSHOT_TOKEN"], repo)
            refused_why = refusal(dedicated_label, latest, now)
        except Exception as error:  # noqa: BLE001 - an unread refusal leaves the builder offered
            print(f"::warning title=nightly build runner::could not read the dedicated builder's recent "
                  f"admissions ({str(error)[:200]})")
    waited_from = clock()
    if refused_why:
        dedicated, dedicated_why = "", refused_why
    else:
        dedicated, dedicated_why = dedicated_route(dedicated_label, read, sleep=sleep, clock=clock,
                                                   wait_seconds=0 if only_dedicated else DEDICATED_WAIT_SECONDS)
    if off_event:
        dedicated_why = f"event {event or '<unset>'} is not one the builder admits (push)"
    # The Blacksmith pick below reads queue ages against `now`: move it past the wait.
    now += dt.timedelta(seconds=max(0.0, clock() - waited_from))
    if only_dedicated:
        write_output(env, {"dedicated": dedicated}, [f"dedicated: {dedicated or 'none'} ({dedicated_why})"])
        return 0

    runners = None
    if not dedicated and any(owned_label(label) for label in labels):
        runners = read()
    owned, owned_why = (dedicated, "the dedicated builder") if dedicated else owned_route(labels, runners)

    snapshot = None
    snapshot_token = env.get("SNAPSHOT_TOKEN", "")
    if snapshot_token and repo:
        try:
            if read_snapshot is None:
                snapshot = pool.GitHub(snapshot_token, repo).snapshot(now=now)
            else:
                snapshot = read_snapshot(snapshot_token, repo)
        except Exception as error:  # noqa: BLE001 - the variable keeps its say
            print(f"::warning title=nightly build runner::could not read the pool snapshot ({str(error)[:200]})")
    candidate = (env.get("CANDIDATE") or "").strip()
    blacksmith, blacksmith_why = blacksmith_route(candidate, snapshot, now, (env.get("EXCLUDE") or "").strip())
    if not owned and runners is None and (env.get("UNREAD_OWNED_FALLBACK") or "").strip() == "1":
        # Only where the caller opts in (UNREAD_OWNED_FALLBACK=1): nightly.yml's build pick sets it while
        # vars.CI_PR_POOL_OWNED is on, and the owned-pool rescue watches that build. Off (the kill switch), no
        # owned label is offered; the train (nightly-next-train.yml) has no rescue, so it keeps Blacksmith.
        # Fleet first (Leo, 2026-10-30: Blacksmith is capped, paid overflow): runners the picker cannot read (its
        # token's API budget spent, or no routing token) are not a reason to send the build to Blacksmith macOS.
        # On 2026-10-31 run 41203691245's picker got a 403 rate limit on /actions/runners and queued the first tip
        # build after a three-hour red on blacksmith-6vcpu-macos-26, which started nothing, while the nightly slot
        # pool had nine minis. The watched owned pool is a many-runner label the rescue watches and moves.
        pooled, pooled_why = unread_owned_route(labels)
        if pooled:
            owned, owned_why = pooled, pooled_why
    if not owned and runners is not None and blacksmith_stalled_everywhere(candidate, snapshot, now):
        # Owned Macs before Blacksmith (Leo, 2026-10-24): queue on the busy owned pool, not a stalled label.
        queued, queued_why = owned_queue_route(labels, runners)
        if queued:
            owned, owned_why = queued, queued_why
    trusted, trusted_why = trusted_route(
        env.get("TRUSTED_POOL", ""), env.get("TRUSTED_RUNNER", ""), runners,
        event=event, ref=ref,
    )
    if refused_why and trusted:
        # The trusted pair is the dedicated builder (trusted_route()), and build-nightly-app takes `trusted`
        # before `owned`: offering it would send the build back to the Mac that is refusing it.
        trusted, trusted_why = "", f"{refused_why} (the trusted pair is the same builder)"
    if only_verify:
        write_output(env, {"owned": owned}, [f"verify: {owned or 'none'} ({owned_why})",
                                             f"blacksmith otherwise: {blacksmith} ({blacksmith_why})"])
        return 0

    # The Ghostty helper never takes the dedicated builder (its hook admits only build-nightly-app),
    # so while the app build holds it the helper gets its own owned pick, as the verify jobs do.
    helper, helper_why = owned, owned_why
    if dedicated:
        helper_runners = read() if any(owned_label(label) for label in labels) else None
        helper, helper_why = owned_route(labels, helper_runners)
    runner = owned or blacksmith
    write_output(env, {"dedicated": dedicated, "trusted": trusted, "owned": owned, "blacksmith": blacksmith, "runner": runner,
                       "helper": helper, "attempt": attempt or "1"},
                 [f"dedicated: {dedicated or 'none'} ({dedicated_why})", f"trusted: {trusted or 'none'} ({trusted_why})",
                  f"owned: {owned or 'none'} ({owned_why})",
                  f"blacksmith: {blacksmith} ({blacksmith_why})", f"route: {runner}",
                  f"helper: {helper or blacksmith} ({helper_why if helper else 'no idle owned Mac besides the dedicated builder, so Blacksmith'})",
                  f"attempt: {attempt or '1'}"])
    return 0


if __name__ == "__main__":
    sys.exit(main(argv=sys.argv[1:]))
