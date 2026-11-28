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

It never fails the job:

    ROUTE_TOKEN=<administration: read> DEDICATED_LABEL=<vars.CI_IOS_INTERNAL_RUNNER> ios_internal_runner.py
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
    line = f"archive runner: {dedicated or 'Blacksmith'} ({why}), attempt {attempt}"
    print(line)
    if env.get("GITHUB_OUTPUT"):
        with open(env["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write(f"dedicated={dedicated}\nattempt={attempt}\n")
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write(f"- {line}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
