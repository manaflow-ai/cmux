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

- a run in nightly-next-one's own leave step ("Leave the push slot to a newer nightly-next push") holds nothing
  (leaving_slot): it waits there for this promotion and leaves by skipping its build.
- a read that fails never promotes while a nightly-next push run created within RUN_LOOKBACK may wait at the
  slot (or the listing itself fails): GitHub would cancel that pending job. It waits, and says which read failed.

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

# Latest wins at nightly-next-one's slot: a run admitted after a long wait there runs feat-cmux-next's leave step
# again as nightly-next-one's first step ("Leave the push slot to a newer nightly-next push") and waits for a
# promotion. In that step it builds nothing: the tick promotes, the newer push's nightly-next-one queues behind it,
# and it leaves by skipping its build (nothing is cancelled).
LEAVE_ONE = getattr(rolling, "LEAVE_ONE_STEP", "Leave the push slot to a newer nightly-next push")
if LEAVE_ONE != "Leave the push slot to a newer nightly-next push":
    failures.append(f"LEAVE_ONE_STEP must be nightly-next-one's step name on feat-cmux-next, got {LEAVE_ONE!r}")


def one_in(step_status: str, later: str = "") -> list[dict]:
    one = job("nightly-next-one", "in_progress", 1, "cmux15")
    one["steps"] = [{"name": "Hold the whole Mac before any credential", "status": "completed", "conclusion": "success"},
                    {"name": "Claim the whole Mac for signing", "status": "completed", "conclusion": "success"},
                    {"name": LEAVE_ONE, "status": step_status, "conclusion": None}]
    if later:
        one["steps"].append({"name": "Point the signing steps at the build products", "status": later})
    return [*PRE, one]


stale = run(43608103300, 35, head_sha=HEAD)
for name, jobs, want_go in (("in nightly-next-one's leave step", one_in("in_progress"), True),
                            ("past nightly-next-one's leave step, building", one_in("completed", "in_progress"), False)):
    if rolling.leaving_slot(jobs) != want_go:
        failures.append(f"leaving_slot for a run {name} must be {want_go}")
    go, reason = rolling.decide(NOW, head=HEAD, head_runs=[stale], jobs_of=lambda r, j=jobs: j, promotions=[],
                                oldest_waiting=(WAITING, NOW - dt.timedelta(minutes=20)), starts=[stale])
    if go != want_go:
        failures.append(f"a run {name}: the tick must {'promote' if want_go else 'wait'}: {reason}")


# A read that fails never promotes past a run that may be waiting at the slot: GitHub would replace (cancel) that
# pending job. Under an exhausted REST budget the jobs read fails while a run waits there.
class Api:
    def __init__(self, routes: dict):
        self.routes = routes

    def __call__(self, path: str):
        for prefix, value in self.routes.items():
            if prefix in path:
                if isinstance(value, Exception):
                    raise value
                return value
        raise AssertionError(f"unexpected read {path}")


def api(runs=None, **broken) -> Api:
    routes = {"/git/ref/heads/nightly-next": {"object": {"sha": HEAD}},
              "/compare/": {"status": "ahead", "commits": [{"sha": WAITING, "commit": {"committer": {"date": at(30)}}}]},
              "branch=nightly-next": runs if isinstance(runs, Exception) else {"workflow_runs": runs or []},
              "event=workflow_dispatch": {"workflow_runs": []},
              "/jobs?": {"jobs": [*PRE, job("nightly-next-one", "pending", 25, "")]}}
    for key, error in broken.items():
        routes[{"jobs": "/jobs?", "runs": "branch=nightly-next", "promotions": "event=workflow_dispatch"}[key]] = error
    return Api(routes)


