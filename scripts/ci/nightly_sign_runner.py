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
Without a fresh snapshot (none, a stale one, or one still unreadable after
SNAPSHOT_READS tries) the placement is unverified, and says so: `placement=unverified`
in the outputs, a ::warning and a step-summary line. It then takes DEFAULT, the size
with the most slots, never the variable unchecked (that variable named the dead
12 vCPU label on 2026-10-26), with the other size as `alternate`; a full re-run
that is still blind takes the other size. It never prints an empty label and never
fails the job: a failed placement step would leave the signing jobs on the variable alone.

It also prints `alternate`, the other Blacksmith macOS 26 size, unless the
snapshot sees that size stalled too: then `alternate` is the pick itself. GitHub never re-routes a queued job, and the pick is made once: a label
that stalls after it holds the job until the run is cancelled. A re-run of
failed jobs keeps this job's outputs, so the signing jobs read `alternate` on
attempt 2 and later, and the re-run (the owned-pool rescue's or a person's)
moves off the label that stalled instead of queueing on it again.
A label the snapshot shows dead (dead(): nothing running and no job started for an hour; a snapshot too old
for the stall rule, up to six hours, still shows it) counts as stalled, is never `alternate`, and an unverified
placement does not rotate onto it. When this
step itself runs on a later attempt (a full re-run picks again), its pick is
fresh, so `alternate` is that pick (run 40500413442's full re-run took the
stale 12 vCPU alternate over a fresh pick, 2026-10-27):

    SNAPSHOT_TOKEN=<actions: read> CANDIDATE=<vars.MACOS_RUNNER_26> nightly_sign_runner.py
    -> `runner=<label>`, `alternate=<label>` and `placement=verified|unverified` in $GITHUB_OUTPUT,
       and why in the step summary
"""

from __future__ import annotations

import datetime as dt
import os
import re
import sys
import time
from pathlib import Path
from typing import Any, Callable, Mapping

sys.path.insert(0, str(Path(__file__).resolve().parent))
import next_macos_cascade as cascade  # noqa: E402

BLACKSMITH_MACOS = re.compile(r"blacksmith-[0-9]+vcpu-macos-26")
DEFAULT = cascade.SMALL
# An unreadable snapshot is read again, at most SNAPSHOT_READS times, and no new read starts
# SNAPSHOT_READ_SECONDS after the first: one read can take a minute (15 + 15 + 30 s of
# timeouts), and the 2-minute placement step must still write its outputs.
SNAPSHOT_READS = 3
SNAPSHOT_READ_SECONDS = 40
SNAPSHOT_RETRY_PAUSE = 5.0


def candidates(variable: str) -> list[str]:
    """The variable's label when it is a Blacksmith macOS 26 label, then 6 vCPU, then 12 vCPU."""
    first = [variable] if BLACKSMITH_MACOS.fullmatch(variable or "") else []
    return list(dict.fromkeys([*first, cascade.SMALL, cascade.LARGE]))


def dead(snapshot: Mapping[str, Any] | None, now: dt.datetime) -> set[str]:
    """The Blacksmith macOS 26 labels the snapshot (fresh or not) shows dead (simple_pool_picker.blacksmith_dead():
    nothing running and no job started on it for an hour, from a snapshot up to six hours old), or none when it
    shows every one dead: with no label showing life it says nothing to choose by."""
    labels = (cascade.SMALL, cascade.LARGE)
    out = {label for label in labels if cascade._picker_rule.blacksmith_dead(snapshot, label, now)}  # noqa: SLF001
    return set() if out >= set(labels) else out


def stalled(snapshot: Mapping[str, Any] | None, labels: list[str], now: dt.datetime) -> set[str] | None:
    """The labels a fresh snapshot saw a job wait on for STALL_MINUTES or more, or shows dead (dead()); None
    without one. The stall rule alone calls a busy label and a dead one stalled alike: on 2026-10-30
    blacksmith-12vcpu-macos-26 had started nothing for about a day while 6 vCPU, stalled by that rule too,
    ran 5 jobs."""
    fresh = cascade._fresh(snapshot, now)  # noqa: SLF001 - the cascade's own freshness rule
    if fresh is None:
        return None
    age, pools = fresh
    age = max(0.0, age)
    out = dead(snapshot, now) & set(labels)
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
        # A busy label still starts jobs; a dead one starts none.
        gone = dead(snapshot, now)
        label = DEFAULT if DEFAULT not in gone else next((other for other in labels if other not in gone), DEFAULT)
        return label, (f"every Blacksmith macOS label is stalled ({', '.join(sorted(stuck))}); `{label}` "
                       + ("has the most slots" if label == DEFAULT else f"still starts jobs (`{DEFAULT}` is dead)"))
    skipped = [label for label in labels[: labels.index(moving[0])]]
    why = f"`{moving[0]}`" + (f", past stalled {', '.join(f'`{s}`' for s in skipped)}" if skipped else "")
    return moving[0], why


