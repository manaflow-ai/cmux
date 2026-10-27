#!/usr/bin/env python3
"""Pick the Blacksmith macOS label the nightly's sign, notarize and publish jobs take.

Signing stays on Blacksmith (keys stay in GitHub environment secrets, never on
a mini). Those jobs used to take `vars.MACOS_RUNNER_26` alone, so when that
variable named a label with no runners (blacksmith-12vcpu-macos-26 started
nothing from about 01:20Z on 2026-10-26) every nightly waited on it and the
feed went eight hours stale.

This reads the queue janitor's pool snapshot (macos-pool-load, at most
next_macos_cascade.QUEUE_SNAPSHOT_MINUTES old; two API requests) and prints the
first candidate whose queue is moving: vars.MACOS_RUNNER_26 when it names a
Blacksmith macOS label, then 6 vCPU, then 12 vCPU. A label is not moving when
the snapshot saw a job wait on it for simple_pool_picker.BLACKSMITH_STALL_MINUTES or more.
With no fresh snapshot (or an unreadable one) the variable keeps its say, as
before. It never prints an empty label and never fails the job:

    SNAPSHOT_TOKEN=<actions: read> CANDIDATE=<vars.MACOS_RUNNER_26> nightly_sign_runner.py
    -> `runner=<label>` in $GITHUB_OUTPUT, and why in the step summary
"""

from __future__ import annotations

import datetime as dt
import os
import re
import sys
from pathlib import Path
from typing import Any, Callable, Mapping

sys.path.insert(0, str(Path(__file__).resolve().parent))
import next_macos_cascade as cascade  # noqa: E402

BLACKSMITH_MACOS = re.compile(r"blacksmith-[0-9]+vcpu-macos-26")
DEFAULT = cascade.SMALL


def candidates(variable: str) -> list[str]:
    """The variable's label when it is a Blacksmith macOS 26 label, then 6 vCPU, then 12 vCPU."""
    first = [variable] if BLACKSMITH_MACOS.fullmatch(variable or "") else []
    return list(dict.fromkeys([*first, cascade.SMALL, cascade.LARGE]))


def stalled(snapshot: Mapping[str, Any] | None, labels: list[str], now: dt.datetime) -> set[str] | None:
    """The labels a fresh snapshot saw a job wait on for STALL_MINUTES or more; None without one."""
    fresh = cascade._fresh(snapshot, now)  # noqa: SLF001 - the cascade's own freshness rule
    if fresh is None:
        return None
    age, pools = fresh
    age = max(0.0, age)
    out = set()
    for label in labels:
        # The one Blacksmith stall rule (simple_pool_picker.blacksmith_stalled, 10 min).
        if cascade._picker_rule.blacksmith_stalled(cascade._field(pools, label, "queued"),  # noqa: SLF001
                                                   cascade._field(pools, label, "oldest_queued_minutes"), age):  # noqa: SLF001
            out.add(label)
    return out


def pick(variable: str, snapshot: Mapping[str, Any] | None, now: dt.datetime) -> tuple[str, str]:
    """(label, why)."""
    labels = candidates(variable)
    stuck = stalled(snapshot, labels, now)
    if stuck is None:
        return labels[0], f"no fresh pool snapshot, so `{labels[0]}` (vars.MACOS_RUNNER_26 or the default)"
    moving = [label for label in labels if label not in stuck]
    if not moving:
        return DEFAULT, f"every Blacksmith macOS label is stalled ({', '.join(sorted(stuck))}); `{DEFAULT}` has the most slots"
    skipped = [label for label in labels[: labels.index(moving[0])]]
    why = f"`{moving[0]}`" + (f", past stalled {', '.join(f'`{s}`' for s in skipped)}" if skipped else "")
    return moving[0], why


def main(env: Mapping[str, str] = os.environ, read: Callable[[str, str], Any] | None = None,
         now: dt.datetime | None = None) -> int:
    now = now or dt.datetime.now(dt.timezone.utc)
    variable = (env.get("CANDIDATE") or "").strip()
    snapshot = None
    token, repo = env.get("SNAPSHOT_TOKEN", ""), env.get("GITHUB_REPOSITORY", "")
    if token and repo:
        try:
            if read is None:
                import pr_runner_pool  # noqa: PLC0415 - only for the live read

                snapshot = pr_runner_pool.GitHub(token, repo).snapshot(now=now)
            else:
                snapshot = read(token, repo)
        except Exception as error:  # noqa: BLE001 - never fail the job; the variable keeps its say
            print(f"::warning title=nightly sign runner::could not read the pool snapshot ({str(error)[:200]})")
    label, why = pick(variable, snapshot, now)
    print(f"nightly sign runner: {why}")
    if env.get("GITHUB_OUTPUT"):
        with open(env["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write(f"runner={label}\n")
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write(f"\nNightly sign runner: {why}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
