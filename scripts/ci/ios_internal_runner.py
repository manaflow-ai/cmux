#!/usr/bin/env python3
"""Pick the iPhone INTERNAL archive's runner: the dedicated mini while it can take the job, else Blacksmith.

ios-internal-nightly.yml's archive read `vars.CI_IOS_INTERNAL_RUNNER || ...` in its runs-on. The
variable names one mini's own runner label (glaeda-runner-<runner name>), and a set variable never
falls through, so every archive waited on that one mini however long it was busy or offline. Leo,
2026-10-24: no job waits on one reserved machine; the routing order is owned Macs, then Blacksmith
macOS last. The PR pools are not an owned option here: the archive is what gets signed and shipped to
TestFlight, so it runs on the dedicated mini (warm caches) or an ephemeral Blacksmith Mac, never on a
machine that runs pull request code.

A Linux job runs this right before the archive queues and prints:

- `dedicated`: the first of the variable's labels an online runner carrying it is idle for, waiting up
  to WAIT_SECONDS (5 min) while one is busy. Empty when the variable is unset, the runners cannot be
  read (no routing token), or every listed mini is offline or still busy.

The variable may list several trusted builder labels (comma or space separated), preferred first
(the first keeps the warmest caches). Leo, 2026-11-25: "Why are these iPhone builds still so slow
and unverified? Don't we have freed up Mac capacity?" With one label, run 45681529736 found the mini
busy and queued 17.9 min for a Blacksmith Mac (the fallback before #56877) for its 20 min archive.
Each listed label must name a machine that runs no pull request code (same trust as the one mini).
- `attempt`: GITHUB_RUN_ATTEMPT, the attempt this pick was made for. The archive takes `dedicated`
  only on that attempt, so a re-run of failed jobs that keeps this job's outputs takes Blacksmith.

- `fallback`: FALLBACK_MAC (an ephemeral Blacksmith Mac, whose image has Xcode 27) when the runner census
  (CI_RUNNER_STATE) shows no online Mac runner carrying FLEET_XCODE's Xcode label, else empty (the archive
  takes the fleet's `cmux-mac` + `xcode-27.0`). Leo, 2026-11-26: "refuse to queue a job for a label no live
  runner has". Run 45717448413's archive asked for cmux-mac + xcode-27.0 at 22:59Z on 11-25 and started at
  01:22Z on 11-26: 2 h 23 min with no Mac offering Xcode 27, while a Blacksmith Mac takes it in minutes. An
  unread or stale census keeps the fleet label: the reroute needs a reading, never a guess.

It never fails the job:

    ROUTE_TOKEN=<administration: read> DEDICATED_LABEL=<vars.CI_IOS_INTERNAL_RUNNER> FALLBACK_MAC=<label> ios_internal_runner.py
"""

from __future__ import annotations

import os
import sys
import time
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pr_runner_pool as pool  # noqa: E402

WAIT_SECONDS = 5 * 60
LOOK_SECONDS = 30
# The archive's fleet fallback (ios-internal-nightly.yml's runs-on ends with it): the scheduler grants cmux-mac
# on demand, so its Xcode label is what needs a live carrier.
FLEET_XCODE = ("cmux-mac", "xcode-27.0")


def labels_of(value: str) -> list[str]:
    """The variable's labels in order, duplicates dropped: `a,b c` is [a, b, c]."""
    out: list[str] = []
    for label in value.replace(",", " ").split():
        if label not in out:
            out.append(label)
    return out


def state(label: str, runners: Sequence[Mapping[str, Any]] | None) -> str:
    """'idle', 'busy', 'offline' or 'unread' for the runners carrying `label`."""
    if runners is None:
        return "unread"
    online = [runner for runner in runners if runner.get("status") == "online" and label in pool.runner_labels(runner)]
    if not online:
        return "offline"
    return "idle" if any(not runner.get("busy") for runner in online) else "busy"


