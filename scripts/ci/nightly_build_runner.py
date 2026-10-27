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

A Linux job runs this right before the macOS job queues and prints two labels:

- `owned`: the first of OWNED_LABELS (vars.CI_NIGHTLY_NEXT_BUILD_RUNNER, then
  vars.CI_SIDE_LANE_RUNNER) that the rescue watches, or the same label on a wider class
  (side_lane_placement.compatible_labels()), while an online runner carrying it
  is idle now (pr_runner_pool.live_owned_free(), the rule side lanes are placed
  with). Empty on any attempt after 1, when no label is one the rescue watches, or when the runners cannot be read: a busy fleet is never waited on.
- `blacksmith`: the Blacksmith macOS 26 label whose queue moves
  (nightly_sign_runner.pick(): vars.MACOS_RUNNER_26, then 6 vCPU, then 12 vCPU,
  past any stalled one). Never empty. EXCLUDE (a label another leg already
  waits on) is skipped while another candidate moves.

The workflow takes `owned` on attempt 1 and `blacksmith` otherwise. A job an
owned runner refuses at "Set up runner", or one stuck on an owned label after
an idle runner was taken by another job, is re-run by ci-owned-pool-rescue.yml
(owned_pool_rescue.py watches nightly-next push runs); that re-run is attempt 2,
which reads `blacksmith`, so the next pool takes it instead of the same label.

It never fails the job and never prints an empty `blacksmith`:

    ROUTE_TOKEN=<org runners: read> SNAPSHOT_TOKEN=<actions: read> OWNED_LABELS='<a> <b>' CANDIDATE=<vars.MACOS_RUNNER_26> \\
        nightly_build_runner.py   -> owned=..., blacksmith=..., runner=... in $GITHUB_OUTPUT
"""

from __future__ import annotations

import datetime as dt
import os
import sys
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


def main(env: Mapping[str, str] = os.environ,
         read_runners: Callable[[str, str], Sequence[Mapping[str, Any]]] | None = None,
         read_snapshot: Callable[[str, str], Any] | None = None,
         now: dt.datetime | None = None) -> int:
    now = now or dt.datetime.now(dt.timezone.utc)
    repo = env.get("GITHUB_REPOSITORY", "")
    attempt = (env.get("GITHUB_RUN_ATTEMPT") or "").strip()
    labels = (env.get("OWNED_LABELS") or "").split()

    runners = None
    route_token = env.get("ROUTE_TOKEN", "")
    if attempt in ("", "1") and any(owned_label(label) for label in labels) and route_token and repo:
        try:
            runners = (read_runners or (lambda token, name: pool.GitHub(token, name).runners()))(route_token, repo)
        except Exception as error:  # noqa: BLE001 - never fail the job; Blacksmith takes it
            print(f"::warning title=nightly build runner::could not list owned runners ({str(error)[:200]})")
    owned, owned_why = owned_route(labels, runners, attempt)

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
    lines = [f"owned: {owned or 'none'} ({owned_why})", f"blacksmith: {blacksmith} ({blacksmith_why})",
             f"route: {runner}"]
    for line in lines:
        print(f"nightly build runner: {line}")
    if env.get("GITHUB_OUTPUT"):
        with open(env["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write(f"owned={owned}\nblacksmith={blacksmith}\nrunner={runner}\n")
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write("\nNightly build runner:\n" + "".join(f"- {line}\n" for line in lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