def alternate(variable: str, label: str, snapshot: Mapping[str, Any] | None, now: dt.datetime) -> str:
    """The Blacksmith macOS 26 label a re-run takes: the other size, unless the snapshot sees it stalled.

    Never a label a fresh snapshot saw stalled: with every other size stalled it is `label` itself.
    """
    others = [other for other in candidates(variable) if other != label]
    stuck = stalled(snapshot, others, now) or set()
    return next((other for other in others if other not in stuck), label)


def read_snapshot(read: Callable[[], Any], title: str, *, sleep: Callable[[float], None] = time.sleep,
                  clock: Callable[[], float] = time.monotonic) -> tuple[Any, str]:
    """(the snapshot or None, why it could not be read or ""): a bounded retry of an unreadable read."""
    start, problem = clock(), ""
    for attempt in range(1, SNAPSHOT_READS + 1):
        try:
            return read(), ""
        except Exception as error:  # noqa: BLE001 - never fail the job; the pick says it is unverified
            problem = f"could not read the pool snapshot ({str(error)[:200]})"
        if attempt == SNAPSHOT_READS or clock() - start + SNAPSHOT_RETRY_PAUSE > SNAPSHOT_READ_SECONDS:
            break
        print(f"{title}: {problem}; reading it again ({attempt + 1} of {SNAPSHOT_READS})")
        sleep(SNAPSHOT_RETRY_PAUSE)
    return None, problem


def place(variable: str, snapshot: Mapping[str, Any] | None, now: dt.datetime, attempt: int,
          problem: str = "") -> tuple[str, str, str, bool]:
    """(runner, alternate, why, verified) for the signing jobs.

    A fresh snapshot verifies the pick (pick(), alternate()). Without one, nothing says the variable's
    label is moving, so it is not trusted: attempt 1 takes DEFAULT (the most slots) with the other
    size as `alternate`, and a full re-run (attempt 2 on, which picks again) the next size in turn.
    """
    rerun_pick = attempt > 1
    if stalled(snapshot, candidates(variable), now) is None:
        sizes = [DEFAULT, *(size for size in (cascade.SMALL, cascade.LARGE) if size != DEFAULT)]
        # A snapshot too old to verify a pick still shows which label is dead: never rotate onto it.
        gone = dead(snapshot, now)
        sizes = [size for size in sizes if size not in gone] or sizes
        label = sizes[(attempt - 1) % len(sizes)]
        other = label if rerun_pick else sizes[attempt % len(sizes)]
        if not problem:
            problem = ("no pool snapshot" if snapshot is None
                       else "the pool snapshot is stale or malformed "
                            f"(generated {str(snapshot.get('generated_at') or 'at an unknown time')[:40]})"
                       if isinstance(snapshot, Mapping) else "the pool snapshot is malformed")
        why = (f"placement unverified: {problem}, so `{label}`"
               + (" (the size with the most slots)" if label == DEFAULT else " (the next size on this re-run)")
               + ", not vars.MACOS_RUNNER_26 unchecked")
        return label, other, why, False
    label, why = pick(variable, snapshot, now)
    # A pick made on attempt 2 or later is already fresh: the jobs reading `alternate` take it.
    return label, label if rerun_pick else alternate(variable, label, snapshot, now), why, True


def main(env: Mapping[str, str] = os.environ, read: Callable[[str, str], Any] | None = None,
         now: dt.datetime | None = None, *, sleep: Callable[[float], None] = time.sleep,
         clock: Callable[[], float] = time.monotonic) -> int:
    now = now or dt.datetime.now(dt.timezone.utc)
    variable = (env.get("CANDIDATE") or "").strip()
    snapshot, problem = None, "no token to read the pool snapshot"
    token, repo = env.get("SNAPSHOT_TOKEN", ""), env.get("GITHUB_REPOSITORY", "")
    if token and repo:
        def live() -> Any:
            if read is not None:
                return read(token, repo)
            import pr_runner_pool  # noqa: PLC0415 - only for the live read

            return pr_runner_pool.GitHub(token, repo).snapshot(now=now)
        snapshot, problem = read_snapshot(live, "nightly sign runner", sleep=sleep, clock=clock)
    try:
        attempt = max(1, int((env.get("GITHUB_RUN_ATTEMPT") or "1").strip() or "1"))
    except ValueError:
        attempt = 1
    label, other, why, verified = place(variable, snapshot, now, attempt, problem)
    if not verified:
        print(f"::warning title=nightly sign runner::{why}")
    print(f"nightly sign runner: {why}; a re-run takes `{other}`")
    if env.get("GITHUB_OUTPUT"):
        with open(env["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write(f"runner={label}\nalternate={other}\nplacement={'verified' if verified else 'unverified'}\n")
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write(f"\nNightly sign runner: {why}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
