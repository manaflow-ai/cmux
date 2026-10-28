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
  of the previous tip, or a verify) this waits up to DEDICATED_WAIT_SECONDS (5 min) for it,
  reading the runners every 30 s; offline, unread or still busy after that, it is skipped.
  Leo, 2026-10-27: "what if we just dedicatd one, only, always, and it just
  incrementally... did the thing?"
- `owned`: the first of OWNED_LABELS (vars.CI_NIGHTLY_NEXT_BUILD_RUNNER, then
  vars.CI_SIDE_LANE_RUNNER) that the rescue watches, or the same label on a wider class
  (side_lane_placement.compatible_labels()), while an online runner carrying it
  is idle now (pr_runner_pool.live_owned_free(), the rule side lanes are placed
  with). Empty when no label is one the rescue watches, or when the runners
  cannot be read (no routing token): a busy fleet is never waited on.
- `blacksmith`: the Blacksmith macOS 26 label whose queue moves
  (nightly_sign_runner.pick(): vars.MACOS_RUNNER_26, then 6 vCPU, then 12 vCPU,
  past any stalled one). Never empty. EXCLUDE (a label another leg already
  waits on) is skipped while another candidate moves.

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


# How long a run waits for the dedicated builder while it is busy, and how often it looks. Its
# incremental build of the previous tip or a 3-minute verify usually ends inside this; a longer
# wait would cost more than the cold build on the next pool saves.
DEDICATED_WAIT_SECONDS = 5 * 60
DEDICATED_LOOK_SECONDS = 30


# The builder admits only a push to nightly-next (nightly_builder.py admit). A dispatched run sent
# there is refused at "Set up runner" (run 40594111618, 2026-10-27: "event workflow_dispatch is not push").
DEDICATED_EVENTS = frozenset({"push"})


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


def blacksmith_route(variable: str, snapshot: Mapping[str, Any] | None, now: dt.datetime,
                     exclude: str = "") -> tuple[str, str]:
    """(a moving Blacksmith macOS 26 label, why), skipping `exclude` while another label moves."""
    label, why = blacksmith_picker.pick(variable, snapshot, now)
    if exclude and label == exclude:
        others = [other for other in blacksmith_picker.candidates(variable) if other != exclude]
        stuck = blacksmith_picker.stalled(snapshot, others, now) or set()
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
         sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic) -> int:
    now = now or dt.datetime.now(dt.timezone.utc)
    repo = env.get("GITHUB_REPOSITORY", "")
    attempt = (env.get("GITHUB_RUN_ATTEMPT") or "").strip()
    labels = (env.get("OWNED_LABELS") or "").split()
    dedicated_label = (env.get("DEDICATED_LABEL") or "").strip()
    only_dedicated = list(argv[:1]) == ["dedicated"]
    only_verify = list(argv[:1]) == ["verify"]
    if only_verify:
        dedicated_label = ""  # the verify jobs never take the dedicated builder: it keeps that Mac for the next build
    event = (env.get("GITHUB_EVENT_NAME") or "").strip()
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

    waited_from = clock()
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
    blacksmith, blacksmith_why = blacksmith_route((env.get("CANDIDATE") or "").strip(), snapshot, now,
                                                  (env.get("EXCLUDE") or "").strip())
    if only_verify:
        write_output(env, {"owned": owned}, [f"verify: {owned or 'none'} ({owned_why})",
                                             f"blacksmith otherwise: {blacksmith} ({blacksmith_why})"])
        return 0

    runner = owned or blacksmith
    write_output(env, {"dedicated": dedicated, "owned": owned, "blacksmith": blacksmith, "runner": runner,
                       "attempt": attempt or "1"},
                 [f"dedicated: {dedicated or 'none'} ({dedicated_why})", f"owned: {owned or 'none'} ({owned_why})",
                  f"blacksmith: {blacksmith} ({blacksmith_why})", f"route: {runner}", f"attempt: {attempt or '1'}"])
    return 0


if __name__ == "__main__":
    sys.exit(main(argv=sys.argv[1:]))