def pick(label: str, read: Callable[[], Sequence[Mapping[str, Any]] | None], *,
         wait_seconds: float = WAIT_SECONDS, look_seconds: float = LOOK_SECONDS,
         sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic) -> tuple[str, str]:
    """(the first of `label`'s labels a runner is idle for, waiting up to `wait_seconds` while one is busy, or "", why)."""
    labels = labels_of(label)
    if not labels:
        return "", "CI_IOS_INTERNAL_RUNNER is unset"
    deadline = clock() + wait_seconds
    while True:
        runners = read()
        states = {one: state(one, runners) for one in labels}
        for one in labels:
            if states[one] == "idle":
                return one, f"`{one}` is online and idle"
        seen = ", ".join(f"`{one}` is {states[one]}" for one in labels)
        if "busy" not in states.values():
            return "", seen
        if clock() + look_seconds > deadline:
            return "", f"{seen}: stayed busy for {round(wait_seconds / 60)} min"
        sleep(look_seconds)


def xcode_carried(labels: Sequence[str], runners: Sequence[Mapping[str, Any]] | None) -> bool | None:
    """Whether an online runner carries every `xcode-<v>` label of `labels`; None when the runners are unread.

    A standing glaeda runner carries `xcode-<v>` only for an Xcode its host really has (glaeda_fleet_labels), and a
    granted runner only for the Xcode its Mac asked with, so an online one is a Mac that can run the job."""
    if runners is None:
        return None
    need = {label for label in labels if label.startswith("xcode-")}
    return any(runner.get("status") == "online" and need <= pool.runner_labels(runner) for runner in runners)


def fleet_fallback(env: Mapping[str, str]) -> tuple[str, str]:
    """(FALLBACK_MAC when the census shows no live carrier of FLEET_XCODE, else "", why)."""
    fallback = (env.get("FALLBACK_MAC") or "").strip()
    if not fallback:
        return "", "FALLBACK_MAC is unset"
    document = pool.runner_state(env.get("GITHUB_REPOSITORY", ""), raw=env.get("CI_RUNNER_STATE", ""))
    carried = xcode_carried(FLEET_XCODE, None if document is None else pool.census_runners(document))
    xcode = " + ".join(FLEET_XCODE)
    if carried is None:
        return "", f"no fresh runner census: `{xcode}` kept"
    if carried:
        return "", f"an online runner carries `{xcode}`"
    return fallback, f"no online runner carries `{xcode}`: `{fallback}`"


def main(env: Mapping[str, str] = os.environ,
         read_runners: Callable[[str, str], Sequence[Mapping[str, Any]]] | None = None,
         sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic) -> int:
    repo = env.get("GITHUB_REPOSITORY", "")
    token = env.get("ROUTE_TOKEN", "")
    label = (env.get("DEDICATED_LABEL") or "").strip()
    first_look = True

    def read() -> Sequence[Mapping[str, Any]] | None:
        nonlocal first_look
        use_state, first_look = first_look, False
        if not (token and repo):
            return None
        try:
            if use_state:
                document = pool.runner_state(repo, raw=env.get("CI_RUNNER_STATE", ""))
                if document is not None:
                    # Keep this picker's repository-only registration scope.
                    print("Runner state: trusted repository document (no runner API requests)", file=sys.stderr)
                    return document["repository_runners"]
            if read_runners is not None:
                return read_runners(token, repo)
            # The dedicated mini is a repository runner, so the repository's list is enough.
            return list(pool.GitHub(token, repo)._runner_pages(f"/repos/{repo}/actions/runners"))
        except Exception as error:  # noqa: BLE001 - never fail the job; Blacksmith takes it
            # The error's type only: its text could carry a response body into this log.
            print(f"::warning title=iOS archive runner::could not list runners ({type(error).__name__})")
            return None

    dedicated, why = pick(label, read, sleep=sleep, clock=clock)
    attempt = (env.get("GITHUB_RUN_ATTEMPT") or "").strip() or "1"
    fallback, fallback_why = ("", "") if dedicated else fleet_fallback(env)
    if dedicated:
        line = f"archive runner: {dedicated} ({why}), attempt {attempt}"
    else:
        line = f"archive runner: {fallback or ' + '.join(FLEET_XCODE)} ({why}; {fallback_why}), attempt {attempt}"
    print(line)
    if env.get("GITHUB_OUTPUT"):
        with open(env["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write(f"dedicated={dedicated}\nattempt={attempt}\nfallback={fallback}\n")
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write(f"- {line}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