QUOTA = OSError("HTTP 403: API rate limit exceeded")
cases = [
    ("the run listing fails (a waiting run can't be ruled out)", api(runs=QUOTA), False),
    ("the jobs read fails with a run 30 min old not completed", api([run(1, 30, head_sha=HEAD)], jobs=QUOTA), False),
    ("the jobs read fails with a run whose creation is unreadable",
     api([run(2, 30, head_sha=HEAD, created_at="not a time")], jobs=QUOTA), False),
    ("the promotion read fails with a run 2 h old still in progress",
     api([run(3, 120, head_sha="c" * 40)], promotions=QUOTA), False),
    ("the promotion read fails and every recent run is completed",
     api([run(4, 30, "completed", head_sha=HEAD)], promotions=QUOTA), True),
    ("the promotion read fails and the only open run is older than RUN_LOOKBACK",
     api([run(5, 200, head_sha=HEAD)], promotions=QUOTA), True),
]
for name, reader, want_go in cases:
    go, reason = rolling.evaluate(NOW, "o/r", "f" * 40, api=reader)
    if go != want_go:
        failures.append(f"{name}: the tick must {'promote' if want_go else 'wait'}, got {go}: {reason}")
    elif not go and "could not read" not in reason:
        failures.append(f"{name}: the wait must say which read failed and why it waits: {reason}")

# The next run's set-up overlaps the holder's notarization (feat-cmux-next's nightly-next-one asks this tick when it
# reaches "Ask main's nightly-next tick at notarization", just before "Notarize app ticket through final DMG").
# Push runs 43634178843, 43642011551 and 43644053566 waited 19.6-26.8 min from landing to run created behind the
# previous nightly-next-one, then 4.7 min more for wake, tick, promote, preflight, decide and resolve (21:38:45 to
# 21:43:25). From that step on, the holder is finishing: the tick may promote ONE run, whose nightly-next-one then
# waits pending on nightly-next-one-push until the slot frees. Never a second: with any other loop run open (its
# nightly-next-one pending, or still in decide or resolve), GitHub would replace the pending job (a cancelled
# nightly), so a finishing holder holds again.
FINISH = list(getattr(rolling, "FINISH_STEPS", ()))
for want in ("Ask main's nightly-next tick at notarization", "Notarize app ticket through final DMG"):
    if want not in FINISH:
        failures.append(f"FINISH_STEPS must name nightly-next-one's step {want!r} (feat-cmux-next's names)")


def one_at(steps: list[tuple[str, str, str | None]], status: str = "in_progress") -> list[dict]:
    one = job("nightly-next-one", status, 20, "cmux15")
    one["steps"] = [{"name": LEAVE_ONE, "status": "completed", "conclusion": "success"},
                    {"name": "Start the signed-app checks (they run during notarization)", "status": "completed",
                     "conclusion": "success"}]
    one["steps"] += [{"name": n, "status": s, "conclusion": c} for n, s, c in steps]
    return [*PRE, one]


ASK, NOTARIZE = "Ask main's nightly-next tick at notarization", "Notarize app ticket through final DMG"
signing = one_at([(ASK, "queued", None), (NOTARIZE, "queued", None)])
asking = one_at([(ASK, "in_progress", None), (NOTARIZE, "queued", None)])
notarizing = one_at([(ASK, "completed", "success"), (NOTARIZE, "in_progress", None)])
publishing = one_at([(ASK, "completed", "success"), (NOTARIZE, "completed", "success"),
                     ("Final publication gate", "in_progress", None)])
uploading = one_at([(ASK, "completed", "success"), (NOTARIZE, "completed", "success"),
                    ("Upload nightly variant artifacts", "in_progress", None)])
left = one_at([(ASK, "completed", "skipped"), (NOTARIZE, "completed", "skipped")])
finishing = getattr(rolling, "finishing", lambda jobs: False)
for name, jobs, want in (("signing, before the ask", signing, False), ("in the ask step", asking, True),
                         ("notarizing", notarizing, True), ("publishing", publishing, True),
                         ("in the post-feed uploads", uploading, True), ("left the slot (steps skipped)", left, False)):
    if finishing(jobs) != want:
        failures.append(f"finishing() for a nightly-next-one {name} must be {want}")
