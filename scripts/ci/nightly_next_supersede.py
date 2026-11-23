#!/usr/bin/env python3
"""Latest wins for nightly-next: drop an older nightly run that holds a concurrency group the tip waits on.

nightly.yml keeps nightly-next pushes (and the loop's retries) in nightly-build-nightly-next-push and the sign
stages in nightly-build-nightly-next-sign, never cancelling a started run. GitHub keeps one newer run pending
per group and replaces it with each newer push. So an older run whose remaining jobs wait on a runner label
that stopped serving holds the group for hours, and every tip run behind it is replaced while pending and
never starts (2026-11-10/11: push runs 42925854615 and 42929616529 and sign run 42930383771 held them; tip
runs 42945365476, 42947517129 and 42948266530 were each replaced with no jobs). Leo, 2026-11-11: "aren't
there things we can just be like 'ok just get this one in asap'", and 2026-11-06: nothing queues.

The rule. A run is dropped when main's delivery_workflows.superseded_unstarted() says it is stale (the stale
rule the queue janitor and the agents' cancel guard read), or when all of these hold (holder_superseded()):
  1. it holds a shared group (group_of()) and every job of its current attempt but the light control and
     decide ones (LIGHT_JOBS) is queued with no runner, or skipped (build_started() is None);
  2. it is not the tip's push run (a sign stage's head is the tip when its push run dispatched it, not the
     build it signs, so the sign group is judged by 3 alone);
  3. the newest run GitHub keeps pending in its group waits on it with no jobs: the tip's push run or loop
     retry for the push group, the sign stage of a later push run for the sign group (group_waiter());
  4. nothing in it has moved for READY_WAIT (5 min), over the stuck-job read's 3 min, so a job about to get
     a runner gets it first.
LIGHT_JOBS, build_started(), attempt_jobs() and waited_since() come from main's delivery_workflows.py, read at
run time (--rules), so the light-job list and the started rule have one definition. A run with any build,
sign or publish job started is never cancelled, nor is the tip's push run or the newest sign stage.

Before each cancel the open pull requests at its head, the tip, the waiting runs and the run are read again,
and its jobs last of all; anything unread keeps the run. At most MAX_CANCELS a run, never a force-cancel.
With --settle, a holder that only lacks its READY_WAIT, or a tip whose run is not listed yet, is judged once
more after that wait (at most SETTLE_MAX), so the push that starts this workflow clears its own holder.

A holder can go stale after that settle: its decide finishes a few minutes after the push, then its build jobs
queue on a dead label, and only then does its 5-minute READY_WAIT start. This workflow starts only on a
promotion push or by dispatch (a schedule runs only on the default branch's files, and this file is not on main),
so such a holder used to wait for the next promotion. Now, with --chain N, a pass that still keeps a holder only
for its READY_WAIT dispatches this workflow again on nightly-next (chain N+1, at most CHAIN_MAX): the next run waits
on this one's concurrency group, then settles and judges again. The chain stops as soon as no holder lacks only
time (it was dropped, it started building, or the waiter went), so it costs nothing while nothing is stuck.

    nightly_next_supersede.py OWNER/REPO --rules PATH/delivery_workflows.py [--settle] [--chain N] [--dry-run]
Needs gh with GH_TOKEN (actions: write). Exit 0 once the arguments read: its findings are annotations.
"""
from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import json
import os
import re
import subprocess
import sys
import time
from collections.abc import Callable, Iterable, Mapping, Sequence
from pathlib import Path
from types import ModuleType
from typing import Any

