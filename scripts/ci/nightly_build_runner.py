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
  with). Empty on any attempt after 1, when no label is one the rescue watches, or when the runners cannot be read: a busy fleet is never waited on.
- `blacksmith`: the Blacksmith macOS 26 label whose queue moves
  (nightly_sign_runner.pick(): vars.MACOS_RUNNER_26, then 6 vCPU, then 12 vCPU,
  past any stalled one). Never empty. EXCLUDE (a label another leg already
  waits on) is skipped while another candidate moves.

`owned` is `dedicated` when that is set. The workflow takes `owned` on attempt 1 and
`blacksmith` otherwise. A job an
owned runner refuses at "Set up runner", or one stuck on an owned label after
an idle runner was taken by another job, is re-run by ci-owned-pool-rescue.yml
(owned_pool_rescue.py watches nightly-next push runs); that re-run is attempt 2,
which reads `blacksmith`, so the next pool takes it instead of the same label.

It never fails the job and never prints an empty `blacksmith`:

    ROUTE_TOKEN=<org runners: read> SNAPSHOT_TOKEN=<actions: read> OWNED_LABELS='<a> <b>' CANDIDATE=<vars.MACOS_RUNNER_26> \\
        DEDICATED_LABEL=<vars.CI_NIGHTLY_NEXT_DEDICATED_LABEL> \\
        nightly_build_runner.py   -> dedicated=..., owned=..., blacksmith=..., runner=... in $GITHUB_OUTPUT

`nightly_build_runner.py dedicated` prints only `dedicated`, with no wait: the signed-app
verify takes the dedicated builder only while it is idle now (pick-nightly-sign-runner).
"""

from __future__ import annotations

import datetime as dt
import os
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
def owned_label(label: str) -> bool:
    return pool.persistent(label)


# How long a run waits for the dedicated builder while it is busy, and how often it looks. Its
# incremental build of the previous tip or a 3-minute verify usually ends inside this; a longer
# wait would cost more than the cold build on the next pool saves.
DEDICATED_WAIT_SECONDS = 5 * 60
DEDICATED_LOOK_SECONDS = 30


def dedicated_state(label: str, runners: Sequence[Mapping[str, Any]] | None) -> str:
    """'idle', 'busy', 'offline', 'unread' or 'off' for the dedicated builder's label."""
    if not pool.nightly_dedicated(label):
        return "off"
    if runners is None:
        return "unread"
    online = [runner for runner in runners
              if runner.get("status") == "online" and label in pool.runner_labels(runner)]
    if not online:
        return "offline"
    return "idle" if any(not runner.get("busy") for runner in online) else "busy"


def dedicated_route(label: str, read: Callable[[], Sequence[Mapping[str, Any]] | None], attempt: str, *,
                    wait_seconds: float = DEDICATED_WAIT_SECONDS, look_seconds: float = DEDICATED_LOOK_SECONDS,
                    sleep: Callable[[float], None] = time.sleep,
                    clock: Callable[[], float] = time.monotonic) -> tuple[str, str]:
    """(the dedicated label while its runner is idle, waiting up to `wait_seconds` while it is busy, or "", why)."""
    if attempt not in ("", "1"):
        return "", f"attempt {attempt} takes Blacksmith"
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


def owned_route(labels: str | Sequence[str], runners: Sequence[Mapping[str, Any]] | None,
                attempt: str) -> tuple[str, str]:
    """(the first watched owned label, or a wider class of it, with an idle runner now, or "", why)."""
    wanted = [label for label in (labels.split() if isinstance(labels, str) else labels) if label]
    if attempt not in ("", "1"):
        return "", f"attempt {attempt} takes Blacksmith, the next pool after the owned one"
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

    route_token = env.get("ROUTE_TOKEN", "")

    def read() -> Sequence[Mapping[str, Any]] | None:
        if not (route_token and repo):
            return None
        try:
            return (read_runners or (lambda token, name: pool.GitHub(token, name).runners()))(route_token, repo)
        except Exception as error:  # noqa: BLE001 - never fail the job; the next pool takes it
            print(f"::warning title=nightly build runner::could not list owned runners ({str(error)[:200]})")
            return None

    dedicated, dedicated_why = dedicated_route(dedicated_label, read, attempt, sleep=sleep, clock=clock,
                                               wait_seconds=0 if only_dedicated else DEDICATED_WAIT_SECONDS)
    if only_dedicated:
        write_output(env, {"dedicated": dedicated}, [f"dedicated: {dedicated or 'none'} ({dedicated_why})"])
        return 0

    runners = None
    if not dedicated and attempt in ("", "1") and any(owned_label(label) for label in labels):
        runners = read()
    owned, owned_why = (dedicated, "the dedicated builder") if dedicated else owned_route(labels, runners, attempt)

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

    runner = owned or blacksmith
    write_output(env, {"dedicated": dedicated, "owned": owned, "blacksmith": blacksmith, "runner": runner},
                 [f"dedicated: {dedicated or 'none'} ({dedicated_why})", f"owned: {owned or 'none'} ({owned_why})",
                  f"blacksmith: {blacksmith} ({blacksmith_why})", f"route: {runner}"])
    return 0


if __name__ == "__main__":
    sys.exit(main(argv=sys.argv[1:]))
