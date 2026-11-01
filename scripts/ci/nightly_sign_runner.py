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
RUNNER_POOLS (vars.RUNNER_POOLS, runner_pools.py's one routing variable) is read too: a label its `_dead` marks
saw dead within MARK_TTL counts as dead, and with every label dead the pick is the variable's live macos_26
member, never the other one. `alternate` never names a label the snapshot or a mark shows dead, even when every
label is dead: then it is the pick itself. Until 2026-10-31 dead() dropped the evidence when it showed both
labels dead, so with no fresh snapshot a re-run still took blacksmith-12vcpu-macos-26 (05:44Z: 88 queued, none
running, the oldest 1403 min), as classic_nightly_build_runner.py did:

    SNAPSHOT_TOKEN=<actions: read> [SNAPSHOT_FALLBACK_TOKEN=<github.token>] CANDIDATE=<vars.MACOS_RUNNER_26> \\
        RUNNER_POOLS=<vars.RUNNER_POOLS> nightly_sign_runner.py
    -> `runner=<label>`, `alternate=<label>` and `placement=verified|unverified` in $GITHUB_OUTPUT,
       and why in the step summary
"""

from __future__ import annotations

import datetime as dt
import json
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
# RUNNER_POOLS' dead marks (label -> when last seen dead) and the pool the candidates form. A mark older than
# runner_pools.DEAD_TTL is one its writer would drop (it re-marks a still-dead label every pass), so it proves nothing.
DEAD_KEY = "_dead"
POOL = "macos_26"
MARK_TTL = dt.timedelta(minutes=30)
LABELS = (cascade.SMALL, cascade.LARGE)
LINUX_LABELS = ("blacksmith-4vcpu-ubuntu-2404", "blacksmith-16vcpu-ubuntu-2404", "blacksmith-32vcpu-ubuntu-2404")
# Nightly overflow moves a queued signer to another declared size after about
# three minutes with no start; this is shorter than the macOS sign picker's
# ten-minute Blacksmith stall rule.
LINUX_STALL_MINUTES = 3


def candidates(variable: str) -> list[str]:
    """The variable's label when it is a Blacksmith macOS 26 label, then 6 vCPU, then 12 vCPU."""
    first = [variable] if BLACKSMITH_MACOS.fullmatch(variable or "") else []
    return list(dict.fromkeys([*first, cascade.SMALL, cascade.LARGE]))


def linux_candidates(variable: str) -> list[str]:
    """The configured Blacksmith Linux size, then the other declared sizes."""
    first = [variable] if variable in LINUX_LABELS else []
    return list(dict.fromkeys([*first, *LINUX_LABELS]))


def linux_stalled(snapshot: Mapping[str, Any] | None, labels: list[str], now: dt.datetime) -> set[str] | None:
    """Return Linux labels whose queue has stalled, or None without a fresh snapshot."""
    fresh = cascade._fresh(snapshot, now)  # noqa: SLF001 - use the shared snapshot age rule
    if fresh is None:
        return None
    age, pools = fresh
    # macos-pool-load is currently produced from the macOS queue janitor and
    # therefore may contain no Linux labels at all.  Treat an incomplete Linux
    # view as unverified instead of claiming an absent label is moving; the
    # caller then rotates to its alternate on a stalled retry.
    if not all(label in pools for label in labels):
        return None
    # `oldest_queued_minutes` is measured when the snapshot was generated.  A
    # queued job therefore keeps aging while the picker is reading the
    # snapshot; ignoring that age can keep selecting a label that has already
    # exceeded the three-minute overflow threshold.
    age = max(0.0, age)
    out: set[str] = set()
    for label in labels:
        entry = (pools or {}).get(label) or {}
        try:
            queued = float(entry.get("queued") or 0)
            oldest = float(entry.get("oldest_queued_minutes") or 0)
        except (TypeError, ValueError):
            continue
        if queued and oldest + age >= LINUX_STALL_MINUTES:
            out.add(label)
    return out


def linux_place(variable: str, snapshot: Mapping[str, Any] | None, now: dt.datetime,
                attempt: int) -> tuple[str, str, str, bool]:
    """Pick a moving Blacksmith Linux size for release-pool signer jobs."""
    labels = linux_candidates(variable)
    stalled = linux_stalled(snapshot, labels, now)
    if stalled is None:
        index = (attempt - 1) % len(labels)
        label = labels[index]
        other = labels[(index + 1) % len(labels)]
        return label, other, f"placement unverified: no fresh Linux pool snapshot, so `{label}`", False
    moving = [label for label in labels if label not in stalled] or labels
    label = moving[min(attempt - 1, len(moving) - 1)]
    others = [candidate for candidate in moving if candidate != label]
    other = others[0] if others else label
    return label, other, f"Blacksmith Linux picker chose `{label}`" + (f"; stalled {', '.join(sorted(stalled))}" if stalled else ""), True


def runner_pools(raw: str | None) -> Mapping[str, Any]:
    """The RUNNER_POOLS value, or {} when it is unset or not a JSON object."""
    try:
        value = json.loads(raw or "")
    except ValueError:
        return {}
    return value if isinstance(value, dict) else {}


def marked_dead(pools: Mapping[str, Any] | None, now: dt.datetime) -> set[str]:
    """The Blacksmith macOS 26 labels RUNNER_POOLS' `_dead` marks saw dead within MARK_TTL of `now`."""
    marks = (pools or {}).get(DEAD_KEY)
    if not isinstance(marks, Mapping):
        return set()
    out = set()
    for label, since in marks.items():
        try:
            seen = dt.datetime.fromisoformat(str(since).replace("Z", "+00:00"))
        except ValueError:
            continue
        if label in LABELS and seen.tzinfo is not None and dt.timedelta(minutes=-5) <= now - seen < MARK_TTL:
            out.add(label)
    return out


def every_dead(snapshot: Mapping[str, Any] | None, now: dt.datetime,
               pools: Mapping[str, Any] | None = None) -> set[str]:
    """Every Blacksmith macOS 26 label the snapshot (fresh or not; simple_pool_picker.blacksmith_dead()) or a
    RUNNER_POOLS mark shows dead, all of them included."""
    shown = {label for label in LABELS if cascade._picker_rule.blacksmith_dead(snapshot, label, now)}  # noqa: SLF001
    return shown | marked_dead(pools, now)


def dead(snapshot: Mapping[str, Any] | None, now: dt.datetime, pools: Mapping[str, Any] | None = None) -> set[str]:
    """The labels every_dead() names, or none when it names every one: with no label showing life it says nothing
    to choose by, and the caller's own order holds (live_member() leads it then). Never a source for `alternate`,
    which reads every_dead()."""
    out = every_dead(snapshot, now, pools)
    return set() if out >= set(LABELS) else out


def live_member(snapshot: Mapping[str, Any] | None, now: dt.datetime, pools: Mapping[str, Any] | None) -> str:
    """With every label dead, RUNNER_POOLS' live macos_26 member (runner_pools.py keeps the pool's first member
    when every member is marked), else ""."""
    member = (pools or {}).get(POOL)
    if member in LABELS and every_dead(snapshot, now, pools) >= set(LABELS):
        return str(member)
    return ""


def stalled(snapshot: Mapping[str, Any] | None, labels: list[str], now: dt.datetime,
            pools: Mapping[str, Any] | None = None) -> set[str] | None:
    """The labels a fresh snapshot saw a job wait on for STALL_MINUTES or more, or shows dead (dead()); None
    without one. The stall rule alone calls a busy label and a dead one stalled alike: on 2026-10-30
    blacksmith-12vcpu-macos-26 had started nothing for about a day while 6 vCPU, stalled by that rule too,
    ran 5 jobs."""
    fresh = cascade._fresh(snapshot, now)  # noqa: SLF001 - the cascade's own freshness rule
    if fresh is None:
        return None
    age, pools = fresh
    age = max(0.0, age)
    out = dead(snapshot, now, pools) & set(labels)
    for label in labels:
        # The one Blacksmith stall rule (simple_pool_picker.blacksmith_stalled, 10 min).
        if cascade._picker_rule.blacksmith_stalled(cascade._field(pools, label, "queued"),  # noqa: SLF001
                                                   cascade._field(pools, label, "oldest_queued_minutes"), age):  # noqa: SLF001
            out.add(label)
    return out


def pick(variable: str, snapshot: Mapping[str, Any] | None, now: dt.datetime,
         pools: Mapping[str, Any] | None = None) -> tuple[str, str]:
    """(label, why). `pools` is the RUNNER_POOLS value, for its dead marks and live member."""
    member = live_member(snapshot, now, pools)
    if member:
        return member, f"every Blacksmith macOS 26 label shows dead; `{member}`, RUNNER_POOLS' live {POOL} member"
    labels = candidates(variable)
    stuck = stalled(snapshot, labels, now, pools)
    if stuck is None:
        # A snapshot too old for the stall rule still shows a dead label (dead()): never pick it unverified.
        # dev_landing_place.py's overflow (OVERFLOW_LABEL, 12 vCPU) and nightly_build_runner.py read this pick.
        gone = dead(snapshot, now, pools)
        label = next((label for label in labels if label not in gone), labels[0])
        return label, (f"no fresh pool snapshot, so `{label}` "
                       + ("(vars.MACOS_RUNNER_26 or the default)" if label == labels[0]
                          else f"(`{labels[0]}` is dead: nothing running, no job started in an hour)"))
    moving = [label for label in labels if label not in stuck]
    if not moving:
        # A busy label still starts jobs; a dead one starts none.
        gone = dead(snapshot, now, pools)
        label = DEFAULT if DEFAULT not in gone else next((other for other in labels if other not in gone), DEFAULT)
        return label, (f"every Blacksmith macOS label is stalled ({', '.join(sorted(stuck))}); `{label}` "
                       + ("has the most slots" if label == DEFAULT else f"still starts jobs (`{DEFAULT}` is dead)"))
    skipped = [label for label in labels[: labels.index(moving[0])]]
    why = f"`{moving[0]}`" + (f", past stalled {', '.join(f'`{s}`' for s in skipped)}" if skipped else "")
    return moving[0], why


def alternate(variable: str, label: str, snapshot: Mapping[str, Any] | None, now: dt.datetime,
              pools: Mapping[str, Any] | None = None) -> str:
    """The Blacksmith macOS 26 label a re-run takes: the other size, unless the snapshot sees it stalled.

    Never a label a fresh snapshot saw stalled, nor one the snapshot (fresh or not) or a RUNNER_POOLS mark shows
    dead (every_dead(), so also when every label shows dead): then it is `label` itself.
    """
    others = [other for other in candidates(variable) if other != label]
    stuck = (stalled(snapshot, others, now, pools) or set()) | every_dead(snapshot, now, pools)
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
          problem: str = "", pools: Mapping[str, Any] | None = None) -> tuple[str, str, str, bool]:
    """(runner, alternate, why, verified) for the signing jobs.

    A fresh snapshot verifies the pick (pick(), alternate()). Without one, nothing says the variable's
    label is moving, so it is not trusted: attempt 1 takes DEFAULT (the most slots) with the other
    size as `alternate`, and a full re-run (attempt 2 on, which picks again) the next size in turn. A label the
    snapshot or a RUNNER_POOLS mark shows dead is never `alternate`; with every label dead both are RUNNER_POOLS'
    live macos_26 member when it names one.
    """
    rerun_pick = attempt > 1
    if stalled(snapshot, candidates(variable), now, pools) is None:
        sizes = [DEFAULT, *(size for size in (cascade.SMALL, cascade.LARGE) if size != DEFAULT)]
        # A snapshot too old to verify a pick still shows which label is dead: never rotate onto it.
        gone = dead(snapshot, now, pools)
        sizes = [size for size in sizes if size not in gone] or sizes
        member = live_member(snapshot, now, pools)
        label = member or sizes[(attempt - 1) % len(sizes)]
        other = label if rerun_pick else sizes[attempt % len(sizes)]
        if other in every_dead(snapshot, now, pools):
            other = label
        if not problem:
            problem = ("no pool snapshot" if snapshot is None
                       else "the pool snapshot is stale or malformed "
                            f"(generated {str(snapshot.get('generated_at') or 'at an unknown time')[:40]})"
                       if isinstance(snapshot, Mapping) else "the pool snapshot is malformed")
        why = (f"placement unverified: {problem}, so `{label}`"
               + (f" (RUNNER_POOLS' live {POOL} member; every label shows dead)" if member
                  else " (the size with the most slots)" if label == DEFAULT else " (the next size on this re-run)")
               + ", not vars.MACOS_RUNNER_26 unchecked")
        return label, other, why, False
    label, why = pick(variable, snapshot, now, pools)
    # A pick made on attempt 2 or later is already fresh: the jobs reading `alternate` take it.
    return label, label if rerun_pick else alternate(variable, label, snapshot, now, pools), why, True