WORKFLOW, BRANCH = "nightly.yml", "nightly-next"
STATUSES = ("pending", "queued", "in_progress")
HOLDER_STATUSES = frozenset({"queued", "in_progress"})
WAITER_STATUSES = frozenset({"pending"})  # what GitHub shows for a run waiting on its group
PAGE, MAX_PAGES = 100, 3
MAX_CANCELS = 2  # one push holder and one sign holder
READY_WAIT = dt.timedelta(minutes=5)
SETTLE_MAX = dt.timedelta(minutes=6)
SETTLE_NO_WAITER = dt.timedelta(seconds=45)  # the push's nightly run may not be listed yet
CHAIN_MAX = 12  # re-dispatches after one push: about 12 x (queue + SETTLE_MAX), over an hour of a holder going stale
SELF = "nightly-next-supersede.yml"
SHA = re.compile(r"[0-9a-f]{40}")
# nightly.yml's run-name for the dispatches its group expression puts in the push and sign groups.
RETRY_TITLE = re.compile(r"^Retry nightly-next \([12] of 2\)$")
SIGN_TITLE = re.compile(r"^Sign nightly-next run ([0-9]+) attempt [0-9]+$")


class Unreadable(Exception):
    """A read or write that failed, or an answer not of the shape read here. Nothing is cancelled on it."""


# ---- the rule


def load_rules(path: str | os.PathLike[str]) -> ModuleType:
    """main's scripts/ci/delivery_workflows.py, which must define what the rule reads."""
    spec = importlib.util.spec_from_file_location("delivery_workflows", path)
    if spec is None or spec.loader is None:
        raise Unreadable(f"{path}: not a Python module")
    module = importlib.util.module_from_spec(spec)
    sys.modules["delivery_workflows"] = module
    spec.loader.exec_module(module)
    for name in ("superseded_unstarted", "attempt_jobs", "build_started", "waited_since", "LIGHT_JOBS"):
        if not hasattr(module, name):
            raise Unreadable(f"{path} has no {name}")
    return module


def _file_name(path: Any) -> str:
    return Path(str(path or "").split("@", 1)[0]).name.lower()


def _time(value: Any) -> dt.datetime | None:
    try:
        return dt.datetime.fromisoformat(str(value).replace("Z", "+00:00")) if value else None
    except ValueError:
        return None


def _repo(run: Mapping[str, Any]) -> str:
    return str(((run.get("head_repository") or {}).get("full_name")) or "").lower()


def group_of(run: Mapping[str, Any]) -> str | None:
    """"push" or "sign" for a run in a shared group of the nightly.yml on nightly-next, else None.

    Only nightly.yml runs whose head_branch is nightly-next count: they run that branch's nightly.yml, whose
    group expression keys these groups. main's nightly.yml keys main's push runs by run id, and nightly-sign.yml
    keys per source run, so neither is ever a holder or a waiter (live titles: 42952791964 "Sign nightly-next
    run 42950072283 attempt 1", 42941668554 "Retry nightly-next (1 of 2)")."""
    if _file_name(run.get("path")) != WORKFLOW or run.get("head_branch") != BRANCH:
        return None
    titles = [str(run.get(key) or "") for key in ("display_title", "name")]
    if run.get("event") == "push":
        return "push"
    if run.get("event") == "workflow_dispatch":
        if any(RETRY_TITLE.match(title) for title in titles):
            return "push"
        if any(SIGN_TITLE.match(title) for title in titles):
            return "sign"
    return None


def sign_source(run: Mapping[str, Any]) -> int | None:
    """The push run a sign stage signs (from its run name), or None."""
    for key in ("display_title", "name"):
        match = SIGN_TITLE.match(str(run.get(key) or ""))
        if match:
            return int(match.group(1))
    return None


JobsOf = Callable[[Mapping[str, Any]], "Sequence[Mapping[str, Any]] | None"]