holder = run(43634178843, 25, head_sha=HEAD)
for name, jobs, want_go in (("signing, before notarization", signing, False), ("notarizing", notarizing, True),
                            ("publishing", publishing, True)):
    go, reason = rolling.decide(NOW, head=HEAD, head_runs=[holder], jobs_of=lambda r, j=jobs: j, promotions=[],
                                oldest_waiting=(WAITING, NOW - dt.timedelta(minutes=5)), starts=[holder])
    if go != want_go:
        failures.append(f"the holder's nightly-next-one {name}, nothing else open: the tick must "
                        f"{'promote one run' if want_go else 'wait'}: {reason}")
# One run promoted past the finishing holder: whatever it does, nothing more is promoted (GitHub would replace
# its pending nightly-next-one, or the one it is about to queue).
for name, next_jobs, next_status in (
        ("pending at the slot", [*PRE, job("nightly-next-one", "pending", 4, "")], "in_progress"),
        ("in decide", [job("runner-preflight", "completed", 2), job("decide", "in_progress", 1)], "in_progress"),
        ("pending with no jobs yet", [], "pending"),
        ("waiting in resolve's leave step",
         [job("runner-preflight", "completed", 9), job("decide", "completed", 8),
          {**job("resolve-nightly-cmux-tui-client", "in_progress", 7),
           "steps": [{"name": rolling.LEAVE_SLOT_STEP, "status": "in_progress"}]}], "in_progress")):
    nxt = run(43642011551, 6, next_status, head_sha=WAITING)
    go, reason = rolling.decide(NOW, head=WAITING, head_runs=[nxt],
                                jobs_of=lambda r, n=next_jobs: notarizing if r["id"] == holder["id"] else n,
                                promotions=[], oldest_waiting=("c" * 40, NOW - dt.timedelta(minutes=3)),
                                starts=[nxt, holder])
    if go:
        failures.append(f"a finishing holder with one promoted run {name}: no second promotion: {reason}")
# Review of 4cf338e7c740: holder H (commit W) reaches the ask, the tick promotes X, push run R0(X) fails in resolve,
# and retry-nightly-next dispatches "Retry nightly-next (1 of 2)" of X, whose nightly-next-one waits pending behind
# H. Then Y becomes buildable. The retry_of filter drops that retry (a retry of the head while a commit waits), but it
# is still an open loop run at the slot: promoting Y would get GitHub to replace its pending job. No promotion.
X = "d" * 40
h_w = run(43634178843, 25, head_sha=HEAD)
retry_x = run(43650000001, 3, event="workflow_dispatch", display_title="Retry nightly-next (1 of 2)", head_sha=X)
r0_x = run(43649000000, 9, "completed", head_sha=X)
retry_jobs = [*PRE, job("nightly-next-one", "pending", 1, "")]
go, reason = rolling.decide(NOW, head=X, head_runs=[retry_x, r0_x],
                            jobs_of=lambda r: notarizing if r["id"] == h_w["id"] else retry_jobs, promotions=[],
                            oldest_waiting=("e" * 40, NOW - dt.timedelta(minutes=2)), starts=[retry_x, r0_x, h_w])
if go:
    failures.append(f"a retry of the head pending at the slot behind a finishing holder: no promotion: {reason}")
# Run-list lag: nightly-next already moved past the holder's commit (a promotion went through), but the new push run
# is not listed yet. The holder is no longer the head's run, so it is not finishing for this rule: it holds.
lagged = run(43634178843, 25, head_sha=HEAD)
go, reason = rolling.decide(NOW, head=WAITING, head_runs=[], jobs_of=lambda r: notarizing, promotions=[],
                            oldest_waiting=("e" * 40, NOW - dt.timedelta(minutes=2)), starts=[lagged])
if go:
    failures.append(f"nightly-next moved past the finishing holder, its new run not listed yet: no promotion: {reason}")

# The feed watch's starvation guard keeps counting a finishing holder (run_holds_group is unchanged): its dispatch
# for one commit skips the rolling rule, so only the rule above may promote past a holder.
if not watch.run_holds_group(holder, notarizing, NOW):
    failures.append("run_holds_group must still count a notarizing nightly-next-one (the feed watch reads it)")

if failures:
    print("FAIL: the push slot ends at nightly-next-one\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: the push slot ends at nightly-next-one")