def main(env: Mapping[str, str] = os.environ, read: Callable[[str, str], Any] | None = None,
         now: dt.datetime | None = None, *, sleep: Callable[[float], None] = time.sleep,
         clock: Callable[[], float] = time.monotonic) -> int:
    now = now or dt.datetime.now(dt.timezone.utc)
    variable = (env.get("CANDIDATE") or "").strip()
    snapshot, problem = None, "no token to read the pool snapshot"
    token, repo = env.get("SNAPSHOT_TOKEN", ""), env.get("GITHUB_REPOSITORY", "")
    # The read token is the routing App's, whose installation budget other jobs share: on
    # run 41335987427 (2026-11-01) every read answered 403 with X-RateLimit-Remaining=0, the
    # pick went blind onto blacksmith-6vcpu-macos-26 and the final DMG verify sat queued there.
    # GITHUB_TOKEN has its own budget, so a failed read is tried with it next.
    fallback = env.get("SNAPSHOT_FALLBACK_TOKEN", "").strip()
    tokens = [token] + ([fallback] if fallback and fallback != token else [])
    if token and repo:
        def live() -> Any:
            current = tokens[0]
            try:
                if read is not None:
                    return read(current, repo)
                import pr_runner_pool  # noqa: PLC0415 - only for the live read

                return pr_runner_pool.GitHub(current, repo).snapshot(now=now)
            except Exception:
                if len(tokens) > 1:
                    tokens.pop(0)
                    print("nightly sign runner: the read token failed; the next read uses SNAPSHOT_FALLBACK_TOKEN")
                raise
        snapshot, problem = read_snapshot(live, "nightly sign runner", sleep=sleep, clock=clock)
    try:
        attempt = max(1, int((env.get("GITHUB_RUN_ATTEMPT") or "1").strip() or "1"))
    except ValueError:
        attempt = 1
    if env.get("PLATFORM", "macos").strip().lower() == "linux":
        label, other, why, verified = linux_place(variable, snapshot, now, attempt)
    else:
        label, other, why, verified = place(variable, snapshot, now, attempt, problem, runner_pools(env.get("RUNNER_POOLS")))
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