def group_waiter(run: Mapping[str, Any], runs: Iterable[Mapping[str, Any]], jobs_of: JobsOf, tip: str,
                 ) -> tuple[Mapping[str, Any] | None, str]:
    """(the newer run waiting on `run`'s group, why), or (None, why not). The waiter is the newest run pending in
    the same group and head repository, on attempt 1, created after `run`, with no jobs (one read): at the tip
    for the push group, signing a later push run for the sign group."""
    group = group_of(run)
    if group is None:
        return None, "it holds no shared nightly-next group"
    created, repo = _time(run.get("created_at")), _repo(run)
    if created is None or not repo:
        return None, "its creation or head repository could not be read"
    mine = sign_source(run) if group == "sign" else None
    if group == "sign" and mine is None:
        return None, "the push run its sign stage signs could not be read"
    waiting = []
    for other in runs:
        if (other.get("id") == run.get("id") or group_of(other) != group or _repo(other) != repo
                or other.get("status") not in WAITER_STATUSES or other.get("run_attempt") != 1):
            continue
        when = _time(other.get("created_at"))
        if when is None or when <= created:
            continue
        if group == "push" and str(other.get("head_sha") or "").lower() != tip:
            continue
        if group == "sign" and (sign_source(other) or 0) <= (mine or 0):
            continue
        waiting.append((when, other))
    if not waiting:
        return None, f"no newer run {'at the tip ' + tip[:12] + ' ' if group == 'push' else ''}waits on its {group} group"
    other = max(waiting, key=lambda pair: pair[0])[1]  # GitHub keeps one pending run per group
    theirs = jobs_of(other)
    if theirs is None:
        return None, f"the jobs of run {other.get('id')}, waiting in its {group} group, could not be read"
    if theirs:
        return None, f"run {other.get('id')} lists jobs, so it is not waiting on the group"
    return other, f"run {other.get('id')} ({str(other.get('head_sha'))[:12]}) waits on its {group} group"


def holder_superseded(rules: ModuleType, run: Mapping[str, Any], jobs: Sequence[Mapping[str, Any]] | None,
                      runs: Sequence[Mapping[str, Any]], jobs_of: JobsOf, *, tip: str, now: dt.datetime,
                      ready_wait: dt.timedelta = READY_WAIT) -> tuple[bool, str, dt.timedelta | None]:
    """(drop, why, still to wait): main's stale rule, else conditions 1-4 above. `still to wait` is set when
    only condition 4 failed: how long until it holds."""
    tip = str(tip or "").lower()
    if not SHA.fullmatch(tip):
        return False, "the tip of nightly-next could not be read", None
    try:
        ok, why = rules.superseded_unstarted(run, jobs, runs, jobs_of, now=now, tip_sha=tip)
    except Exception as error:  # a broken rule keeps the run
        return False, f"superseded_unstarted() failed ({type(error).__name__}: {error})", None
    if ok:
        return True, why, None
    group = group_of(run)
    if group is None:
        return False, why, None
    if run.get("status") not in HOLDER_STATUSES:
        return False, f"it is {run.get('status') or 'in an unknown state'}", None
    mine = rules.attempt_jobs(run, jobs) if jobs is not None else None
    if mine is None:
        return False, "its jobs, or which attempt they belong to, could not be read", None
    started = rules.build_started(mine)
    if started:
        return False, f"condition 1 fails, it has started: {started}", None
    if group == "push" and str(run.get("head_sha") or "").lower() == tip:
        return False, "it is the tip's push run, and the newest tip must build", None
    since = rules.waited_since(run, mine)
    if since is None:
        return False, "how long it has waited could not be read", None
    waiter, about = group_waiter(run, runs, jobs_of, tip)
    if waiter is None:
        return False, f"{about} ({why})", None
    waited = now - since
    if waited < ready_wait:
        return False, (f"{about}, but it has waited {int(waited.total_seconds() // 60)} min since it last moved, "
                       f"under {int(ready_wait.total_seconds() // 60)}"), ready_wait - waited
    pending = sum(1 for job in mine if job.get("status") in rules.WAITING_JOB_STATUSES)
    return True, (f"it holds its {group} group with every job but the light ones queued or skipped ({pending} "
                  f"waiting), it has waited {int(waited.total_seconds() // 60)} min since it last moved, and "
                  f"{about}"), None


# ---- GitHub, through gh


Gh = Callable[[Sequence[str], bool], str]


