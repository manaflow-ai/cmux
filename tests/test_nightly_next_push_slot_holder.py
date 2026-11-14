#!/usr/bin/env python3
"""The tick counts a nightly-next loop run as holding the push slot only until its nightly-next-one ends.

feat-cmux-next's nightly.yml moves the push serialization from the workflow-level group
(nightly-build-nightly-next-push) to the nightly-next-one job (nightly-next-one-push), so a run's post-feed tail
(published-build, keep-published-dsyms, publish-nightly-next-github, dispatch-published-in) holds nothing. Holding
through it, 5-10 min after the feed, made two landings wait 22.1 and 23.9 min from landing to run created:
holder 43581845419 (feed 10:09:17Z, ended 10:19:08Z) delayed 43584856901; holder 43605506661 (feed 14:57:49Z,
ended 15:02:43Z) delayed 43608103300.

run_holds_group (scripts/ci/nightly_next_feed_watch.py), for the rolling rule (nightly_next_rolling.py):
- nightly-next-one queued, pending or in progress: holds, however long it has waited. A promotion now would only
  get it, the one pending loop run, replaced (2026-11-12: 13 of 17 cancelled; nobody cancels a nightly).
- nightly-next-one finished (success or failure): holds nothing, whatever the tail still runs.
- nightly-next-one skipped (the split jobs build): the run holds as before, through its tail.
- a run with no jobs yet that is pending (on a concurrency group): holds, however long. A queued one with no jobs
  keeps the 10-minute cut-off for a run that never starts.

Manual lane (Lawrence 2026-10-23: no new CI tests): python3 tests/test_nightly_next_push_slot_holder.py.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("nightly_next_rolling", ROOT / "scripts/ci/nightly_next_rolling.py")
rolling = importlib.util.module_from_spec(spec)
sys.modules["nightly_next_rolling"] = rolling
spec.loader.exec_module(rolling)
watch = rolling.watch

# 2026-11-14 15:00:00Z: holder 43605506661's nightly-next-one wrote the feed at 14:57:49Z; its tail ran to 15:02:43Z.
NOW = dt.datetime(2026, 11, 14, 15, 0, tzinfo=dt.timezone.utc)
HEAD = "a" * 40
WAITING = "b" * 40
failures: list[str] = []


def at(minutes_ago: float) -> str:
    return (NOW - dt.timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


def run(run_id: int, minutes_ago: float, status: str = "in_progress", **extra) -> dict:
    return {"id": run_id, "status": status, "conclusion": None, "event": "push", "head_branch": "nightly-next",
            "display_title": "nightly-next build", "head_sha": HEAD, "created_at": at(minutes_ago),
            "run_started_at": at(minutes_ago), "html_url": f"https://github.com/o/r/actions/runs/{run_id}", **extra}


def job(name: str, status: str, minutes_ago: float = 1.0, runner: str = "r", conclusion: str | None = None) -> dict:
    return {"name": name, "status": status, "created_at": at(minutes_ago), "started_at": at(minutes_ago),
            "conclusion": conclusion if conclusion is not None else ("success" if status == "completed" else None),
            "runner_name": runner, "runner_id": 1 if runner else 0, "steps": []}


PRE = [job("runner-preflight", "completed", 30), job("decide", "completed", 29), job("resolve-nightly-cmux-tui-client", "completed", 28)]
TAIL = [job("published-build", "completed", 3), job("keep-published-dsyms", "in_progress", 2, "cmux15"),
        job("publish-nightly-next-github", "in_progress", 2, "GitHub Actions 1"),
        job("dispatch-published-in", "queued", 1, "")]


def holds(jobs: list[dict], minutes_ago: float = 30, **run_extra) -> bool:
    return watch.run_holds_group(run(43605506661, minutes_ago, **run_extra), jobs, NOW)


def check(name: str, got: bool, want: bool) -> None:
    if got != want:
        failures.append(f"{name}: run_holds_group gave {got}, want {want}")


# The evidence shape: the feed is written, nightly-next-one succeeded, the tail runs. The slot is free.
check("nightly-next-one done, tail running (43605506661 at 15:00Z)",
      holds([*PRE, job("nightly-next-one", "completed", 27), *TAIL]), False)
check("nightly-next-one failed, the tail's retry job runs",
      holds([*PRE, job("nightly-next-one", "completed", 27, conclusion="failure"), job("retry-nightly-next", "in_progress", 1)]),
      False)
# Building, or waiting for the slot or the signer: it holds, however long it waited.
check("nightly-next-one building", holds([*PRE, job("nightly-next-one", "in_progress", 20)]), True)
check("nightly-next-one queued 40 min on the slot, no runner",
      holds([*PRE, job("nightly-next-one", "queued", 40, "")], 45), True)
check("nightly-next-one pending on the slot", holds([*PRE, job("nightly-next-one", "pending", 40, "")], 45), True)
# The split jobs (the one job off, or decide chose them): the run holds through its tail, as before.
check("nightly-next-one skipped, the split publish's tail runs",
      holds([*PRE, job("nightly-next-one", "completed", 27, conclusion="skipped"), job("publish-nightly", "completed", 5),
             job("generate-nightly-deltas (arm64)", "in_progress", 4, "mac")]), True)
# Before the slot: decide and resolve still run (nightly-next-one not created yet): it holds.
check("decide running", holds([job("runner-preflight", "completed", 3), job("decide", "in_progress", 2)], 3), True)
# A run pending on a concurrency group has no jobs: it holds however long it waits (a promotion replaces it).
check("pending on a group 25 min with no jobs", holds([], 25, status="pending"), True)
# A queued run with no jobs that never starts keeps the cut-off.
check("queued 25 min with no jobs", holds([], 25, status="queued"), False)
check("queued 3 min with no jobs", holds([], 3, status="queued"), True)

# The rolling rule end to end: with the holder's nightly-next-one done and a landing waiting, the tick promotes
# at once instead of waiting 5-10 min for the tail (43608103300 waited 23.9 min from landing to run created).
holder = run(43605506661, 30, head_sha=HEAD)
tail_jobs = [*PRE, job("nightly-next-one", "completed", 27), *TAIL]
go, reason = rolling.decide(NOW, head=HEAD, head_runs=[holder], jobs_of=lambda r: tail_jobs, promotions=[],
                            oldest_waiting=(WAITING, NOW - dt.timedelta(minutes=8)), starts=[holder])
if not go:
    failures.append(f"the tick must promote once the holder's nightly-next-one is done: {reason}")
building = [*PRE, job("nightly-next-one", "in_progress", 20)]
go, reason = rolling.decide(NOW, head=HEAD, head_runs=[holder], jobs_of=lambda r: building, promotions=[],
                            oldest_waiting=(WAITING, NOW - dt.timedelta(minutes=8)), starts=[holder])
if go:
    failures.append(f"the tick must wait while the holder's nightly-next-one builds: {reason}")
# One loop run pending at the slot behind a building one: still no promotion, so GitHub never replaces it.
pending = run(43608103300, 6, head_sha=WAITING)
go, reason = rolling.decide(NOW, head=WAITING, head_runs=[pending],
                            jobs_of=lambda r: tail_jobs if r["id"] == 43605506661 else
                            [*PRE, job("nightly-next-one", "pending", 4, "")], promotions=[],
                            oldest_waiting=("c" * 40, NOW - dt.timedelta(minutes=30)), starts=[holder, pending])
if go:
    failures.append(f"a loop run pending at the slot holds the tick, so no promotion replaces it: {reason}")

if failures:
    print("FAIL: the push slot ends at nightly-next-one\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: the push slot ends at nightly-next-one")