def gh_cli(args: Sequence[str], write: bool) -> str:
    """Run gh. A write goes out once (no gh_budget_wait.sh retries). A missing gh is unread, not a traceback."""
    env = dict(os.environ)
    if write:
        env["GH_BUDGET_WAIT_ATTEMPTS"] = "1"
    try:
        result = subprocess.run(["gh", *args], capture_output=True, text=True, env=env, stdin=subprocess.DEVNULL)
    except OSError as error:
        raise Unreadable(f"gh could not run: {error}") from error
    if result.returncode:
        raise Unreadable(f"gh {' '.join(args[:4])} failed: {result.stderr.strip()[:200]}")
    return result.stdout


def ls_remote_sha(repo: str, branch: str) -> str:
    """A branch's tip from git's ref advertisement: no token and none of the API budget."""
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/")
    try:
        out = subprocess.run(["git", "ls-remote", "--exit-code", f"{server}/{repo}", f"refs/heads/{branch}"],
                             capture_output=True, text=True, timeout=60, check=True, stdin=subprocess.DEVNULL,
                             env={**os.environ, "GIT_TERMINAL_PROMPT": "0"}).stdout
    except (OSError, subprocess.SubprocessError) as error:
        raise Unreadable(f"git ls-remote {branch} failed: {error}") from error
    sha = out.split()[0].lower() if out.split() else ""
    if not SHA.fullmatch(sha):
        raise Unreadable(f"{branch} is {sha!r}")
    return sha


class Api:
    def __init__(self, repo: str, gh: Gh = gh_cli, tip: Callable[[str, str], str] = ls_remote_sha):
        self.repo, self.gh, self._tip = repo, gh, tip

    def get(self, path: str) -> Any:
        text = self.gh(["api", f"repos/{self.repo}/{path}"], False)
        try:
            return json.loads(text)
        except json.JSONDecodeError as error:
            raise Unreadable(f"{path}: not JSON") from error

    def listing(self, path: str, key: str) -> list[dict[str, Any]]:
        """Every item of a paginated listing; the items must add up to total_count, none twice."""
        items: list[dict[str, Any]] = []
        total = None
        for page in range(1, MAX_PAGES + 1):
            body = self.get(f"{path}{'&' if '?' in path else '?'}per_page={PAGE}&page={page}")
            if not isinstance(body, dict) or not isinstance(body.get(key), list) or not isinstance(
                    body.get("total_count"), int):
                raise Unreadable(f"{path}: not a listing of {key}")
            if total is not None and body["total_count"] != total:
                raise Unreadable(f"{path}: total_count moved between pages")
            total = body["total_count"]
            items.extend(item for item in body[key] if isinstance(item, dict))
            if len(items) >= total or not body[key]:
                break
        ids = [item.get("id") for item in items]
        if total is None or len(items) != total or len(ids) != len(set(map(repr, ids))):
            raise Unreadable(f"{path}: {len(items)} items for a total_count of {total}")
        return items

    def tip(self) -> str:
        return self._tip(self.repo, BRANCH)

    def runs(self) -> list[dict[str, Any]]:
        """nightly.yml's unfinished runs on nightly-next: holders and the runs pending on their groups."""
        found: dict[Any, dict[str, Any]] = {}
        for status in STATUSES:
            for run in self.listing(f"actions/workflows/{WORKFLOW}/runs?branch={BRANCH}&status={status}",
                                    "workflow_runs"):
                found[run.get("id")] = run
        return list(found.values())

    def run(self, run_id: int) -> dict[str, Any]:
        body = self.get(f"actions/runs/{run_id}")
        if not isinstance(body, dict) or body.get("id") != run_id:
            raise Unreadable(f"run {run_id}: not a run")
        return body

    def jobs(self, run_id: int) -> list[dict[str, Any]]:
        return self.listing(f"actions/runs/{run_id}/jobs?filter=latest", "jobs")

    def open_prs_at(self, sha: str) -> list[int]:
        body = self.get(f"commits/{sha}/pulls")
        if not isinstance(body, list):
            raise Unreadable(f"pull requests at {sha[:12]}: not a list")
        return [pr.get("number") for pr in body if isinstance(pr, dict) and pr.get("state") == "open"
                and str((pr.get("head") or {}).get("sha") or "").lower() == sha.lower()]

    def cancel(self, run_id: int) -> None:
        self.gh(["api", "-X", "POST", f"repos/{self.repo}/actions/runs/{run_id}/cancel"], True)

    def rearm(self, chain: int) -> None:
        """Dispatch this workflow again on nightly-next, as link CHAIN of the chain."""
        self.gh(["workflow", "run", SELF, "-R", self.repo, "--ref", BRANCH, "-f", f"chain={chain}"], True)


# ---- one pass


Clock = Callable[[], dt.datetime]


def _utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def judge(rules: ModuleType, api: Api, run: Mapping[str, Any], runs: Sequence[Mapping[str, Any]], tip: str,
          now: dt.datetime) -> tuple[bool, str, dt.timedelta | None]:
    cache: dict[Any, list[dict[str, Any]] | None] = {}

    def jobs_of(other: Mapping[str, Any]) -> list[dict[str, Any]] | None:
        key = other.get("id")
        if key not in cache:
            try:
                cache[key] = api.jobs(int(key))
            except (Unreadable, TypeError, ValueError):
                cache[key] = None
        return cache[key]
    return holder_superseded(rules, run, jobs_of(run), runs, jobs_of, tip=tip, now=now)


def sweep(rules: ModuleType, api: Api, *, dry_run: bool, log: Callable[[str], None], clock: Clock,
          done: list[int], waits: list[dt.timedelta] | None = None) -> dt.timedelta | None:
    """Cancel each droppable holder; return how long a kept holder still has to wait (None when none would
    become droppable by waiting). WAITS gets each kept holder's own READY_WAIT remainder (not the brief wait for a
    tip run not listed yet): what a re-dispatch would wait out."""
    def warn(message: str) -> None:
        log(f"::warning title=nightly-next supersede::{message}")

    try:
        tip, runs = api.tip(), api.runs()
    except Unreadable as why:
        warn(f"the nightly-next runs could not be read ({why}); nothing cancelled")
        return None
    holders = sorted((run for run in runs if run.get("status") in HOLDER_STATUSES and group_of(run)
                      and run.get("id") not in done),
                     key=lambda run: (str(run.get("created_at") or ""), run.get("id") or 0))
    if not holders:
        log("nightly-next supersede: no run holds the push or sign group")
        return None
    later: dt.timedelta | None = None
    tip_listed = any(group_of(run) == "push" and str(run.get("head_sha") or "").lower() == tip for run in runs)
    for listed in holders:
        run_id = int(listed["id"])
        ok, why, wait = judge(rules, api, listed, runs, tip, clock())
        if not ok:
            log(f"nightly-next run {run_id} ({group_of(listed)} group, {str(listed.get('head_sha'))[:12]}): kept, {why}")
            if wait is not None:
                later = wait if later is None else min(later, wait)
                if waits is not None:
                    waits.append(wait)
            elif not tip_listed and group_of(listed) == "push":
                later = SETTLE_NO_WAITER if later is None else min(later, SETTLE_NO_WAITER)
            continue
        if len(done) >= MAX_CANCELS:
            log(f"nightly-next run {run_id}: would be dropped ({why}), but {MAX_CANCELS} were this run")
            continue
        # Everything once more, the run's own jobs last, right before the cancel: a build that started, a tip
        # that moved, a waiter that went, or a pull request opened at its head keeps the run.
        try:
            prs = api.open_prs_at(str(listed.get("head_sha") or ""))
            fresh_tip, fresh_runs = api.tip(), api.runs()
            current = api.run(run_id)
            ok, why, _ = judge(rules, api, current, fresh_runs, fresh_tip, clock())
            last = api.jobs(run_id) if ok else None
        except Unreadable as error:
            warn(f"run {run_id}: the re-read failed ({error}); kept")
            continue
        if not ok:
            log(f"nightly-next run {run_id}: kept on re-read, {why}")
            continue
        if prs:
            log(f"nightly-next run {run_id}: kept, PR #{prs[0]} is open at its head")
            continue
        mine = rules.attempt_jobs(current, last) if last is not None else None
        started = rules.build_started(mine) if mine is not None else "its jobs could not be read"
        if started:
            log(f"nightly-next run {run_id}: kept on the last read of its jobs, {started}")
            continue
        if dry_run:
            log(f"nightly-next run {run_id}: would cancel, {why}")
            done.append(run_id)
            continue
        try:
            api.cancel(run_id)
        except Unreadable as error:
            warn(f"run {run_id}: the cancel was refused ({error}); the next push reads it again")
            continue
        log(f"::notice title=nightly-next supersede::cancelled run {run_id} ({group_of(current)} group, "
            f"{str(current.get('head_sha'))[:12]}) so the tip builds: {why}")
        done.append(run_id)
    return later


def tick(rules: ModuleType, api: Api, *, dry_run: bool = False, settle: bool = False,
         log: Callable[[str], None] = print, clock: Clock = _utc_now,
         sleep: Callable[[float], None] = time.sleep, chain: int | None = None) -> list[int]:
    """One sweep, and with `settle` one more after the shortest wait a kept holder needs (at most SETTLE_MAX).
    With CHAIN (this run's link, 0 for a push), a last sweep that still keeps a holder only for its READY_WAIT
    dispatches the next link, up to CHAIN_MAX; a dry run never does."""
    done: list[int] = []
    waits: list[dt.timedelta] = []
    later = sweep(rules, api, dry_run=dry_run, log=log, clock=clock, done=done, waits=waits)
    if settle and later is not None and len(done) < MAX_CANCELS:
        pause = min(later, SETTLE_MAX).total_seconds() + 5
        log(f"nightly-next supersede: judging again in {int(pause)} s")
        sleep(pause)
        waits.clear()
        sweep(rules, api, dry_run=dry_run, log=log, clock=clock, done=done, waits=waits)
    if chain is not None and waits and len(done) < MAX_CANCELS:
        if dry_run:
            log(f"nightly-next supersede: would dispatch link {chain + 1} (a holder still lacks {min(waits)})")
        elif chain >= CHAIN_MAX:
            log(f"::warning title=nightly-next supersede::a holder still lacks {min(waits)} after {CHAIN_MAX} "
                "re-dispatches; the next promotion or scripts/ci/nightly_now.py judges it again")
        else:
            try:
                api.rearm(chain + 1)
                log(f"nightly-next supersede: a holder still lacks {min(waits)}; dispatched link {chain + 1} "
                    f"of at most {CHAIN_MAX}")
            except Unreadable as error:
                log(f"::warning title=nightly-next supersede::the re-dispatch was refused ({error}); the next "
                    "promotion judges it again")
    return done


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("repo")
    parser.add_argument("--rules", required=True, help="main's scripts/ci/delivery_workflows.py")
    parser.add_argument("--settle", action="store_true", help="judge once more after a kept holder's wait")
    parser.add_argument("--dry-run", action="store_true", help="read and decide only; cancel nothing")
    parser.add_argument("--chain", type=int, default=None,
                        help="this run's link of the re-dispatch chain (0 for a push); omitted, never re-dispatch")
    args = parser.parse_args(argv)
    try:
        rules = load_rules(args.rules)
    except (Unreadable, OSError, SyntaxError) as error:
        print(f"::warning title=nightly-next supersede::the stale rule could not be loaded ({error}); nothing cancelled")
        return 0
    tick(rules, Api(args.repo), dry_run=args.dry_run, settle=args.settle, chain=args.chain)
    return 0


if __name__ == "__main__":
    sys.exit(main())
