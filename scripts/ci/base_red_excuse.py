#!/usr/bin/env python3
"""Excuse a red check that fails the same way on the base branch.

Run via scripts/gh-merge-green before it refuses a red cmux-next run or a red
required check. A failed job on the PR head is excused only when the same job
of the same workflow, on the latest completed run of the base branch that has
a verdict, also failed, and the head's failed steps and failing test names are
all among the base's. Error lines are compared only when no test failed (a
compile error, say), and warnings never are: they vary run to run (SwiftPM's
cache warnings refused #18147 on 2026-10-07). Names are compared, not counts:
the base may fail more. A runner refusal (no steps, a failed setup step, or the glaeda
hook's refusal), a cancelled or timed-out job, and a failure with no test or
error line to compare are never excused. A job whose runner was lost (test_reds.lost_runner: GitHub's "lost
communication with the server" annotation, a step left unfinished, no log stored) is refused as infra, not a
verdict: never the PR's own red, it needs a re-run like a cancelled job. One base red then no longer freezes
every pull request into that base (2026-10-07: four base reds, and the PRs
fixing them deadlocked on each other's reds).

A job that runs tests is judged per test by scripts/ci/test_reds.py, the one
classifier for "red on the base, so not ours" (2026-10-28: cmux#26346 landed
with its own test helper crash because the job was red on the base too). A
failing test the base's run does not fail is the head's; a crash (signal,
abort, EXC_*, Fatal error) is the head's whatever the base shows; and a run
whose per-test results are cut short (no summary, ended early, stuck) is the
head's, since nothing in it can be compared.

A failing test is the base's when it failed on any of the newest BASE_WINDOW base verdicts for its job, not only
the newest (2026-11-01). The newest verdict still decides whether the job is red on the base at all: when it is
not a failure, nothing older is read (fixed_on_base, below). When it is, a head failing test, failed step or error
line that the newest red run lacks is looked for in the older verdicts, newest first, at most BASE_WINDOW verdicts
within BASE_WINDOW_HOURS of the newest, and only back to the first green one: a green base run means every
test passed there, so an older red may predate a fix and never counts. A crash, a cut-short run, the
Chromium check, a process signal and the panic ratchet are judged against the newest alone, as before. Why: the
feat-cmux-next tip Swift suite fails 59 to 106 tests on every run and the set churns:
modelModeAndOptionPicksGoToThisChat() failed on run 41282022128, passed on 41298073172 and failed again on
41303556638, and 56 of the 115 tests that failed on the last six runs failed on only one of them. So a pull
request's test that is flaky on the base read as its own red whenever the newest run happened to pass it, and
reviewed PRs sat. The audit line names the run each such test failed on.

A compile check that gave no verdict (the build fleet's "no result", "No build-fleet verdict") is never a
base red, even with the base's identical line: nothing compiled the head. It is set aside only when the
same head has a real compile pass (a green Mac Release compile or a cmux-next/compile success). Error
lines are compared with commit shas masked, so a real red that names each run's own commit still matches.

No failure is exit 0: asked about no red run or check (or about a green ws-check), it prints why and exits 0. A
red run or check it was named that shows no failed job is still refused (2026-11-05: land-judge asks it about
every merge, and a green head read as exit 1).

Every run is bounded: past DEADLINE_SECONDS of wall clock (BASE_RED_EXCUSE_DEADLINE_SECONDS) it stops and refuses as
infra, not a verdict. A --sha that is one character forty times (a test's "a" * 40, an all-zero sha) is refused at
once, before any read, unless BASE_RED_EXCUSE_FIXTURE_SHA=1 says a test fixture answers for it. 2026-11-05: a
gh-merge-green test run's classifier, --sha aaaa... against a fake gh whose list never ended, outlived its test and ran
for three days on gcp-agent-lane-2, holding 27.6 GB.
"""
from __future__ import annotations

# This check is a deterministic version comparison. Blacksmith's Actions log
# exposes only the generic exit annotation, so there is no useful output line
# for the normal signature matcher to compare. Its failed step is the stable
# failure identity; compare that step on the base just like a test name.
CHROMIUM_CURRENCY_JOB = "Shipped Chromium is at most one stable milestone behind"
CHROMIUM_CURRENCY_STEP = "Pinned Chromium against Chrome stable"

import argparse
import bisect
import contextvars
import copy
import functools
import hashlib
import importlib.util
import io
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from collections import Counter
from typing import Callable, NamedTuple

_http_spec = importlib.util.spec_from_file_location("deadline_http", Path(__file__).with_name("deadline_http.py"))
deadline_http = importlib.util.module_from_spec(_http_spec)
_http_spec.loader.exec_module(deadline_http)

try:  # a failed job's log as this host's glaeda-gh kept it (no API call); absent, every log is read from GitHub
    _glaeda_spec = importlib.util.spec_from_file_location("glaeda_log", Path(__file__).with_name("glaeda_log.py"))
    glaeda_log = importlib.util.module_from_spec(_glaeda_spec)
    _glaeda_spec.loader.exec_module(glaeda_log)
except OSError:
    glaeda_log = None

_spec = importlib.util.spec_from_file_location("main_fix_evidence", Path(__file__).with_name("main_fix_evidence.py"))
_evidence = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_evidence)
Refused, job_for, latest_checks = _evidence.Refused, _evidence.job_for, _evidence.latest_checks
# A read GitHub rate-limited, where the evidence reader tells it apart (main's main_fix_evidence.py): exit 3, which
# gh-merge-green reports as a rate limit rather than a red. A reader without it raises Refused (exit 1).
RateLimited = getattr(_evidence, "RateLimited", ())


class RateLimitedRead(Exception):
    """A read GitHub rate-limited, as judge() re-raises it so the comparison cannot swallow it.

    main's RateLimited is a Refused, and the comparison turns a Refused from a read into a refusal of its
    own ("no rollup red is excused", say) in a dozen places, so a rate limit read as a verdict on the red
    and main() returned 1 where gh-merge-green expects 3. This is not a Refused, so only main() catches it.
    """


class JobBudgetCut(Exception):
    """A judgement's live base job-list reads ran out (CALL_JOB_READS, job_budget) or glaeda-gh's sweep guard refused
    one: a read that never happened. Not a Refused, for RateLimitedRead's reason: the comparison turns a Refused from
    a read into a refusal of its own in a dozen places, so the guard's raw text came out of a web or gallery path as
    the judgement's answer. one_judgement makes it the timed retry (cut_refusal) for the red being judged (NAME)."""

    def __init__(self, reads: int, name: str | None):
        super().__init__(f"{reads} live base job lists read")
        self.reads, self.name = reads, name


def rate_limited_classes() -> tuple:
    """What main() reports as a rate limit, as one flat tuple. A reader without RateLimited leaves it the empty
    tuple, and `except ((), RateLimitedRead)` is a TypeError on every other refusal ("catching classes that do not
    inherit from BaseException"), which would break the ordinary exit-1 path. Read at call time, so a caller that
    loads a reader with RateLimited (main's) is honoured."""
    return ((RateLimited,) if isinstance(RateLimited, type) else tuple(RateLimited)) + (RateLimitedRead,)


def json_shape(route: str, found, *, paginate: bool = False, none: bool = False):
    """FOUND, GitHub's parsed answer to ROUTE, when it is a JSON object or list (a paginated read: each page is one);
    NONE lets a None through (a test fake's empty answer). Anything else is Refused as unread, naming the first
    SHAPE_CHARS characters of what came back, so no reader below calls `.get` on it. While the REST quota was spent
    a read of a workflow's runs came back as a str, and list_base_runs' `listed.get("workflow_runs")` raised
    AttributeError, a traceback land-judge showed as the refusal (cmux#39676 at 9be3f014, 2026-11-10)."""
    for page in found if paginate and isinstance(found, list) else [found]:
        if not (isinstance(page, (dict, list)) or (none and page is None)):
            raise Refused(f"GitHub's answer to {route} could not be read: {str(page)[:SHAPE_CHARS]}")
    return found


SHAPE_CHARS = 200


# One read per source per judgement (review of cmux#41151 at bfa0db5f, F1): an excuse path may ask a source twice (the
# app FFI pin rule's whole-log and rollup readings each prove a published base pin: its release files and compile
# evidence), and a second network read that fails (a 503) must never overturn a proof the first one made. judge()
# opens one memo per judgement, and every network entry point is answered from it after its first read, a failed one
# too: one source gives one answer per judgement (a file one read found absent is never found on a second), and a 503
# is not asked twice. The entry points (review of cmux#41266 at 8fafe451, F1: source_text's git read was outside it):
#   gh       GitHub.run's reads (`gh api` REST and GraphQL, `gh run view`), and rate_limit_aware's json, blob and
#            GraphQL reads, so a client that is not GitHub (the tests' fakes) is read once too;
#   git      git_text (a fetch and a `git show`), and source_text as a whole (git, then GraphQL);
#   release  ffi_release_file (the release download, then the release-assets API);
#   receipt  compile_receipt (the receipts host);
#   artifact GitHub.artifact_file (by range, or the zip whole).
# tests/test_base_red_excuse.py's OneReadPerJudgement wraps each of them and fails on a key read twice in a judgement.
# Outside a judgement (a direct call, a test of one reader) every read goes out, as before.
JUDGEMENT_READS: contextvars.ContextVar = contextvars.ContextVar("judgement_reads", default=None)


def read_once(key: tuple, read: Callable[[], object]):
    """READ's answer, read once per judgement under KEY (JUDGEMENT_READS), or the exception it raised; each caller gets
    its own copy, so no reader changes what another is answered."""
    memo = JUDGEMENT_READS.get()
    if memo is None:
        return read()
    if key not in memo:
        try:
            memo[key] = (True, read())
        except (Refused, RateLimitedRead) as why:
            memo[key] = (False, why)
    ok, found = memo[key]
    if not ok:
        raise found
    return copy.deepcopy(found)


def once_per_judgement(kind: str, key: Callable[..., tuple] | None = None):
    """A network entry point read once per judgement (read_once) under (KIND, KEY(*args) or args, kwargs): KEY drops an
    argument that names no source (a client, a method's self)."""
    def wrap(function):
        @functools.wraps(function)
        def read(*args, **kwargs):
            named = key(*args, **kwargs) if key is not None else args
            return read_once((kind, *named, *sorted(kwargs.items())), lambda: function(*args, **kwargs))
        return read
    return wrap


# gh api's flags that take a value (gh help api); a value is never read as the method, a field or the endpoint.
GH_API_FIELD_FLAGS = ("-f", "-F", "--field", "--raw-field")
GH_API_VALUE_FLAGS = ("-H", "--header", "-q", "--jq", "-t", "--template", "--hostname", "--cache", "-p", "--preview")


def gh_read(args: list[str]) -> bool:
    """Whether gh ARGS only reads, by the HTTP method gh sends (review of cmux#41312 at 67c48fb7, F1): `gh run view`;
    `gh api` with an explicit GET (its fields are query parameters); `gh api` with no method and no body, which gh
    sends as GET; or a GraphQL query. Any other explicit method writes, a field or --input with no method is gh's
    POST, and a GraphQL mutation, a query from a file or stdin, or a call with no query writes. Only a read is kept
    for the judgement (read_once), so a write always goes out."""
    if args[:2] == ["run", "view"]:
        return True
    if args[:1] != ["api"]:
        return False
    method, fields, body, endpoint = None, [], False, None
    rest = iter(args[1:])
    for arg in rest:
        if arg in ("-X", "--method"):
            method = next(rest, "")
        elif arg.startswith("--method="):
            method = arg.partition("=")[2]
        elif arg.startswith("-X"):
            method = arg[2:]
        elif arg in GH_API_FIELD_FLAGS:
            fields.append(next(rest, ""))
        elif arg.startswith(("--field=", "--raw-field=")):
            fields.append(arg.partition("=")[2])
        elif arg.startswith(("-f", "-F")) and not arg.startswith("--"):
            fields.append(arg[2:])
        elif arg == "--input":
            body = True
            next(rest, None)
        elif arg.startswith("--input="):
            body = True
        elif arg in GH_API_VALUE_FLAGS:
            next(rest, None)
        elif not arg.startswith("-") and endpoint is None:
            endpoint = arg
    if endpoint == "graphql":
        queries = [field.partition("=")[2] for field in fields if field.startswith("query=")]
        if body or len(queries) != 1 or (method is not None and method.upper() not in ("GET", "POST")):
            return False
        text = queries[0].lstrip()
        return not text.startswith(("mutation", "@")) and text != "-"
    if method is not None:
        return method.upper() == "GET"
    return not fields and not body


def once_key(name: str, args: tuple, kwargs: dict) -> tuple | None:
    """read_once's key for a rate_limit_aware read NAME(ARGS, KWARGS), or None for one that is not kept: anything but
    json, blob and a GraphQL query. A job's log is not kept: each job's log has one reader per judgement (read_head,
    base_evidence, the guard and web readers), and it is no proof a second read could overturn."""
    if name in ("json", "blob"):
        return (name, repr(args), repr(sorted(kwargs.items())))
    if name == "run" and args and isinstance(args[0], list) and args[0][:2] == ["api", "graphql"]:
        return ("graphql", kwargs.get("repo"), repr(args[0]))
    return None


def rate_limit_aware(github):
    """GITHUB with every rate-limited read raised as RateLimitedRead instead (above), and every `json` read that is not
    a JSON object or list Refused as unread (json_shape). Reads are looked up on each call, so a caller that replaces
    one (the tests' fakes) is still read, and checked. Each network read is read once per judgement (read_once)."""
    class Aware:
        def __getattr__(self, name: str):
            attribute = getattr(github, name)
            if not callable(attribute):
                return attribute

            def go(*args, **kwargs):
                try:
                    found = attribute(*args, **kwargs)
                except RateLimited as error:
                    raise RateLimitedRead(str(error)) from None
                if name == "json" and args:
                    return json_shape(str(args[0]), found, paginate=bool(kwargs.get("paginate")), none=True)
                return found

            def read(*args, **kwargs):
                key = once_key(name, args, kwargs)
                return go(*args, **kwargs) if key is None else read_once(key, lambda: go(*args, **kwargs))

            return read

    return Aware()


# The fields this script reads from each REST list it reads, as a `gh api --jq` projection. On an agent host the gh
# shim answers a REST read over GraphQL while the REST quota is under its floor, and GraphQL's answer has REST's
# common fields only, so a read with no --jq (a whole object) was refused there: manaflow-ai/cmux#38416's merge check
# stopped on "GraphQL could not answer `gh api repos/manaflow-ai/cmux/actions/runs/42476982159/jobs?...`: a whole REST
# object ...; add --jq naming fields" (2026-11-08). Naming the fields lets it answer, and on REST the projection
# keeps every field read here (a job's runner and labels are never read). A field added to a reader of these lists
# goes here too: a missing one reads as null, never as a refusal. Reads GraphQL can't answer whatever the fields
# (a single job, a compare's merge base, a run's check suite node id, artifacts, workflow runs) stay whole.
JOB_FIELDS = ("id, name, run_id, run_attempt, head_sha, head_branch, workflow_name, status, conclusion, started_at, "
              "completed_at, html_url, url, check_run_url")
STEP_FIELDS = "name, status, conclusion, number, started_at, completed_at"
PROJECTIONS = (
    # A run's jobs (filter=all or latest), one page each.
    (re.compile(r"repos/[^/]+/[^/]+/actions/runs/\d+(?:/attempts/\d+)?/jobs(?:\?.*)?"),
     f"{{total_count, jobs: [.jobs[] | {{{JOB_FIELDS}, steps: [.steps[]? | {{{STEP_FIELDS}}}]}}]}}"),
    # A commit's statuses, newest first, with who posted each (compile_status_at).
    (re.compile(r"repos/[^/]+/[^/]+/commits/[^/?]+/statuses(?:\?.*)?"),
     "[.[] | {context, state, description, target_url, created_at, creator: {login: .creator.login, "
     "id: .creator.id, type: .creator.type}}]"),
    # A commit's combined status.
    (re.compile(r"repos/[^/]+/[^/]+/commits/[^/?]+/status(?:\?.*)?"),
     "{state, sha, total_count, statuses: [.statuses[] | {context, state, description, target_url, created_at, "
     "updated_at}]}"),
    # A branch's commit history.
    (re.compile(r"repos/[^/]+/[^/]+/commits\?(?:.*&)?sha=.*"),
     "[.[] | {sha, commit: {committer: {date: .commit.committer.date}}, parents: [.parents[]? | {sha}]}]"),
)


def projection(route: str) -> str | None:
    """The `--jq` projection for ROUTE (PROJECTIONS), or None to read it whole."""
    return next((jq for pattern, jq in PROJECTIONS if pattern.fullmatch(route)), None)


ESCAPE_FLAG = "--allow-escape-sequences"
UNKNOWN_ESCAPE_FLAG = f"unknown flag: {ESCAPE_FLAG}"
REQUEST_FAILED = "GitHub evidence request failed: "


# Notes an agent host's gh wrappers write before the real gh's own stderr (a wait on a repeated read).
WRAPPER_NOTE_PREFIXES = ("glaeda-gh:", "gh-quota:")


def escape_flag_unknown(stderr: str) -> bool:
    """Whether an old gh rejected the optional ANSI-output flag itself: gh's first line, after any
    wrapper notes, is exactly the refusal. Another unknown flag first still refuses."""
    lines = [line.strip() for line in (stderr or "").strip().splitlines()]
    gh_lines = [line for line in lines if not line.startswith(WRAPPER_NOTE_PREFIXES)]
    return bool(gh_lines) and gh_lines[0] == UNKNOWN_ESCAPE_FLAG


# Settled reads (2026-11-17): GitHub answers that can no longer change are read once per host and kept, so a merge
# check run again after a quota refusal reads none of them again. land-judge refused cmux#45097 at 6aa5d9938d5f five
# times with "[quota: not judged, retry]" while it read "ok: may merge": each run re-read the same finished head and
# base runs over the shared login's REST, which other callers spent within minutes of each reset. Kept (in
# jobs_cache(), so BASE_RED_EXCUSE_JOBS_CACHE=off turns it off): a completed job (a re-run is a new job id), a commit, a
# compare of two commits, and a completed run's record and job lists. A run's record and job lists are served only
# while the run is the same completed attempt GitHub serves now (run_now: a run record or list this process read live,
# else this host's glaeda-gh at most GLAEDA_RUN_FRESH_SECONDS old); a run re-run since, still in progress, or not known
# now is read live, as before. Never kept: lists of a branch's runs, a commit's checks or statuses, compares of a
# branch: they are answers about now.
SETTLED_KEEP_SECONDS = 14 * 24 * 3600
GLAEDA_RUN_FRESH_SECONDS = 600
_SETTLED_REPO = r"repos/(?P<repo>[\w.-]+/[\w.-]+)"
SETTLED_JOB = re.compile(rf"{_SETTLED_REPO}/actions/jobs/\d+")
SETTLED_RUN = re.compile(rf"{_SETTLED_REPO}/actions/runs/(?P<run>\d+)")
SETTLED_RUN_JOBS = re.compile(rf"{_SETTLED_REPO}/actions/runs/(?P<run>\d+)/jobs\?filter=(?:all|latest)&per_page=\d+")
SETTLED_FOREVER = re.compile(rf"{_SETTLED_REPO}/(?:commits/[0-9a-f]{{40}}|compare/[0-9a-f]{{40}}\.\.\.[0-9a-f]{{40}}"
                             r"(?:\?per_page=\d+)?)")
RUNS_LIST = re.compile(rf"{_SETTLED_REPO}/actions/(?:workflows/[^/?]+/)?runs\?.*")
_SETTLED_PRUNED: list[bool] = []
NOT_KEPT = object()


def live_runs() -> dict[tuple[str, int], dict]:
    """Every run record this judgement read live (a run, or a list of runs), by (repo, run id): what GitHub serves
    now. Kept in the judgement's memo (JUDGEMENT_READS), so it lives no longer than that; outside a judgement, none."""
    memo = JUDGEMENT_READS.get()
    return {} if memo is None else memo.setdefault(("live runs",), {})


def settled_file(route: str, state: tuple | None = None) -> Path | None:
    where = jobs_cache()
    if where is None:
        return None
    import hashlib
    name = hashlib.sha256(json.dumps([route, state]).encode()).hexdigest()[:40]
    return where / "settled" / f"{name}.json"


def settled_get(route: str, state: tuple | None = None):
    """The answer kept for ROUTE (in STATE), or NOT_KEPT."""
    path = settled_file(route, state)
    if path is None:
        return NOT_KEPT
    try:
        kept = json.loads(path.read_text())
    except (OSError, ValueError):
        return NOT_KEPT
    return kept.get("answer", NOT_KEPT) if isinstance(kept, dict) and kept.get("route") == route else NOT_KEPT


def settled_put(route: str, found, state: tuple | None = None) -> None:
    path = settled_file(route, state)
    if path is None:
        return
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        spare = path.with_name(f".{path.name}.{os.getpid()}")
        spare.write_text(json.dumps({"route": route, "state": state, "answer": found}))
        os.replace(spare, path)
        if not _SETTLED_PRUNED:
            _SETTLED_PRUNED.append(True)
            prune_kept(path.parent, SETTLED_KEEP_SECONDS)
    except OSError:
        pass


def completed_state(run: object) -> tuple[int, str] | None:
    """(run_attempt, updated_at) of a completed RUN, or None for one in progress or that names neither."""
    if not isinstance(run, dict) or run.get("status") != "completed":
        return None
    attempt, updated = run.get("run_attempt"), run.get("updated_at")
    if not isinstance(attempt, int) or not isinstance(updated, str) or not updated:
        return None
    return attempt, updated


def run_now(repo: str, run: int) -> dict | None:
    """RUN's record as GitHub serves it now: one this process read live, else this host's glaeda-gh's when it read
    the run within GLAEDA_RUN_FRESH_SECONDS (its state alone), else None."""
    if (repo, run) in live_runs():
        return live_runs()[(repo, run)]
    kept = read_once(("glaeda run", repo, run), lambda: glaeda_log.cached_run(repo, run)
                     if glaeda_log is not None and hasattr(glaeda_log, "cached_run") else None)
    if isinstance(kept, dict) and time.time() - float(kept.get("at") or 0) <= GLAEDA_RUN_FRESH_SECONDS:
        return kept
    return None


def note_live_runs(repo: str, found) -> None:
    """Remember every full run record in FOUND (a run, a list of runs, or pages of one), read live just now."""
    pages, live = found if isinstance(found, list) else [found], live_runs()
    for page in pages:
        runs = page.get("workflow_runs") if isinstance(page, dict) and "workflow_runs" in page else [page]
        for run in runs or []:
            if isinstance(run, dict) and isinstance(run.get("id"), int) and isinstance(run.get("workflow_id"), int):
                live[(repo, run["id"])] = run
                route = f"repos/{repo}/actions/runs/{run['id']}"
                # A list names up to 100 runs: each is written once, and again only when re-run since.
                if completed_state(run) not in (None, completed_state(settled_get(route))):
                    settled_put(route, run)


def settled_answer(route: str):
    """ROUTE's kept answer when it is still what GitHub would serve, else NOT_KEPT."""
    if SETTLED_FOREVER.fullmatch(route) is not None:
        return settled_get(route)
    if SETTLED_JOB.fullmatch(route) is not None:
        kept = settled_get(route)
        return kept if isinstance(kept, dict) and kept.get("status") == "completed" else NOT_KEPT
    if (found := SETTLED_RUN.fullmatch(route)) is not None:
        repo, run = found["repo"], int(found["run"])
        if (repo, run) in live_runs():
            return copy.deepcopy(live_runs()[(repo, run)])
        state = completed_state(run_now(repo, run))
        kept = settled_get(route) if state is not None else NOT_KEPT
        return kept if completed_state(kept) == state else NOT_KEPT
    if (found := SETTLED_RUN_JOBS.fullmatch(route)) is not None:
        state = completed_state(run_now(found["repo"], int(found["run"])))
        return settled_get(route, state) if state is not None else NOT_KEPT
    return NOT_KEPT


def settle(route: str, found) -> None:
    """Keep FOUND, ROUTE's live answer, when it can no longer change (settled_answer serves it)."""
    if SETTLED_FOREVER.fullmatch(route) is not None:
        settled_put(route, found)
    elif SETTLED_JOB.fullmatch(route) is not None:
        if isinstance(found, dict) and found.get("status") == "completed":
            settled_put(route, found)
    elif (match := SETTLED_RUN.fullmatch(route) or RUNS_LIST.fullmatch(route)) is not None:
        note_live_runs(match["repo"], found)
    elif (match := SETTLED_RUN_JOBS.fullmatch(route)) is not None:
        state = completed_state(run_now(match["repo"], int(match["run"])))
        jobs = [job for page in (found if isinstance(found, list) else [found]) if isinstance(page, dict)
                for job in page.get("jobs") or []]
        # Only the attempt the run's state names, every job of it done: a list read while a re-run started is not.
        if (state is not None and jobs and all(isinstance(job, dict) and job.get("status") == "completed"
                                               for job in jobs)
                and max((job.get("run_attempt") or 1) for job in jobs) == state[0]):
            settled_put(route, found, state)

# Conditional CI reads. Every judgement is a new process, and every landing check of a head judges its reds again: on
# 2026-11-17 (2 h to 12:58Z on cosmic-gray) this script spent 673 REST under land-judge, 402 of them a run's jobs and
# 133 of those the exact page read again, mostly base runs that finished long before. When the caller names a folder in
# BASE_RED_EXCUSE_ETAGS (land-judge names its own, teamleaderleo/leo-workspace tools/land_judge/engine.py ci_etags_root), a
# run's jobs, a run, a workflow's runs and a commit's check runs and statuses are read with the ETag of the answer kept
# there for the same route and --jq (gh_conditional's file format and names, so land-judge's reads and these share one
# store), and GitHub answers an unchanged one 304, which costs no quota. A 304 is GitHub's word that the answer is the
# same, so every judgement reads exactly what a plain read gives. Anything but a 200 or a 304 (a wrapper refusing the
# conditional form, an error, a timeout) is the plain read, as before; with no folder named, every read is plain.
ETAGS_ENV = "BASE_RED_EXCUSE_ETAGS"
CONDITIONAL_ROUTE = re.compile(r"repos/[^/]+/[^/]+/(?:actions/runs(?:/\d+(?:/attempts/\d+)?(?:/jobs)?)?"
                               r"|actions/workflows/[^/?]+/runs|commits/[0-9A-Fa-f]{40}/(?:check-runs|status|statuses))"
                               r"(?:\?.*)?")
HTTP_STATUS = re.compile(r"HTTP/[0-9.]+ ([0-9]{3})")
CONDITIONAL_SECONDS = 90  # main_fix_evidence.GitHub.run's bound


def etags_root() -> Path | None:
    """The folder BASE_RED_EXCUSE_ETAGS names (absolute), or None: every read is plain."""
    folder = os.environ.get(ETAGS_ENV, "")
    return Path(folder) if folder and os.path.isabs(folder) else None


def conditional_read(args: list[str], root: Path) -> str | None:
    """gh ARGS' answer by a conditional read against the one kept under ROOT, for `api ROUTE [--jq JQ]` of a
    CONDITIONAL_ROUTE; None for any other ARGS, or when GitHub's answer was neither a 200 nor a 304 (the caller reads
    it plainly)."""
    if args[:1] != ["api"] or len(args) not in (2, 4) or (len(args) == 4 and args[2] != "--jq"):
        return None
    route, jq = args[1], (args[3] if len(args) == 4 else None)
    if not CONDITIONAL_ROUTE.fullmatch(route):
        return None
    name = f"{route}\0{jq}" if jq is not None else f"{route}\0\0whole"
    store = root / (hashlib.sha256(name.encode()).hexdigest()[:32] + ".json")
    try:
        kept = json.loads(store.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        kept = None
    if not (isinstance(kept, dict) and kept.get("url") == route and kept.get("jq") == jq
            and isinstance(kept.get("etag"), str) and kept["etag"] and isinstance(kept.get("out"), str)):
        kept = None
    argv = ["gh", "api", "--include", *(["-H", f"If-None-Match: {kept['etag']}"] if kept else []), route,
            *(["--jq", jq] if jq is not None else [])]
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
        try:
            process = subprocess.Popen(argv, stdout=output, stderr=errors, stdin=subprocess.DEVNULL)
        except OSError:
            return None
        try:
            process.wait(timeout=CONDITIONAL_SECONDS)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            return None
        if output.tell() > _evidence.MAX_OUTPUT:
            return None
        output.seek(0)
        said = output.read().decode(errors="replace")
    head, _, body = said.replace("\r\n", "\n").partition("\n\n")
    status = HTTP_STATUS.match(head)
    if status and status.group(1) == "304" and kept:
        try:
            os.utime(store)
        except OSError:
            pass
        return kept["out"]
    if not (status and status.group(1) == "200" and process.returncode == 0):
        return None
    etag = next((line.split(":", 1)[1].strip() for line in head.splitlines()[1:]
                 if line.lower().startswith("etag:")), "")
    if etag:
        try:
            root.mkdir(parents=True, exist_ok=True)
            tmp = store.with_name(f".{store.name}.{os.getpid()}.tmp")
            tmp.write_text(json.dumps({"url": route, "jq": jq, "etag": etag, "out": body}), encoding="utf-8")
            os.replace(tmp, store)
        except OSError:
            pass  # a failed write only costs the next read its 304
    return body


class GitHub(_evidence.GitHub):
    """GitHub client for red attribution, including logs of finished jobs in live runs."""

    def run(self, args: list[str], *, repo: str | None = None) -> str:
        """gh ARGS' output; a read is read once per judgement (JUDGEMENT_READS), whatever asked it."""
        if not gh_read(args):
            return _evidence.GitHub.run(self, args, repo=repo)
        return read_once(("gh", repo, *args), lambda: self.read_conditional(args, repo))

    def read_conditional(self, args: list[str], repo: str | None = None) -> str:
        """gh ARGS (a read): conditional first when the caller named an ETag folder (etags_root), else plain."""
        root = etags_root()
        said = conditional_read(args, root) if root is not None else None
        return said if said is not None else _evidence.GitHub.run(self, args, repo=repo)

    def log(self, repo: str, job: dict) -> str:
        # `gh run view --log` waits for every job in the run. The Actions job
        # endpoint serves a finished job while sibling jobs remain queued.
        route = f"repos/{repo}/actions/jobs/{job['id']}/logs"
        # Request ANSI-capable output first; old gh versions reject the flag, while modern
        # versions reject coloured output without it. Either way, normalize bytes in Python.
        # A log section can open with a byte-order mark before its timestamp, which hides that line from every
        # reader that matches a stamp or a prefix (cmuxterm-hq run 42391652834's WS_CHECK_RESULT, 2026-11-07).
        # This host's glaeda-gh keeps the same bytes for every failed job its daemon saw: read there first, with no
        # API call (a replay of 200 verdicts read each log again: about 150 reads, and it stopped at 51 runs).
        # The log's terminal escapes are stripped here too, once, so no parser of it sees raw colour (#41329's review
        # F2: a summary matched on its raw line missed `\x1b[31mFAILED\x1b[0m`).
        kept = glaeda_log.cached_job_log(repo, job.get("id")) if glaeda_log is not None else None
        if kept is not None:
            return test_reds.plain(kept.replace("\ufeff", ""))
        try:
            return test_reds.plain(self.run(["api", ESCAPE_FLAG, route]).replace("\ufeff", ""))
        except Refused as error:
            said = str(error)
            if not (said.startswith(REQUEST_FAILED) and escape_flag_unknown(said[len(REQUEST_FAILED):])):
                raise
        return test_reds.plain(self.run(["api", route]).replace("\ufeff", ""))

    def json(self, route: str, *, paginate: bool = False, per_page: int = 100):
        """ROUTE's answer: kept on this host when it is settled (settled_answer), else read live and kept when it
        can no longer change (settle)."""
        kept = settled_answer(route)
        if kept is not NOT_KEPT:
            return kept
        found = self.live_json(route, paginate=paginate, per_page=per_page)
        settle(route, found)
        return found

    def live_json(self, route: str, *, paginate: bool = False, per_page: int = 100):
        # A run's job list carries every job's steps; see JOBS_PAGE.
        if paginate and "/jobs?" in route:
            per_page = min(per_page, JOBS_PAGE)
        jq = projection(route)

        def fetch(url: str):
            # Each page is checked as it comes, so the pager never meets a str either (json_shape).
            said = self.run(["api", url, *(("--jq", jq) if jq is not None else ())])
            try:
                found = json.loads(said)
            except ValueError:
                raise Refused(f"GitHub's answer to {url} could not be read: {said[:SHAPE_CHARS]}") from None
            return json_shape(url, found)
        if not paginate:
            return fetch(route)
        try:
            return _evidence.gh_pages.pages(fetch, route, per_page=per_page)
        except _evidence.gh_pages.PageCapError as error:
            raise Refused(str(error)) from None

    def dispatch(self, repo: str, workflow: str, ref: str) -> int | None:
        """Start a workflow_dispatch run of WORKFLOW (a file name) on REF; its run id, or None when GitHub named none.
        Refused when this host's gh may not dispatch (base_dispatch)."""
        said = self.run(["api", "-X", "POST", f"repos/{repo}/actions/workflows/{workflow}/dispatches",
                         "-f", f"ref={ref}", "-F", "return_run_details=true"])
        try:
            run = json.loads(said or "{}").get("workflow_run_id")
        except (ValueError, AttributeError):
            return None
        return run if isinstance(run, int) else None

    @once_per_judgement("artifact", lambda self, repo, artifact, member: (repo, int(artifact), member))
    def artifact_file(self, repo: str, artifact: int, member: str) -> str | None:
        """MEMBER's text in Actions ARTIFACT's zip, or None when the zip has no such file.

        It reads only the zip's end record, its central directory and MEMBER, by HTTP range from the artifact's blob
        (artifact_member_by_range): a few hundred KB however large the zip is. The gallery-health shards grew from
        18 MB to 170-190 MB between 2026-11-07 and 11-11, past the whole-download cap, which refused every
        gallery-health red, base or not (cmux#40955). When the blob cannot be read by range (no token, no redirect,
        a server that answers ranges whole) it downloads the zip whole, as before, under ARTIFACT_MAX_BYTES."""
        try:
            return artifact_member_by_range(repo, artifact, member)
        except RangeUnavailable:
            return self.artifact_file_whole(repo, artifact, member)

    def artifact_file_whole(self, repo: str, artifact: int, member: str) -> str | None:
        """MEMBER's text in Actions ARTIFACT's zip, downloaded whole through gh. Refused when the download fails,
        passes ARTIFACT_SECONDS, or the zip or the file passes ARTIFACT_MAX_BYTES."""
        with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
            # gh in a group of its own: a gh wrapper's child holds stdout too, and only killing the whole group
            # ends the read.
            process = subprocess.Popen(["gh", "api", f"repos/{repo}/actions/artifacts/{int(artifact)}/zip"],
                                       stdout=subprocess.PIPE, stderr=errors, start_new_session=True)

            def kill() -> None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):  # gone, or a macOS zombie group
                    pass

            fired = threading.Event()

            def expire() -> None:
                fired.set()
                kill()

            # A read blocks while gh sends nothing: the deadline kills gh's group, which ends the read
            # (router-review F1 of #37969: a stalled download held the whole run's deadline, not ARTIFACT_SECONDS).
            end = time.monotonic() + ARTIFACT_SECONDS
            deadline = threading.Timer(ARTIFACT_SECONDS, expire)
            deadline.start()
            try:
                kept = 0
                while chunk := process.stdout.read(1 << 20):
                    kept += len(chunk)
                    if kept > ARTIFACT_MAX_BYTES:
                        raise Refused(f"artifact {artifact} is over {ARTIFACT_MAX_BYTES} bytes")
                    output.write(chunk)
                process.wait()
                if fired.is_set() or time.monotonic() > end:  # the timer thread may run late
                    raise Refused(f"artifact {artifact} took over {ARTIFACT_SECONDS} seconds to read")
            finally:
                deadline.cancel()
                kill()  # a stray child of a wrapper too, on every path
                process.wait()
            if process.returncode:
                errors.seek(0)
                raise Refused(REQUEST_FAILED + errors.read(2000).decode(errors="replace"))
            output.seek(0)
            try:
                with zipfile.ZipFile(output) as archive:
                    if member not in archive.namelist():
                        return None
                    info = archive.getinfo(member)
                    if info.file_size > ARTIFACT_MAX_BYTES:
                        raise Refused(f"artifact {artifact}: {member} unpacks past the cap")
                    with archive.open(info) as found:
                        raw = found.read(ARTIFACT_MAX_BYTES + 1)
            except zipfile.BadZipFile as error:
                raise Refused(f"artifact {artifact} is not a zip ({error})") from None
            if len(raw) > ARTIFACT_MAX_BYTES:
                raise Refused(f"artifact {artifact}: {member} unpacks past the cap")
            return raw.decode(errors="replace")

    def blob(self, repo: str, ref: str, path: str) -> str:
        """PATH's text in REPO at REF over GraphQL (`object(expression: "REF:PATH")`), never the contents API: an
        agent host's gh shim refuses `gh api repos/O/R/contents/...` as a source read that spends the shared REST
        quota (source_text). The same query reads the mode of PATH's entry in its parent tree: a symlink's blob is the
        name of its target, never the target's text, so a symlink is followed inside the repository (symlinked_path)
        and read again. Refused when the object is missing, not a file, binary, or a symlink out of the repository."""
        return self.followed(repo, ref, path, *self.entry(repo, ref, path))

    def blob_if_present(self, repo: str, ref: str, path: str) -> str | None:
        """blob, or None only when GitHub answers that REF resolves in REPO and REF:PATH names nothing there (no object
        and no entry in its parent tree). Every other answer (a failed request, a ref GitHub does not resolve, a binary
        or truncated file, a symlink out of the repository) is Refused, never taken for an absent file."""
        found, mode = self.entry(repo, ref, path)
        if found is None and mode is None:
            if self.named_object(repo, ref) is None:
                raise Refused(f"{repo}@{ref}: GitHub resolves no such ref, so {path} is unread, not absent")
            return None
        return self.followed(repo, ref, path, found, mode)

    def entry(self, repo: str, ref: str, path: str) -> tuple[dict | None, int | None]:
        """The object REF:PATH names in REPO (a blob's fields, {} for a commit or tree, None for none) and the mode of
        PATH's entry in its parent tree (None when that tree lists no such entry), both from one BLOB_QUERY. Refused
        when GitHub does not serve REPO or answers with errors."""
        owner, _, name = repo.partition("/")
        found = json.loads(self.run(["api", "graphql", "-f", f"query={BLOB_QUERY}", "-f", f"owner={owner}",
                                     "-f", f"name={name}", "-f", f"expression={ref}:{path}",
                                     "-f", f"parent={ref}:{path.rpartition('/')[0]}"]))
        repository = (found.get("data") or {}).get("repository") if isinstance(found, dict) else None
        if not isinstance(repository, dict) or found.get("errors"):
            raise Refused(f"{repo}: GitHub did not serve {ref}:{path}")
        blob = repository.get("object")
        parent = repository.get("parent")
        entries = parent.get("entries") if isinstance(parent, dict) else None
        base = path.rpartition("/")[2]
        mode = next((entry.get("mode") for entry in entries or () if isinstance(entry, dict)
                     and entry.get("name") == base), None)
        return (blob if isinstance(blob, dict) else None), mode

    def followed(self, repo: str, ref: str, path: str, blob: dict | None, mode: int | None) -> str:
        """The text of PATH's blob, BLOB and MODE as entry read them: a symlink is followed inside the repository
        (symlinked_path), up to SYMLINK_HOPS links, and its target read again."""
        hops = 0
        while True:
            if isinstance(blob, dict) and blob.get("isBinary") and mode != GIT_SYMLINK_MODE:
                raise Refused(f"{repo}@{ref}: {path} is not a text file GitHub served (binary)")
            if not isinstance(blob, dict) or not isinstance(blob.get("text"), str):
                why = "a symlink with no target" if mode == GIT_SYMLINK_MODE else "missing, or not a file"
                raise Refused(f"{repo}@{ref}: {path} is not a text file GitHub served ({why})")
            if mode is None:
                # No entry for PATH in its parent tree (no parent read, or PATH runs through a symlinked directory):
                # a symlink's blob would read as its target's name, so nothing is taken from it.
                raise Refused(f"{repo}@{ref}: {path} has no entry GitHub served in its parent tree (a path through "
                              "a symlinked directory is not followed)")
            if mode == GIT_SYMLINK_MODE:
                hops += 1
                if hops > SYMLINK_HOPS:
                    raise Refused(f"{repo}@{ref}: {path} is a symlink loop (over {SYMLINK_HOPS} hops)")
                path = symlinked_path(repo, ref, path, blob["text"])
                blob, mode = self.entry(repo, ref, path)
                continue
            if blob.get("isTruncated"):
                raise Refused(f"{repo}@{ref}: {path} was served truncated")
            return blob["text"]

    def named_object(self, repo: str, expression: str) -> dict | None:
        """The object EXPRESSION names in REPO (OBJECT_QUERY: a blob's fields, {} for a commit or tree), or None when
        it names none. Refused when GitHub does not serve REPO or answers with errors."""
        owner, _, name = repo.partition("/")
        found = json.loads(self.run(["api", "graphql", "-f", f"query={OBJECT_QUERY}", "-f", f"owner={owner}",
                                     "-f", f"name={name}", "-f", f"expression={expression}"]))
        repository = (found.get("data") or {}).get("repository") if isinstance(found, dict) else None
        if not isinstance(repository, dict) or found.get("errors"):
            raise Refused(f"{repo}: GitHub did not serve {expression}")
        named = repository.get("object")
        return named if isinstance(named, dict) else None


BLOB_QUERY = ("query($owner: String!, $name: String!, $expression: String!, $parent: String!) { repository(owner: "
              "$owner, name: $name) { object(expression: $expression) { ... on Blob { text isBinary isTruncated } } "
              "parent: object(expression: $parent) { ... on Tree { entries { name mode } } } } }")
OBJECT_QUERY = ("query($owner: String!, $name: String!, $expression: String!) { repository(owner: $owner, name: $name) "
                "{ object(expression: $expression) { ... on Blob { text isBinary isTruncated } } } }")
# A tree entry's mode for a symlink (0o120000; GraphQL's TreeEntry.mode is the integer), and how many links one read
# follows before it is refused as a loop.
GIT_SYMLINK_MODE = 0o120000
SYMLINK_HOPS = 40


def symlinked_path(repo: str, ref: str, link: str, target: str) -> str:
    """The repository path the symlink LINK (whose blob is TARGET) names; Refused when it leaves the repository."""
    import posixpath
    joined = posixpath.normpath(posixpath.join(posixpath.dirname(link), target))
    if target.startswith("/") or joined in ("..", ".") or joined.startswith("../"):
        raise Refused(f"{repo}@{ref}: {link} is a symlink to {target}, outside the repository")
    return joined


# Where git_text keeps its shallow, blob-less fetches of other repos (one bare repo each). Override for tests or a
# host whose cache lives elsewhere.
SOURCE_CACHE_ENV = "BASE_RED_EXCUSE_SOURCE_CACHE"
GIT_SECONDS = 60
# The whole run's wall-clock bound (module docs). Real runs read a few job logs and finish in well under a minute.
DEADLINE_SECONDS = 1200
PLACEHOLDER_SHA = re.compile(r"([0-9a-fA-F])\1{39}")


class Deadline(BaseException):
    """The run passed its deadline. A BaseException, so no `except Refused` or `except Exception` on the way out
    takes it for a verdict and reads on."""


def deadline_seconds() -> int:
    raw = os.environ.get("BASE_RED_EXCUSE_DEADLINE_SECONDS", "")
    try:
        value = int(raw) if raw else DEADLINE_SECONDS
    except ValueError:
        return DEADLINE_SECONDS
    return value if value > 0 else DEADLINE_SECONDS


def _past_deadline(signum, frame):
    raise Deadline()


def source_cache() -> Path:
    named = os.environ.get(SOURCE_CACHE_ENV)
    if named:
        return Path(named)
    return Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "base-red-excuse" / "src"


def git_remote(repo: str) -> str:
    return f"https://github.com/{repo}.git"


# The source cache's bound. Every object a fetch brings lands in a promisor pack, which `git gc` keeps whatever is
# reachable, and the refs git_commit fetches into are deleted after: so the one-commit fetches, the blobs `git show`
# fetches lazily, ws_check_squash_tree's whole-history fetch and its merge-tree objects piled up for good (2.3 GB on
# the land host on 2026-11-21, nothing removing any of it). A repo whose objects pass SOURCE_CACHE_MAX_BYTES
# (BASE_RED_EXCUSE_SOURCE_CACHE_MAX_BYTES) is made again from nothing by the next run that finds no other run using
# it, which is cheap: every fetch is blob-less and git_commit's one commit deep. A repo made less than
# SOURCE_CACHE_MIN_AGE_SECONDS ago is kept whatever its size, so a working set above the cap is rebuilt once a day at
# most, never once a run. Each run holds a shared flock on the repo's lock file (beside it) from its first git_cache
# call to its exit; the rebuild takes it exclusive without waiting, so a repo another run is reading is never moved.
SOURCE_CACHE_MAX_BYTES_ENV = "BASE_RED_EXCUSE_SOURCE_CACHE_MAX_BYTES"
SOURCE_CACHE_MAX_BYTES = 512 * 1024 * 1024
SOURCE_CACHE_MIN_AGE_SECONDS = 24 * 3600
SOURCE_CACHE_STAMP = "base-red-excuse-made"
_SOURCE_CACHE_LOCKS: dict[str, int] = {}


def source_cache_max_bytes() -> int:
    raw = os.environ.get(SOURCE_CACHE_MAX_BYTES_ENV, "")
    try:
        value = int(raw) if raw else SOURCE_CACHE_MAX_BYTES
    except ValueError:
        return SOURCE_CACHE_MAX_BYTES
    return value if value > 0 else SOURCE_CACHE_MAX_BYTES


def source_cache_bytes(where: Path) -> int:
    """Bytes under WHERE's objects directory (loose objects, packs and their indexes), files only."""
    total = 0
    for root, _, files in os.walk(where / "objects"):
        for name in files:
            try:
                total += os.lstat(os.path.join(root, name)).st_size
            except OSError:
                pass
    return total


def source_cache_hold(where: Path) -> bool:
    """Hold this run's shared lock on the bare repo WHERE (once per process), rebuilding WHERE first when no other run
    holds it and it is past its bound (SOURCE_CACHE_MAX_BYTES and SOURCE_CACHE_MIN_AGE_SECONDS). True when WHERE was
    moved aside for a fresh one. Without flock (no fcntl) nothing is locked and nothing rebuilt."""
    key = str(where)
    if key in _SOURCE_CACHE_LOCKS:
        return False
    try:
        import fcntl
    except ImportError:
        return False
    where.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(where.with_name(where.name + ".lock"), os.O_RDWR | os.O_CREAT, 0o644)
    rebuilt, retired = False, []
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        fcntl.flock(fd, fcntl.LOCK_SH)  # another run reads WHERE: share it, rebuild nothing
    else:
        # No other run holds WHERE, nor any copy an earlier rebuild moved aside.
        retired = sorted(where.parent.glob(where.name + ".retired-*"))
        try:
            made = (where / SOURCE_CACHE_STAMP).stat().st_mtime
        except OSError:
            made = 0.0  # a repo from before the stamp: as old as can be
        if ((where / "HEAD").is_file() and time.time() - made > SOURCE_CACHE_MIN_AGE_SECONDS
                and source_cache_bytes(where) > source_cache_max_bytes()):
            aside = where.with_name(f"{where.name}.retired-{os.getpid()}-{int(time.time())}")
            try:
                os.rename(where, aside)
                retired.append(aside)
                rebuilt = True
            except OSError:
                pass
        fcntl.flock(fd, fcntl.LOCK_SH)
    _SOURCE_CACHE_LOCKS[key] = fd  # held until this process exits
    for old in retired:  # nothing reads a moved-aside copy: removed outside the exclusive hold
        shutil.rmtree(old, ignore_errors=True)
    return rebuilt


def git_cache(repo: str) -> Callable[..., subprocess.CompletedProcess] | None:
    """`git` in REPO's bare repo under source_cache(), made and pointed at REPO's remote (blob-less) on first use; None
    when it cannot be."""
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repo):
        return None
    where = source_cache() / (repo.replace("/", "__") + ".git")
    env = {**os.environ, "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "", "SSH_ASKPASS": ""}

    def git(*args: str) -> subprocess.CompletedProcess:
        return subprocess.run(["git", "--git-dir", str(where), *args], capture_output=True, env=env,
                              timeout=GIT_SECONDS, stdin=subprocess.DEVNULL)

    try:
        source_cache_hold(where)
    except OSError:
        pass  # an unlockable cache is still read, only never rebuilt
    if not (where / "HEAD").is_file():
        where.mkdir(parents=True, exist_ok=True)
        if subprocess.run(["git", "init", "-q", "--bare", str(where)], capture_output=True,
                          timeout=GIT_SECONDS).returncode:
            return None
        try:
            (where / SOURCE_CACHE_STAMP).touch()
        except OSError:
            pass
    for key, value in (("remote.origin.url", git_remote(repo)), ("remote.origin.promisor", "true"),
                       ("remote.origin.partialclonefilter", "blob:none")):
        if git("config", key, value).returncode:
            return None
    return git


@once_per_judgement("git fetch")
def git_commit(repo: str, ref: str) -> str | None:
    """The commit REF names in REPO, fetched one commit deep with no blobs (`--depth=1 --filter=blob:none`) into
    git_cache(REPO), or None when git cannot answer. Once per ref per judgement: every file read at REF (git_text)
    is shown from the one fetch. The fetch goes to a ref of this process's own, so two runs reading different bases at
    once never read each other's; it is removed after, and the commit stays in the repo for `git show`."""
    if ref.startswith("-") or not ref:
        return None
    mine = f"refs/base-red-excuse/{os.getpid()}"
    git = None
    try:
        git = git_cache(repo)
        if git is None or git("fetch", "-q", "--no-tags", "--depth=1", "--filter=blob:none", "origin",
                              f"+{ref}:{mine}").returncode:
            return None
        named = git("rev-parse", "--verify", f"{mine}^{{commit}}")
        commit = named.stdout.decode().strip() if not named.returncode else ""
        return commit if re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", commit) else None
    except (OSError, subprocess.SubprocessError, UnicodeDecodeError):
        return None
    finally:
        if git is not None:
            try:
                git("update-ref", "-d", mine)
            except (OSError, subprocess.SubprocessError):
                pass


def git_tree():
    """scripts/ci/git_tree.py, the one reader of a commit's tree: imported by name, so one module object (and one
    Unreadable) is shared with every other caller."""
    if str(SCRIPT_DIR) not in sys.path:
        sys.path.insert(0, str(SCRIPT_DIR))
    import git_tree as module
    return module


@once_per_judgement("git tree")
def git_tree_entries(repo: str, commit: str) -> dict[str, tuple[str, str]] | None:
    """Every entry of COMMIT's tree in git_cache(REPO) (GitTree.entries: one `ls-tree -r -t`, which the blob-less
    fetch holds), or None when git cannot list it. Once per commit per judgement, however many paths are read."""
    tree = git_tree().GitTree(source_cache() / (repo.replace("/", "__") + ".git"), commit)
    try:
        return tree.entries()
    except git_tree().Unreadable:
        return None
    finally:
        tree.close()


@once_per_judgement("git")
def git_text(repo: str, ref: str, path: str, *, missing=None):
    """PATH's text in REPO at REF from git, or None when git cannot answer (no network, no credentials, no ref).
    MISSING, when given, is returned instead when git fetched REF and its tree has no PATH: a definite absence.

    A bare repo per REPO (git_cache), fetched once per ref per judgement (git_commit), so a read costs one ref fetch,
    one tree listing (git_tree_entries) and the blobs `git show` asks for, and no GitHub API quota at all. What PATH
    names is git_tree.GitTree's answer, the reader every other tree read uses (review of cmux#41314, F1, F2): a
    symlink is followed inside the tree, a symlinked parent too; a directory, a submodule, a binary blob (through a
    link or not), a link out of the tree and a loop are each Refused by name, never read as text or as absent."""
    commit = git_commit(repo, ref)
    if commit is None:
        return None
    module = git_tree()
    try:
        git = git_cache(repo)
        entries = git_tree_entries(repo, commit) if git is not None else None
    except (OSError, subprocess.SubprocessError):
        return None
    if entries is None:
        return None
    shown: dict[str, bytes] = {}

    def read_blob(where: str, oid: str) -> bytes:
        # The cache is a promisor clone: `git show` fetches the one blob it lacks (git_cache's partialclonefilter).
        if oid not in shown:
            try:
                done = git("show", f"{commit}:{where}")
            except (OSError, subprocess.SubprocessError) as why:
                raise module.NeedsFullTree(f"{repo}@{ref}: git show {where} failed: {why}") from None
            if done.returncode:
                raise module.NeedsFullTree(f"{repo}@{ref}: git show {where} failed")
            shown[oid] = done.stdout
        return shown[oid]

    tree = module.GitTree(source_cache() / (repo.replace("/", "__") + ".git"), commit, entries=entries,
                          read_blob=read_blob)
    try:
        if tree.resolve(path) is None:
            # REF's tree has no PATH: a definite absence for the path asked for, never for a link's target.
            parts = [part for part in path.strip("/").split("/") if part not in ("", ".")]
            linked = any(entries.get("/".join(parts[:at]), ("",))[0] == module.SYMLINK
                         for at in range(1, len(parts) + 1))
            return missing if missing is not None and not linked else None
        return tree.text(path)
    except module.NeedsFullTree:
        return None
    except module.Unreadable as why:
        raise Refused(f"{repo}@{ref}: {why}") from None
    finally:
        tree.close()


@once_per_judgement("source", lambda repo, ref, path, github: (repo, ref, path))
def source_text(repo: str, ref: str, path: str, github) -> str:
    """PATH's text in REPO at REF: git first (git_text, no API quota), then GitHub's GraphQL blob (GitHub.blob).
    Never the REST contents API, which an agent host's gh shim refuses as a source read (glaeda-gh's API-source
    guard): the classifier needs no override of that guard on any path."""
    text = git_text(repo, ref, path)
    if text is not None:
        return text
    return github.blob(repo, ref, path)


class _Absent:
    """git_text's answer for a path its fetched tree definitely lacks. read_once hands each caller a deep copy, so the
    marker copies to itself and stays comparable by identity."""

    def __copy__(self):
        return self

    def __deepcopy__(self, memo):
        return self


ABSENT = _Absent()


def source_text_if_present(repo: str, ref: str, path: str, github) -> str | None:
    """source_text, or None only when PATH is definitely absent at REF: git fetched REF and its tree has no PATH, or
    GitHub resolves REF and names nothing at PATH (GitHub.blob_if_present). Anything unread is Refused."""
    text = git_text(repo, ref, path, missing=ABSENT)
    if text is ABSENT:
        return None
    if text is not None:
        return text
    return github.blob_if_present(repo, ref, path)


_spec = importlib.util.spec_from_file_location("test_reds", Path(__file__).with_name("test_reds.py"))
test_reds = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(test_reds)
# Which step of a job printed each line of its log (step_owners) and the log without its passing steps' lines
# (failed_steps_log): one standard-library file, the source cmuxterm-hq and leo-workspace vendor whole.
_spec = importlib.util.spec_from_file_location("failed_steps_log", Path(__file__).with_name("failed_steps_log.py"))
steps_log = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(steps_log)

SETUP_STEPS = frozenset({"Set up job", "Set up runner"})
# Rollups: jobs that only report other jobs' results, judged by those jobs, never by themselves. Only which
# jobs are rollups is named here (workflow file, job id); the rest is derived from the workflows into
# ROLLUPS_FILE by `base_red_excuse.py --write-rollups` (derive_rollups): each rollup's check name (its
# `name:`), the jobs under it (its `needs:`, followed through their own `needs:`), and for a routed rollup
# (ci-guards.yml's Guard status) the route input each needed job runs on (its `if:`). The file is read with
# no YAML parser, so every host that runs this script reads the same contract; tests/test_base_red_excuse.py
# fails when it differs from the workflows. Anything in a workflow or in the file that does not have the
# expected shape is refused, never guessed at: a rollup red is then never excused.
# A run rollup is red when a job under it is red: the whole run's red jobs are judged. One in a called workflow names
# its caller (workflow file, job id), whose name is its check's prefix: ci-web.yml's Web status is 'web / Web status',
# red only when a web job under it is red, and was refused as "no failing test or error line to match" on every PR
# whose web shard red the base shares (2026-11-09, cmux#39559, hq#8503). ios-e2e.yml's ios-e2e-status is red when
# its backend or mac-ios-e2e job is (2026-11-15, cmux#41892: refused as "a summary red"; other_pr_setup_verdict).
RUN_ROLLUPS = (("ci.yml", "ci-status"), ("ci-web.yml", "web-status", ("ci.yml", "web")),
               ("ios-e2e.yml", "ios-e2e-status"))
ROUTED_ROLLUPS = (("ci-guards.yml", "guard-status"),)  # also reports each needed job's route (validate_guard_routes)
ROLLUPS_FILE = Path(__file__).with_name("base_red_rollups.json")
WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"
# The repo whose workflows sit beside this script: its contract is ROLLUPS_FILE.
HOME_REPO = "manaflow-ai/cmux"
# Rollups of the other repos this script judges (--repo), named the same way: (workflow file, job id). Their workflows
# are not in this checkout, so the contract is derived when a red is judged, from the repo's own workflow files at the
# base (derive_rollups over source_text: git, else GraphQL; load_rollups). A repo not named here has no rollups: every
# red job of it is judged as itself. cmuxterm-hq's Skill documentation tests only reports its shards (skills-tests.yml), and was
# refused on every HQ PR as "no failing test or error line to match" (2026-11-04: hq#7038, hq#7039).
OTHER_REPO_ROLLUPS = {
    "manaflow-ai/cmuxterm-hq": {"run": (("skills-tests.yml", "tests"),), "routed": ()},
}
# The repo whose base runs are another repo's base verdict of record (2026-11-21). A repo whose base pushes run no job
# has no verdict of its own to compare a red with: teamleaderleo/glaeda's ci.yml gates every job of its Verify
# workflow on `github.event_name == 'pull_request' || github.repository == 'manaflow-ai/glaeda'`, so a push to main
# there skips the whole workflow, and that file's own comment says the fork's Verify at a commit is "that commit's
# check of record in both repositories" (sync-main.yml keeps both mains at the same commits); scripts/glaeda-gh
# already reads a teamleaderleo/glaeda head's verdict that way. This script did not, so every red of every PR in that
# repo was refused as "'scripts': no main run of its workflow has a verdict for it to compare with": exit 1 for every
# red in the repo, which no push could ever change, and which the landing rules read as "no lander may merge and none
# may call the red base by judgment" (glaeda#2314 and #2320, 2026-11-21: main was red from 09:16Z to 09:53Z and two
# lanes each reproduced it by hand). Only the base runs, their job lists and those jobs' logs are read from the value;
# the head, the merge-base and the base's own commits stay the PR's repo, which holds the same main commits. A verdict
# whose run tested a commit the PR's repo does not have is older than the merge-base (before_merge_base) and refuses
# as before, so two mains that have drifted apart excuse nothing. The readings this skips are the ones no mapped repo
# can reach: guard_group (GUARD_GROUP_JOB, a cmux-next job name), journey (JOURNEY_WORKFLOWS paths), the web shard and
# gallery verdicts, and base_dispatch / base_caller (HOME_REPO-gated); each keeps the PR's repo, so a mapping for a
# repo that is not a cmux fork would have to thread them too.
BASE_VERDICT_REPO = {"teamleaderleo/glaeda": "manaflow-ai/glaeda"}
# A called workflow's base verdict, from the workflow that calls it on base pushes (2026-11-07). ci.yml runs on pull
# requests only; on feat-cmux-next the same ci-web.yml runs from cmux-next-web.yml's `web` job, under the same
# 'web / ...' check names. ci.yml's newest feat-cmux-next run was a 2026-10-06 dispatch, so every web shard red on a
# PR was judged against that month-old pass and refused as having no verdict at or after its merge-base (cmux#37667's
# 'web / Web tests (1/4)', red on the base in cmux-next web run 42358745538). Keyed by (the base branch, the PR run's
# workflow file, the caller job id whose '<id> / ' prefix the check carries), the value is the workflow file whose job
# of the same id calls the same reusable workflow on pushes to that base branch, and only that one: a PR into `main`
# never reads cmux-next web, whose runs on `main` (a dispatch) are no base evidence. tests/test_base_red_excuse.py
# checks each entry against the workflows. Its verdict is read only when the PR run's own workflow has none at or
# after the merge-base.
BASE_WORKFLOW_FOR = {("feat-cmux-next", "ci.yml", "web"): "cmux-next-web.yml"}
# A PR job whose base verdict is another workflow's job under another check name (2026-11-26). pr-router.yml's
# `pipeline` job calls pr-pipeline.yml, whose `linux` job runs ci/steps.toml's linux steps (`ci/run run --job linux`)
# as 'pr pipeline / linux'. Nothing runs pr-pipeline.yml on base pushes; the same linux steps run there as
# cmux-next-base-linux.yml's `linux` job, 'base linux', by the same `ci/run`, with the same log groups and test lines.
# Without this every base red of a linux step (tests/test_ci_no_single_size_pins.py, tests/test_ci_persisted_formats.py
# and scripts/measure/tests/nightly-fresh-launch-update-arm.test.py on 2026-11-26, PR run 45794762063) was refused
# as having no base verdict, on every PR at once. Keyed by (the base branch, the PR run's workflow file, the PR check),
# the value is (the base-push workflow file, its check). The comparison is the usual one, by failing test and error
# line: a red step the base run passed, or did not run, is never excused by it. Read after batch_check, before
# BASE_WORKFLOW_FOR, and like both only when the PR run's own workflow has no verdict at or after the merge-base;
# tests/test_base_red_excuse.py checks each entry against the workflows. The same holds for every step-table job of
# pr-pipeline.yml that runs on Linux: 'pr pipeline / web-browser' (`ci/run run --job web-browser`) had no base run at
# all for its step chat-flow-shift-budget, so its red on cmux#49399 and cmux#51550 (2026-11-26, PR run 45798346304
# and job 139823535345: 'compaction ends: stray 74.8px > 8px', the same line on both) was refused as having no base
# verdict; cmux-next-base-linux.yml now runs the web-browser job as its 'base web-browser' leg. The Mac and iOS jobs
# (ios, mac) have no such base leg yet and keep the refusal.
BASE_CHECK_FOR = {
    ("feat-cmux-next", "pr-router.yml", "pr pipeline / linux"): ("cmux-next-base-linux.yml", "base linux"),
    ("feat-cmux-next", "pr-router.yml", "pr pipeline / web-browser"): ("cmux-next-base-linux.yml", "base web-browser"),
}
# The post-merge batch tier (2026-11-21, cmux#48662): per-push base workflows move onto cmux-next-post-merge.yml,
# which every ~2 h calls each suite of .github/post-merge-batch.json whose paths changed, as a caller job named by the
# suite key, so the base's check of job J of suite S is 'S / J'. A workflow that moved there drops its own
# `push: feat-cmux-next`, so its own base runs go stale and every red on a PR was refused as having no verdict at or
# after its merge-base. batch_check maps a PR's red job to its batch check from the manifest alone, so a new suite is
# covered by its entry, with no change here: a run of the suite's own workflow (J is 'J' on the PR, 'S / J' on the
# base), or of a pull-request caller whose job calls the suite's workflow (ci.yml's `web` calls ci-web.yml: 'web / J'
# on the PR, 'S / J' on the base). Read before BASE_WORKFLOW_FOR, and like it only when the PR's own workflow has no
# verdict at or after the merge-base. A suite skipped in the newest batch run has no verdict there (base_verdicts
# passes it over for the previous batch run where it ran). The manifest is the one beside this script, else the
# base's (land-judge and the lane broker run a `git archive` of scripts/ci alone).
POST_MERGE_WORKFLOW = "cmux-next-post-merge.yml"
POST_MERGE_MANIFEST = ".github/post-merge-batch.json"
POST_MERGE_MANIFEST_FILE = WORKFLOWS.parent / "post-merge-batch.json"
POST_MERGE_BASES = frozenset({"feat-cmux-next"})
# A post-merge batch probe run (cmux-next-post-merge.yml's run-name 'probe <suite> <job> at <sha>') tests one job of
# an older commit while its head_sha is the tip it was dispatched from: never a base verdict for that tip.
POST_MERGE_PROBE_TITLE = "probe "
# A workflow no base push or schedule runs gets its base verdict from a dispatch on the base tip (2026-11-07).
# nightly-next-cua-signed-host.yml runs on pull requests that touch it and on a schedule, but a schedule fires only
# from the default branch, where the file was not yet registered, so feat-cmux-next never had a run of it: every red
# 'signed host admission' (cmux#37855 at 960fd459, cmux#27704) was refused as having no base verdict, and no change to
# that workflow could land. For a (base, workflow file) here, a missing or stale base verdict starts one dispatch of
# the workflow on the base tip, unless one is still running or one started within BASE_DISPATCH_EVERY; the judge
# then refuses, naming that run, and the next check after it completes compares against it as any base run. The run
# list is the record, so every host shares one dedupe and nothing waits here. A host whose gh cannot dispatch (a lane
# VM's broker) refuses with the reason; the next check from a host that can starts it. Keep this list to workflows
# whose base verdict cannot come from a push: each dispatch is a Mac job.
# cmux#37003 (b6fff4f6f105) deleted nightly-next-cua-signed-host.yml, so no workflow needs a base dispatch now; the
# mechanism stays for the next one (BaseDispatchForPullRequestOnlyWorkflows runs it with that entry).
BASE_DISPATCH: frozenset[tuple[str, str]] = frozenset()
BASE_DISPATCH_EVERY = timedelta(minutes=60)
ROUTE_IF = re.compile(r"\$\{\{ *inputs\.(\w+) *== *'true' *\}\}")
# A job a feat-cmux-next pull request runs as a ci/steps.toml step instead (pr-pipeline.yml): it skips only there, and
# its rollup counts that skip as fine, so it has no route input and every other run is judged as an unrouted job's.
STEP_TABLE_SKIP_IF = "${{ github.event_name != 'pull_request' || github.base_ref != 'feat-cmux-next' }}"
# A route report the Guard status prints: always read, even for a job the contract does not name (refused as unknown).
ROUTE_REPORT = r"workflow-guard-[\w-]+|linux_guard_\w+"
HOOK_REFUSAL = "glaeda-cmux-runner-hook: refused"
VERDICTS = frozenset({"success", "failure"})
# How far back the base lookup reads. A feat-cmux-next push skips swift-test, so its base verdict comes
# from the tip Swift suite (main's cmux-next-tip-swift-suite-dispatch.yml, about one run an hour), and
# DEV daily dispatches land between those runs every few minutes: on 2026-10-28, 16 of the base's 20
# newest completed runs were DEV daily runs, and the tip suite run fell out of a 20-run window, so
# no Swift red on any PR could be compared. One page of 100 runs reaches back hours; job listings
# are read newest first, at most BASE_JOB_READS per workflow, so a long run of runs with no verdict
# for the job stays bounded.
BASE_RUNS_PAGE = 100
BASE_JOB_READS = 40
# A run's job list carries every job's steps. GitHub answered the 34-job web run 41098664586's list with
# HTTP 502 at 100 and 50 per page, every time, and at 30 it answered (2026-10-30).
JOBS_PAGE = 30
# A job no feat-cmux-next push runs gets its base verdict from a dispatch: main's tip suite dispatcher
# (cmux-next-tip-swift-suite-dispatch.yml), cmux-next-base-tier-kick.yml (the base Mac tier, at most
# once every 15 minutes on the tip, cmuxterm-hq#5424), each a run named `<title><tested sha>`, or a hand
# dispatch. Base pushes land every minute or two, so the window above can miss them (2026-10-30: no
# daemon-test verdict on the base for hours, #27692). When it does, the base's newest completed dispatches
# are read too, newest first, and the first with a verdict for the job decides, a green one included: an
# older red never stands over a newer green. A suite that never runs the job (DEV daily runs, the other
# suites) is skipped unread, here and in the window above. At most TIP_SUITE_JOB_READS job lists; none of
# them with a verdict refuses as before.
CHECKS_JOB_NAME = "cmux-next checks (god files, concurrency, crash safety, l10n)"
SUITES = {
    # Every suite but the DEV daily also runs the checks job (cmux-next.yml checks' `if`), so naming it in one
    # suite means naming it in all of them: SUITE_JOBS skips a run whose suite does not list a job it lists.
    "cmux-next tip Swift suite · ": frozenset({"cmux-next swift test", CHECKS_JOB_NAME}),
    "cmux-next tip daemon suite · ": frozenset({"cmux-next daemon tests", CHECKS_JOB_NAME}),
    # cmux-next.yml base_tier: path routing's base_tier branch routes these, and nothing else. Its generated
    # files are checked on the generated-files job itself (path routing's generated_host), never folded. Since
    # 2026-11-22 it also carries the checks job, which a feat-cmux-next push no longer runs (workflow note-26).
    "cmux-next base tier · ": frozenset({
        "cmux-next daemon tests", "cmux-next generated files", "cmux app scheme compile (Debug)",
        "cmux-next crash ends the app", CHECKS_JOB_NAME,
    }),
    # cmux-next.yml dispatches that route neither swift-test nor daemon-test (path routing's dev_daily branch).
    "cmux NEXT DEV daily": frozenset(),
}
# The base-red window (2026-11-01): how many of the newest base verdicts for a job a head's failing test may have
# failed on. Only the newest decides whether the job is red on the base at all; the window only widens which
# failing tests count as the base's (see the module docstring). The tip Swift suite runs about every 1.5 to 2 hours
# and one page of BASE_RUNS_PAGE dispatches reaches back about 11 hours (DEV daily runs land about 9 an hour), so 5
# verdicts (about 8 to 10 hours of the suite) fit in that page with TIP_SUITE_JOB_READS to spare for a lost run.
# Older verdicts are read only when the newer ones leave a head test unexcused, one log each, and never one more
# than BASE_WINDOW_HOURS older than the newest.
BASE_WINDOW = 5
BASE_WINDOW_HOURS = 24
TIP_SUITE_JOB_READS = BASE_WINDOW + 2
# The jobs of the cmux-tui tree tiers (cmux_next_tree_notify.TIERS: daemon, scheme). A tip daemon suite or base tier
# dispatch whose tree has not published yet skips them and leaves them to the same-tree run its publish dispatches,
# which carries the same `<title><tested sha>` name. So a suite run with a newer run of the same name (queued,
# running or done) is that first run: it is skipped unread for these jobs and never spends a job-list read. On
# 2026-10-31 the base tier's six newest completed dispatches were all such first runs, and the tip daemon suite
# run with the verdict, behind them, was never read: no pull request's daemon-test red could be compared.
TREE_JOBS = frozenset({"cmux-next daemon tests", "cmux app scheme compile (Debug)", "cmux-next crash ends the app"})


def deferred_first_runs(runs: list[dict]) -> set[int]:
    """The ids of suite runs in RUNS (newest first) that have a newer run of the same name: first runs whose
    tree jobs went to that later same-tree run."""
    seen: set[str] = set()
    deferred: set[int] = set()
    for run in runs:
        title = run.get("display_title") or ""
        if not suite_jobs(run):
            continue
        if title in seen:
            deferred.add(run["id"])
        seen.add(title)
    return deferred


def suite_jobs(run: dict) -> frozenset[str] | None:
    """The jobs a base run's suite can carry, or None for a run of no known suite (a push, a hand dispatch)."""
    title = run.get("display_title") or ""
    return next((jobs for prefix, jobs in SUITES.items() if title.startswith(prefix)), None)


# The jobs some suite above is the base verdict for. Only these are ever skipped: every other job (checks,
# web bundles, the placement jobs) may run in any suite, so a suite run's verdict for it always counts.
SUITE_JOBS = frozenset().union(*SUITES.values())


# A cancelled base tier run is one the base tier kick found superseded with no Mac job in progress
# (cmux_next_base_tier.py cancel_superseded): read here it mostly spends the lookup limits that reach the run
# with a verdict. But since 2026-11-09 (cmux#39631) the kick also cancels a run whose daemon tests or generated
# files finished while its scheme compile still queued, so for those jobs (CANCELLED_TIER_VERDICT_JOBS) such a run
# can hold the newest verdict: a green there must stand over an older red. For them a cancelled base tier run is
# read only when its check suite shows a verdict for the job (or cannot be read), and one with none is passed
# over without spending a job-list read (cancelled_tier_without_verdict). For every other job it has none.
BASE_TIER_TITLE = "cmux-next base tier · "
# The checks job is a Linux job too, so a cancel that waited only on the Mac jobs can leave its verdict behind.
CANCELLED_TIER_VERDICT_JOBS = frozenset({
    "cmux-next daemon tests", "cmux-next generated files", CHECKS_JOB_NAME,
})


def cancelled_base_tier(run: dict) -> bool:
    return run.get("conclusion") == "cancelled" and (run.get("display_title") or "").startswith(BASE_TIER_TITLE)


def never_carries(run: dict, name: str) -> bool:
    """Whether RUN's suite never runs job NAME, so it has no verdict for it to read."""
    if cancelled_base_tier(run) and name not in CANCELLED_TIER_VERDICT_JOBS:
        return True
    jobs = suite_jobs(run)
    return name in SUITE_JOBS and jobs is not None and name not in jobs


def tested_sha(run: dict) -> str:
    """The commit a cmux-next.yml run tested: the sha its name ends in (a same-tree run tests it after the
    branch moved on), else its head_sha."""
    match = re.search(r" · ([0-9a-f]{40})$", run.get("display_title") or "")
    return match.group(1) if match else str(run.get("head_sha") or "")


ANSI = test_reds.ANSI  # one pattern for every reader
ERROR = re.compile(r"##\[error\]|\berror:")
WARNING = re.compile(r"##\[warning\]|\bwarning:")
# A job whose own script says its one red on a line of its own, not an annotation: that line is its error line.
# scripts/ci/cua_signed_host_check.py ends a red run with `FAIL: <why>` and then only the runner's generic exit-code
# annotation, so 'signed host admission' had no error line to compare, and its base red on cmux#37855 (the same
# "signed app pid N never kept an accepted host connection" on base run 42383535506) could not be matched.
# cmuxterm-hq's 'Skill policy tests' runs shell tests that end a red the same way (`FAIL: plist content`, hq#9249's
# LaunchAgent step): with no line of its own to compare, its inherited red had nothing to match on any base.
JOB_ERROR = {"signed host admission": re.compile(r"^FAIL: "), "Skill policy tests": re.compile(r"^FAIL: ")}
# A shell check's own `FAIL: <what>` line (cmuxterm-hq's tests/*.sh: hq#9191's "Skill policy tests" failed only
# `FAIL: plist content` in its LaunchAgent step), counted by the whole-log comparison (unplaced_signature) of any job,
# so a second `FAIL:` line is a new failure there. A placed comparison keys it for JOB_ERROR's jobs alone (a `FAIL:`
# line is no error line for another job's step_errors); a placed red with nothing else to compare is compared whole.
# A unittest's `FAIL: test (module.Class)` is a failing test (test_reds), not this.
SHELL_FAIL = re.compile(r"^FAIL: (?!\w+ \([\w.]+\)$)\S")
# Release-notary helpers report successful validations as `ok: ... (error: ...)`.
# The parenthesized diagnostic is expected output, not a failed check; only
# error annotations outside a successful `ok:` wrapper are evidence.
SUCCESS_DIAGNOSTIC = re.compile(r"^\s*ok:\s+.*\berror:", re.IGNORECASE)
# Summaries carry counts, and a test's own lines already name it.
GENERIC = re.compile(r"Process completed with exit code|red tests?:|✘ Test |Test Case '|\.\.\. FAILED$")
# A line a known-benign emitter printed from a step that did not fail. Every error line in a log is charged to the
# side that printed it, so such a line refuses a red the base is failing too, and the first one in the log pre-empts
# the failure a parser can name. 2026-11-22, cmuxterm-hq eb73df0c's 'go vet + go test' (job 137452468531):
# actions/checkout narrowed a sparse checkout in a reused self-hosted workspace and printed 54
# `##[error]error: Path '<path>' not uptodate; will not remove from working tree.` lines at 02:37:42, its step green;
# the job then ran five more minutes and ended in `FAIL\tcmuxterm-hq/build-fleet/cmd/controller`. Those 54 paths are
# the workspace's history, not the change's, so no base run prints the same ones and the Go failure main was failing
# too could not be matched. git says this while narrowing a checkout and removes the path anyway. Only an emitter's
# own known-benign line is exempt; any other error line, annotated or not, still counts.
BENIGN = re.compile(r"^(?:##\[error\]|::error[^:]*::)?\s*error: .*\bnot uptodate; will not remove from working "
                    r"tree\.?$")
SUMMARY_FAILURE = re.compile(
    r"(?i)\b(?:changed|stale|missing|mismatch|not stamped|not found|out of date|invalid|unavailable|"
    r"cannot|could not|failure|failed|fail|does not match|not match)\b"
)
STAMP = steps_log.STAMP
# SwiftPM's line for a killed test helper, and the hang sampler's ::error lines for it.
CRASH = re.compile(r"exited with unexpected signal code (\d+)|the test helper died on signal (\d+)")
CRASH_LINE = re.compile(r"exited with unexpected signal code|the test helper died on signal|"
                        r"no \"Test run with\" summary line")
# A commit sha inside an error line: a full 40-hex sha, or 7 to 39 hex digits right after a word that
# names a commit (commit, sha, tree, revision). The same red on the head and the base names each run's
# own commit; any other hex id (an artifact, a hash) is compared as it is. A full 40-hex id right after
# a word that names a stored thing rather than a commit (ARTIFACT) is such an id: two different digests
# stayed one error line while every bare 40-hex token was masked, so a real red could pass as a base red
# (cmux#35902, from the review of #35893). A commit the line does not name as an artifact still masks,
# whatever word introduces it: a base red often names each run's own tree or stamp with no keyword at
# all ("source stamp <40-hex> != <40-hex>"), which is why the bare case cannot ask for one.
ARTIFACT = r"(?i:artifacts?|artefacts?|assets?|digests?|checksums?|hashe?s?|packs?|bundles?|archives?|images?|layers?)"
# What may stand between such a word and its id: spaces, one `:` or `=`, and an opening quote or bracket
# (`artifact: <40-hex>`, `checksum=<40-hex>`, `digest (<40-hex>)`), which the literal space alone missed
# (cmux#35941 F1); or an opening quote or bracket on its own, with no space or `:` before it
# (`artifact(<40-hex>)`, `pack"<40-hex>"`, `bundle[<40-hex>]`), which still fell to the bare branch
# (cmux#35941 F3). A separator of some kind is always required, so a bare 40-hex still masks.
NAMED = r"(?:(?:[ \t]+|[ \t]*[:=][ \t]*)[(\[`'\"]?|[(\[`'\"])"
SHA = re.compile(rf"(?P<artifact>\b{ARTIFACT}{NAMED}[0-9a-f]{{40}}\b)"
                 r"|\b[0-9a-f]{40}\b"
                 r"|\b(?P<commit>(?:commit|sha|tree|revision) `?)[0-9a-f]{7,39}\b")
# A compile check that gave no verdict (the build-fleet controller unreachable, timed out, or a result
# for another head): nothing compiled the head, so it is never a base red, whatever the base shows
# (2026-10-28: the fleet Release compile's "no result" was red on PRs and on the base alike while the
# controller was wedged). It is set aside only when another job compiled that same head: COMPILE_PASSES.
# Only the job's own ::error annotation counts (`##[error]` at the start of the line): the log also
# echoes the step's script, which spells these words out on every run, a real compile red included.
# Fail closed: of compile-status's own lines, only "(fail)" is a real compile red; every other state (no result,
# unavailable, mismatch, unreadable, pending, "last: ...", a pass it could not post) and a status it could not
# post at all (GitHub refused it: 2026-11-11 02:38Z, a 403 rate limit on cmux-bot reddened #40351, #40942, #41007
# and the base) are no verdict.
NO_VERDICT = re.compile(r"^##\[error\]\s*(?:cmux-next/compile is not a pass for \S+ \((?!fail\))|"
                        r"could not post the (?:pending|handoff|overflow handoff) status|"
                        r"bad head sha |No build-fleet verdict for `)")
# The jobs that can end without a verdict: an unreadable log of one is never comparable either.
NO_VERDICT_JOBS = frozenset({"cmux-next fleet Release compile", "cmux-next app compile (build fleet)"})
# The shared generated-files check only reads the verdict produced by the Swift, daemon or fast tier job that built
# the package.  A failed prerequisite (especially a cancelled-before-start runner job) leaves that value
# empty, so this check has no result of its own.  It must be rerun together with its host job; comparing its
# fail-closed diagnostic with the base would turn missing evidence into an apparent PR red.
GENERATED_VERDICT_JOB = "cmux-next generated files (shared build)"
GENERATED_NO_VERDICT = re.compile(
    r"^##\[error\]\s*(?:swift-test|daemon-test|fast-tier) \(cancelled\) gave no generated files verdict:"
)
# A summary gate whose dependencies judged nothing (cancelled, abandoned, skipped though required, an empty result)
# says so in one annotation that starts "no verdict: " (scripts/ci/needs_verdict.py, NO_VERDICT_PREFIX). It ends red
# so it never reads as a pass, but it is never the pull request's own red and never a base red: it gets re-run.
# 2026-11-09: #39791's `rust workspaces` summary read `plan: abandoned` as a red, compared it with a green base and
# refused the merge as the pull request's own. Only the live annotation counts (test_reds.lines_of drops the echoed
# script, which spells the same words).
SUMMARY_NO_VERDICT = re.compile(r"^##\[error\]\s*no verdict: ")
# The same rule's red: `summary red: <what>: <job>: failure; ...`. It names which needs failed, in words every summary
# shares, so it is never a signature, an error to compare or evidence of any kind (signature drops it): two summaries
# match on it whichever children failed (cmux#39857 review, 2026-11-09: rust workspaces failing crate-a on the head
# was excused by a base failing crate-b). A summary red is refused with "compare its failed children" unless its
# children are compared one by one, as Guard status's are (validate_guard_routes).
SUMMARY_RED = re.compile(r"^##\[error\]\s*summary red: ")
# A real compile pass at the head: the Mac Release compile (a check run), or the fleet's cmux-next/compile
# commit status.
COMPILE_PASS_CHECKS = ("cmux-next Release compile (Xcode 26)",)
COMPILE_PASS_STATUS = "cmux-next/compile"
# Who may post it. A commit status is trusted only by who posted it: anyone who can write statuses on this repository
# can post one by this name, so its name and state alone are no evidence. Two jobs post it, both with the cmux-bot App's
# token: cmux-next.yml's compile-status (the fleet's controller verdict) and the compile check's fallback poster, which
# turns a compile made off the controller into this status only after it has checked that run's own job metadata
# (exact commit, recipe 2, `--app --release`, a successful run of the default branch). A status by anyone else, a
# person's token included, is not a compile verdict (2026-11-10: with the office Macs and the controller down, the
# fallback poster was the only compile verdict a held PR could get, so the gate must tell it from a look-alike).
# The build fleet's controller posts it too, as the manaflow-checks App (the statuses: write App the pool's required
# checks already post from), on each pull request head whose compile it runs: the same verdict compile-status relayed,
# without a runner held through the compile (cmuxterm-hq build-fleet/cmd/controller/compile_status_poster.go). Both
# are trusted; the newest status either of them made decides.
COMPILE_STATUS_POSTER = {"login": "cmux-bot[bot]", "id": 348531757, "type": "Bot"}
COMPILE_STATUS_CONTROLLER_POSTER = {"login": "manaflow-checks[bot]", "id": 342447321, "type": "Bot"}
COMPILE_STATUS_POSTERS = (COMPILE_STATUS_POSTER, COMPILE_STATUS_CONTROLLER_POSTER)
# The Mac Release compile's steps that compile (or reuse a pass for the same inputs).
COMPILE_STEPS = frozenset({"Release compile", "Reuse that pass"})


# A matrix job named '<name> (${{ matrix.<key> }})' (ci-web.yml's Web tests): its jobs are '<name> (<value>)'.
MATRIX_NAME = re.compile(r"([^$]*[^$ ]) \(\$\{\{ *matrix\.(\w+) *\}\}\)")


def _check_matcher(job_id: str, job: dict, where: str) -> dict:
    """How the Actions jobs of JOB (id JOB_ID in a workflow) are named: {"exact": [...], "prefixes": [...]}. A job
    with no `name:` is named by its id; a called workflow's jobs are '<name> / <its job>'; a matrix job whose
    name holds no expression gets ' (<values>)' after it, as does one named over a computed include; a name may hold an expression only as a last
    ' / ${{ ... }}' segment. Any other shape is refused."""
    name = job.get("name", job_id)
    if not isinstance(name, str) or not name.strip() or name != name.strip():
        raise Refused(f"{where}: job {job_id} has no usable name")
    if "${{" in name and (one := MATRIX_NAME.fullmatch(name)):
        # 'Web tests (${{ matrix.shard }})': one name per value of that one matrix key, as Actions renders it.
        matrix = (job.get("strategy") or {}).get("matrix")
        key = one.group(2)
        values = None
        if isinstance(matrix, dict) and set(matrix) == {key} and isinstance(matrix[key], list):
            values = matrix[key]
        elif (isinstance(matrix, dict) and set(matrix) == {"include"} and isinstance(matrix["include"], list)
              and all(isinstance(row, dict) and key in row for row in matrix["include"])):
            values = [row[key] for row in matrix["include"]]
        elif (isinstance(matrix, dict) and set(matrix) == {"include"} and isinstance(matrix["include"], str)
              and matrix["include"].strip().startswith("${{") and "uses" not in job):
            # A computed include ('react-apps-check (${{ matrix.shard }})' over the shards a pull request reaches,
            # #48561): its values are known only at run time, but Actions still names each job '<name> (<value>)'.
            return {"exact": [], "prefixes": [f"{one.group(1)} ("]}
        if (not values or "uses" in job
                or not all(isinstance(v, (str, int)) and not isinstance(v, bool) and str(v) for v in values)):
            raise Refused(f"{where}: job {job_id}'s name {name!r} is not one matrix key over fixed values")
        return {"exact": [f"{one.group(1)} ({v})" for v in values], "prefixes": []}
    if "${{" in name:
        static, sep, expr = name.partition(" / ${{")
        if not sep or "${{" in static or not expr.endswith("}}") or "${{" in expr or "uses" in job:
            raise Refused(f"{where}: job {job_id}'s name {name!r} is not a fixed name with one last ' / ${{{{ }}}}' part")
        return {"exact": [], "prefixes": [static + " / "]}
    if "uses" in job:
        if (job.get("strategy") or {}).get("matrix"):
            raise Refused(f"{where}: job {job_id} calls a workflow over a matrix")
        return {"exact": [], "prefixes": [name + " / "]}
    if (job.get("strategy") or {}).get("matrix"):
        return {"exact": [name], "prefixes": [name + " ("]}
    return {"exact": [name], "prefixes": []}


def _needs(jobs: dict, job_id: str, where: str) -> list[str]:
    needs = jobs[job_id].get("needs", [])
    needs = [needs] if isinstance(needs, str) else needs
    if not isinstance(needs, list) or not all(isinstance(n, str) and isinstance(jobs.get(n), dict) for n in needs):
        raise Refused(f"{where}: job {job_id}'s needs {needs!r} are not jobs of its workflow")
    return needs


# PyYAML 6.0.3's pure-Python lib/yaml, unmodified (sdist sha256 d76623373421df22fb4cf8817020cbb7ef15c725b9d5e45f17e189bfc384190f,
# MIT, its LICENSE beside it): the YAML reader where the interpreter has no PyYAML. land-judge runs this script as
# `python3 -I` under Homebrew's Python on the Mac that lands PRs, which has none, and every cmuxterm-hq rollup red
# was refused there with "no YAML parser" (2026-11-07, hq#7398).
VENDORED_YAML = Path(__file__).resolve().with_name("_vendor")


def yaml_module():
    """PyYAML: the interpreter's own, else the vendored copy (VENDORED_YAML). Refused when neither imports."""
    try:
        import yaml  # noqa: PLC0415 - only deriving reads YAML; judging this repo reads ROLLUPS_FILE
        return yaml
    except ImportError:
        pass
    if (VENDORED_YAML / "yaml" / "__init__.py").is_file():
        if str(VENDORED_YAML) not in sys.path:
            sys.path.append(str(VENDORED_YAML))
        try:
            import yaml  # noqa: PLC0415
            return yaml
        except ImportError:
            pass
    raise Refused("no YAML parser to read the workflows' rollups; no rollup red is excused")


def derive_rollups(workflows: Path = WORKFLOWS, *, run=RUN_ROLLUPS, routed=ROUTED_ROLLUPS, read=None) -> dict:
    """The rollups contract (ROLLUPS_FILE) derived from the workflow files; refuses any shape it does not know.
    RUN and ROUTED name the rollups (another repo's, OTHER_REPO_ROLLUPS); READ(file) gives a workflow's text when it
    is not under WORKFLOWS (another repo's, at its base)."""
    yaml = yaml_module()
    if read is None:
        def read(file: str) -> str:
            return (workflows / file).read_text()
    out: dict = {"run": {}, "routed": {}}
    for kind, declared in (("run", run), ("routed", routed)):
        for file, job_id, *caller in declared:
            where = f".github/workflows/{file}"
            doc, jobs = _workflow(yaml, read, file)
            if not isinstance(jobs.get(job_id), dict):
                raise Refused(f"{where}: no job {job_id}")
            check = _check_matcher(job_id, jobs[job_id], where)
            if check["prefixes"] or len(check["exact"]) != 1:
                raise Refused(f"{where}: rollup {job_id} has no fixed name")
            prefix = ""
            if caller:
                # A called workflow's jobs are '<its caller's name> / <job>' (_check_matcher of the caller job).
                (caller_file, caller_id), = caller
                caller_where = f".github/workflows/{caller_file}"
                caller_job = _workflow(yaml, read, caller_file)[1].get(caller_id)
                if not isinstance(caller_job, dict) or caller_job.get("uses") != f"./{where}":
                    raise Refused(f"{caller_where}: no job {caller_id} calling {where}")
                prefix = _check_matcher(caller_id, caller_job, caller_where)["prefixes"][0]
            name = prefix + check["exact"][0]
            if name in out["run"] or name in out["routed"]:
                raise Refused(f"{where}: two rollups are named {name!r}")
            needs = _needs(jobs, job_id, where)
            if not needs:
                raise Refused(f"{where}: rollup {job_id} needs no job")
            if kind == "run":
                under, todo = {}, list(needs)
                while todo:
                    need = todo.pop()
                    if need not in under:
                        matcher = _check_matcher(need, jobs[need], where)
                        under[need] = {kind_: [prefix + v for v in matcher[kind_]] for kind_ in ("exact", "prefixes")}
                        todo.extend(_needs(jobs, need, where))
                out["run"][name] = {"workflow": file, "job": job_id, "under": dict(sorted(under.items())),
                                    "reports": _needs_steps(jobs[job_id], where)}
                continue
            triggers = doc.get(True, doc.get("on"))
            inputs = (triggers.get("workflow_call") or {}).get("inputs") if isinstance(triggers, dict) else None
            if not isinstance(triggers, dict) or set(triggers) != {"workflow_call"} or not isinstance(inputs, dict):
                raise Refused(f"{where}: a routed rollup's workflow must be called only, with inputs")
            routes = {}
            for need in needs:
                condition = jobs[need].get("if")
                route = None
                if condition is not None and not (isinstance(condition, str) and condition.strip() == STEP_TABLE_SKIP_IF):
                    match = ROUTE_IF.fullmatch(condition.strip()) if isinstance(condition, str) else None
                    if match is None or match.group(1) not in inputs:
                        raise Refused(f"{where}: job {need}'s if {condition!r} is not one route input == 'true'")
                    route = match.group(1)
                routes[need] = {"route": route, **_check_matcher(need, jobs[need], where)}
            out["routed"][name] = {"workflow": file, "job": job_id, "routes": routes}
    return out


# A step reads its job's needs when an expression in it (`${{ ... }}`) names `needs` (`${{ toJSON(needs) }}`,
# `${{ needs.x.result }}`). Each expression is cut out with str.split, so the read stays linear in the step's text.
NEEDS_WORD = re.compile(r"(?<![\w.-])needs\b")  # the context itself: never `steps.needs-x` or `inputs.needs`


def _reads_needs(text: str) -> bool:
    """Whether an expression `${{ ... }}` in TEXT names `needs`."""
    return any(NEEDS_WORD.search(part.split("}}", 1)[0]) for part in text.split("${{")[1:])


def _needs_steps(job: dict, where: str) -> list[str]:
    """The names of rollup JOB's steps that read its needs (_reads_needs of anything but the step's name and `if:`): the
    only steps whose failure is the needs' (run_rollup_line). A step with no `name:` is left out, so its failure is
    the rollup's own, and so is one that only names `needs` in its `if:` (a check of its own that runs on a need's
    result)."""
    steps = job.get("steps")
    if not isinstance(steps, list) or not all(isinstance(step, dict) for step in steps):
        raise Refused(f"{where}: a rollup's steps are not a list of steps")
    named = [(step.get("name"), step) for step in steps]  # step-name: classify
    return sorted({name for name, step in named if isinstance(name, str) and name.strip()
                   and _reads_needs(json.dumps({k: v for k, v in step.items() if k not in ("name", "if")}, default=str))})


def _workflow(yaml, read, file: str) -> tuple[dict, dict]:
    """Workflow FILE (READ gives its text) and its `jobs:`; refused when unreadable or of another shape."""
    where = f".github/workflows/{file}"
    try:
        doc = yaml.safe_load(read(file))
    except (OSError, Refused, yaml.YAMLError) as error:
        raise Refused(f"{where}: unreadable ({error})") from None
    jobs = doc.get("jobs") if isinstance(doc, dict) else None
    if not isinstance(jobs, dict):
        raise Refused(f"{where}: no jobs")
    return doc, jobs


def _matcher_ok(matcher: object) -> bool:
    return (isinstance(matcher, dict) and set(matcher) >= {"exact", "prefixes"}
            and all(isinstance(matcher[k], list) and all(isinstance(v, str) and v for v in matcher[k])
                    for k in ("exact", "prefixes")))


_ROLLUPS: dict | None = None
# Other repos' contracts, derived by load_rollups: {repo: contract}.
_REPO_ROLLUPS: dict[str, dict] = {}
NO_ROLLUPS = {"run": {}, "routed": {}}


def load_rollups(repo: str, base: str, github) -> None:
    """Derive REPO's rollups contract from its own workflow files at BASE, once. HOME_REPO's is ROLLUPS_FILE."""
    if repo == HOME_REPO or repo in _REPO_ROLLUPS or repo not in OTHER_REPO_ROLLUPS:
        return
    declared = OTHER_REPO_ROLLUPS[repo]

    def read(file: str) -> str:
        return source_text(repo, base, f".github/workflows/{file}", github)

    try:
        _REPO_ROLLUPS[repo] = derive_rollups(run=declared["run"], routed=declared["routed"], read=read)
    except Refused as error:
        raise Refused(f"{repo} rollups at {base}: {error}; no rollup red is excused") from None


def rollups(repo: str = HOME_REPO) -> dict:
    """REPO's rollups contract. HOME_REPO's is ROLLUPS_FILE, checked for shape; refused (so no rollup red is
    excused) when missing or malformed. Another repo's is the one load_rollups derived (refused when it has not), and a
    repo with no rollups named in OTHER_REPO_ROLLUPS has none."""
    if repo != HOME_REPO:
        if repo not in OTHER_REPO_ROLLUPS:
            return NO_ROLLUPS
        if repo not in _REPO_ROLLUPS:
            raise Refused(f"{repo}: its rollups were not read from its workflows; no rollup red is excused")
        return _REPO_ROLLUPS[repo]
    global _ROLLUPS
    if _ROLLUPS is None:
        try:
            data = json.loads(ROLLUPS_FILE.read_text())
        except (OSError, ValueError) as error:
            raise Refused(f"{ROLLUPS_FILE.name}: unreadable ({error}); no rollup red is excused") from None
        run, routed = (data.get("run"), data.get("routed")) if isinstance(data, dict) else (None, None)
        ok = (isinstance(run, dict) and isinstance(routed, dict) and run and routed
              and all(isinstance(r, dict) and isinstance(r.get("under"), dict) and r["under"]
                      and all(_matcher_ok(m) for m in r["under"].values())
                      and isinstance(r.get("reports"), list) and all(isinstance(n, str) and n for n in r["reports"])
                      for r in run.values())
              and all(isinstance(r, dict) and isinstance(r.get("routes"), dict) and r["routes"]
                      and all(_matcher_ok(m) and (m.get("route") is None or isinstance(m.get("route"), str))
                              for m in r["routes"].values()) for r in routed.values()))
        if not ok:
            raise Refused(f"{ROLLUPS_FILE.name}: not a rollups contract; no rollup red is excused")
        _ROLLUPS = data
    return _ROLLUPS


def matches(matcher: dict, name: str, prefix: str = "") -> bool:
    """Whether Actions job NAME is one of the jobs MATCHER names, under a caller's PREFIX ('guards / ')."""
    return (any(name == prefix + exact for exact in matcher["exact"])
            or any(name.startswith(prefix + start) for start in matcher["prefixes"]))


def routed_rollup(name: str, repo: str = HOME_REPO) -> tuple[dict, str] | None:
    """(the routed rollup check NAME is, the caller prefix it runs under), or None. A routed rollup's workflow is
    only ever called, so its check is '<caller> / <name>' (a bare name is still one, with no prefix)."""
    for rollup, contract in rollups(repo)["routed"].items():
        if name == rollup or name.endswith(" / " + rollup):
            return contract, name[:-len(rollup)]
    return None


def is_aggregate(name: str, repo: str = HOME_REPO) -> bool:
    """Whether a check of REPO reports other jobs rather than running work itself."""
    return name in rollups(repo)["run"] or routed_rollup(name, repo) is not None


def _sub_shas(text: str, keep: list | None = None) -> str:
    """TEXT with its commit shas masked (SHA). With KEEP, each id the pattern preserves is set aside there and
    left as a marker of letters alone, so a later pass over TEXT's numbers cannot touch its digits."""
    def masked(match: re.Match[str]) -> str:
        if (named := match.group("artifact")) is not None:
            if keep is None:
                return named
            keep.append(named)
            return _marker(len(keep) - 1)
        return (match.group("commit") or "") + "<sha>"

    return SHA.sub(masked, text)


def _marker(index: int) -> str:
    """A placeholder for the id at INDEX of a keep list: letters between two NULs, so no number masking,
    and nothing test_reds.volatile rewrites, is in it."""
    letters = ""
    index += 1
    while index:
        index, rest = divmod(index - 1, 26)
        letters = chr(ord("a") + rest) + letters
    return f"\0{letters}\0"


MARKER = re.compile("\0([a-z]+)\0")


def _marker_index(letters: str) -> int:
    """The keep-list index _marker wrote as LETTERS."""
    index = 0
    for letter in letters:
        index = index * 26 + ord(letter) - ord("a") + 1
    return index - 1


def mask_shas(text: str) -> str:
    """TEXT with its commit shas masked, leaving every other hex id as it is (SHA)."""
    return _sub_shas(text)


# A file's name in an error line, after its directories: a name with an extension that starts with a letter (so a time
# or a version is never one), ending a whole path component: no name character, slash or name-continuing dot after it
# ("run123.build" inside "run123.build-extra/" is a directory's prefix, not a file: Codex on #41172, F1). Only the name
# keeps its digits; a directory may be a run's own (DerivedData's hashed folder), so its digits are masked as before.
FILE_NAME = re.compile(r"(?:(?<=/)|(?<![\w/.+-]))[\w+-][\w.+-]*\.[A-Za-z][A-Za-z0-9]*(?![\w+/-]|\.[\w/])")


def normalise_error(text: str) -> str:
    """An error line as compared with the base's: the annotation prefix dropped, commit shas, run-to-run tokens
    (test_reds.volatile: run-named temp dirs, the runner's checkout root, times) and then
    every number masked, so the same red on two runs is one line and a different red is not. An id mask_shas
    preserves keeps its digits: they are the whole of what tells two digests apart (cmux#35941 F2)."""
    kept: list = []
    said = _sub_shas(text.replace("##[error]", "").strip(), keep=kept)
    said = test_reds.volatile(said)

    def keep_path(match: re.Match[str]) -> str:
        kept.append(match[0])
        return _marker(len(kept) - 1)
    # A file's name keeps its digits: tests/test_1.py is not tests/test_2.py, nor Sources/A1.swift Sources/A2.swift
    # (an excuse key that drops identity: a finding on one file matched a finding on another). Its line number,
    # after the colon, is still masked.
    said = FILE_NAME.sub(keep_path, said)
    said = re.sub(r"\d+", "#", said)
    # Each marker back to its id in one pass (a replace per id read the whole line once per path on it: a PR's line
    # of N paths took N^2, PrLogReadersScale).
    def restore(match: re.Match[str]) -> str:
        index = _marker_index(match[1])
        return kept[index] if index < len(kept) else match[0]
    return MARKER.sub(restore, said) if kept else said


# failed_steps_log.py's, used here as they are (never a copy): the reader of a log's lines and their steps.
lines_of, STEP_START, _stamp_time = steps_log.lines_of, steps_log.STEP_START, steps_log._stamp_time
FAILED, ERRORED, PASSED, AMBIGUOUS = steps_log.FAILED, steps_log.ERRORED, steps_log.PASSED, steps_log.AMBIGUOUS
SECTION_RED, STEP_OWNERS_MAX_LINES = steps_log.SECTION_RED, steps_log.STEP_OWNERS_MAX_LINES
StepNamesUnknown, STEP_NAMES_UNKNOWN = steps_log.StepNamesUnknown, steps_log.STEP_NAMES_UNKNOWN
step_owners, failed_steps_log = steps_log.step_owners, steps_log.failed_steps_log
ALIGN_MAX_STARTS, _one_to_one_starts, _aligned_starts = (steps_log.ALIGN_MAX_STARTS, steps_log._one_to_one_starts,
                                                         steps_log._aligned_starts)
_live_red, _line_time = steps_log._live_red, steps_log._line_time


class FailedView:
    """failed_view's answer for a placed log: the sections of JOB's failed steps, in log order, as (the index of the
    step in STEPS, its status, its raw lines), and nothing a passing step printed. A head's view (BASE false) keeps
    its FAILED and ERRORED sections, everything that may be its red; a base's keeps its FAILED ones, everything that
    may be base evidence, and the ERRORED ones its own failed rollup names red (rollup_vouched); any other ERRORED
    section is a continue-on-error step's: shown, never evidence. TEXT is the one way any comparator reads a log's
    lines."""
    __slots__ = ("job", "base", "steps", "sections", "_text")

    def __init__(self, job: dict, base: bool, steps: list[dict], sections: list[tuple[int, str, list[str]]]):
        self.job, self.base, self.steps, self.sections = job, base, steps, sections
        # Built once: every comparator reads a view's text, several times a judgment. Rebuilt per read, each read made
        # and freed two copies of a long log (the sections' join, then Steps' own), which glibc hands back to the OS
        # and faults in again above its trim threshold: view_text read 15x at 4x a HostileLog (PrLogReadersScale), 4x
        # with that threshold raised. The sections are never changed after a view is made.
        self._text = test_reds.Steps(["\n".join(lines) for _, _, lines in sections])

    def text(self) -> str:
        """Its sections' lines, as a test_reds.Steps: every reader of it reads each section as the failed step it was
        placed as, never splitting the text by its echoes and judging pass or fail again (#41329's review follow-up
        F3)."""
        return self._text

    def failed_text(self) -> str:
        """text() of its FAILED sections alone: all a base's view keeps, so a head's count of a failing test is
        compared like for like with a base's (compare_window); a base view's is its text()."""
        if self.base:
            return self._text
        return test_reds.Steps(["\n".join(lines) for _, status, lines in self.sections if status == FAILED])

    def lines(self) -> list[tuple[str, int]]:
        """(raw line, the index of its step in STEPS) for each line of the view."""
        return [(line, k) for k, _, lines in self.sections for line in lines]

    def __repr__(self) -> str:
        return f"FailedView({'base' if self.base else 'head'}, {[(k, status) for k, status, _ in self.sections]})"


def failed_view(job: dict, log: str, *, step_names, base: bool) -> "FailedView | Unplaced":
    """The one reader of a job log for every comparator, head and base alike (signature, step_errors, compare_window,
    crash_signals, the panic ratchet, the package, guard and quarantine rules, next_batch's expand_job): LOG's
    sections step_owners places that are not PASSED (FailedView), or UNPLACED when any line of it is AMBIGUOUS. No
    comparator reads a raw log or calls step_owners itself (tests/test_base_red_excuse.py's FailedViewIsTheOnlyReader
    scans for both): #40542's seventh Codex BLOCK, F1, at 35f63387, was signature() reading a head's failing tests
    from its whole log while a base's came from its failed sections alone, so a passing negative-case step's
    `✘ Test fake()` matched the base's real fake() failure and compare_window excused an unrelated new error in the
    step that failed. An empty log is placed and has no section. STEP_NAMES: step_owners'. BASE, keyword-only with no
    default, is the log's role, which every caller names: True for a base's log (evidence: FAILED sections and the
    ERRORED ones its failed rollup names red, rollup_vouched, or its failed gated step needed to fail, gate_vouched),
    False for the head's or a stack's (its red: FAILED and ERRORED). The test scan (FailedViewIsTheOnlyReader) checks
    each caller's role against where its log came from: the follow-up to #40542's Codex F1 at 8dc7e0dc, where
    next_batch read its base runs with the head's default role, so a base's ERRORED continue-on-error section was
    base evidence and next-batch said "no new failures" for a red judge() refuses."""
    if not log.strip():
        return FailedView(job, base, [], [])
    owned = step_owners(job, log, step_names=step_names)
    if any(status == AMBIGUOUS for _, _, status in owned):
        return UNPLACED
    steps = [step for step in job.get("steps") or [] if step.get("conclusion") != "skipped"]
    if all(isinstance(step.get("number"), int) for step in steps):
        steps.sort(key=lambda step: step["number"])
    keep = (FAILED,) if base else (FAILED, ERRORED)
    vouched = rollup_vouched(steps, owned) | gate_vouched(steps, owned, step_names) if base else frozenset()
    sections: list[tuple[int, str, list[str]]] = []
    for line, k, status in owned:
        if status not in keep and not (status == ERRORED and k in vouched):
            continue
        if not sections or sections[-1][0] != k:
            sections.append((k, status, []))
        sections[-1][2].append(line)
    return FailedView(job, base, steps, sections)


def gate_vouched(steps: list[dict], owned: list[tuple[str, int | None, str]], step_names) -> frozenset[int]:
    """The indexes in STEPS of the continue-on-error checks a base log's own failed gated step vouches for: the ERRORED
    sections a base's view keeps as evidence (failed_view), beside rollup_vouched's. A gated step is one whose workflow
    `if:` lets it run only when one of the checks it names failed (StepNames.gates, _failure_gates), so its running,
    and failing, says the job is red for them. 2026-11-14: every PR's "cmux-next generated files" red was refused with
    "5 failing test(s) pass, do not run or fail differently on each of feat-cmux-next run 43606519098 ...": the catalog
    check ("Check generated action catalog, surfaces and inventory", continue-on-error) failed titlesUseTitleCase and
    four more on head and base alike, but only the head's ERRORED section was read, and the base's "Regenerate stale
    files" (`if: steps.actions.outcome == 'failure' || ...`), the step that failed the job because of it, vouched for
    nothing. Only a gated step that FAILED vouches, and only for a named check whose section is ERRORED (it printed a
    live `##[error]`); an unproven workflow (no gates) vouches for nothing."""
    gates = getattr(step_names, "gates", None)
    if not isinstance(gates, dict):
        return frozenset()
    failed = {k for _, k, status in owned if status == FAILED and k is not None}
    numbers = {step.get("number"): k for k, step in enumerate(steps)}
    found = set()
    for k in failed:
        for number in gates.get(steps[k].get("number"), ()):
            if number in numbers:
                found.add(numbers[number])
    return frozenset(found)


def rollup_vouched(steps: list[dict], owned: list[tuple[str, int | None, str]]) -> frozenset[int]:
    """The indexes in STEPS of the continue-on-error checks a base log's own failed rollup step names red: the ERRORED
    sections a base's view keeps as evidence (failed_view). The jobs API calls such a check a success; the job failed
    because its rollup (ROLLUP_STEPS, "Fail on any red check") listed it, one `##[error]red check: NAME` line each
    (rollup_log_reds: the whole list, its count and its `- NAME (outcome)` items agreeing, read from the rollup's own
    FAILED section alone). 2026-11-12: cmux#41790's checks job failed only in "Script tests (pin-cmux-tui, embed-cef,
    ensure-cef store)" (bash scripts/cmux-next/tests/generated-ownership.test.sh), exactly as feat-cmux-next run
    43196103785 did, and was refused with "errors not on feat-cmux-next run": that step's section is ERRORED on both
    sides, and a base view kept FAILED sections alone. A warn-only guard (WARN_ONLY_HEADER's list, no `red check:`
    line) and any ERRORED section the rollup does not name stay out: never evidence. A name two steps share, a rollup
    list that does not parse whole, or a rollup that did not fail vouches for nothing."""
    rollups = {k for k, step in enumerate(steps) if str(step.get("name") or "") in ROLLUP_STEPS  # step-name: classify
               and step.get("conclusion") == "failure"}
    if len(rollups) != 1:
        return frozenset()
    rollup = next(iter(rollups))
    named = rollup_log_reds("\n".join(line for line, k, status in owned if k == rollup and status == FAILED))
    if not named:
        return frozenset()
    by_name: dict[str, list[int]] = {}
    for k, step in enumerate(steps):
        by_name.setdefault(str(step.get("name") or ""), []).append(k)  # step-name: classify
    return frozenset(by_name[name][0] for name in named
                     if len(by_name.get(name, ())) == 1 and by_name[name][0] != rollup)


def view_text(view: FailedView) -> str:
    """VIEW's lines; a TypeError for anything that is not a FailedView (a raw log, UNPLACED), so no comparator can
    be handed one."""
    if not isinstance(view, FailedView):
        raise TypeError(f"a comparator reads a FailedView (failed_view), not {type(view).__name__}")
    return view.text()


# The runner's own steps around a job's workflow steps in the jobs API's steps[]: "Set up job" first, then a job-started
# hook's "Set up runner"; after them the post steps ("Post ..."), a job-completed hook's "Complete runner" and
# "Complete job" last. A workflow's `pre:` steps, a container job's steps or anything else leaves its order unproven.
RUNNER_LEADING_STEPS = ("Set up runner",)
RUNNER_TRAILING_STEPS = ("Complete runner",)


def workflow_step_names(repo: str, job: dict, path, github, seen: dict) -> dict[int, bool] | StepNamesUnknown:
    """step_owners' STEP_NAMES for JOB: {the number of each of its jobs-API steps its workflow (PATH, read at the
    job's head_sha) lists: True when that step has a `name:`, False when it has none}, or STEP_NAMES_UNKNOWN. Only a
    proven mapping names anything: one workflow job whose name is JOB's (no matrix, no called workflow), its steps
    matched to the jobs API's by order between the runner's own (RUNNER_LEADING_STEPS, RUNNER_TRAILING_STEPS), every
    fixed `name:` the step's API name, every unnamed step's API name `Run <its uses>` or, for a `run:` step, `Run ...`
    (_step_marks); a job whose name is an expression _check_matcher does not read (cmux-next.yml's
    cmux-scheme-compile) may be JOB too, so one whose steps fit as well must give the same marks. A local composite
    is one jobs-API step and changes none of this (LocalCompositeCannotPose). A workflow that cannot be read, or any
    doubt, is STEP_NAMES_UNKNOWN, so step_owners keeps taking a "Run ..." name for an unnamed step's (#40542's sixth
    Codex BLOCK). Each workflow is read once (SEEN). GITHUB with no blob read (next_batch's) reads git alone."""
    api = sorted(job.get("steps") or [], key=lambda step: step.get("number") if isinstance(step.get("number"), int)
                 else -1)
    names = [step.get("name") for step in api]  # step-name: validate
    sha = str(job.get("head_sha") or "")
    path = str(path or "").split("@", 1)[0]
    if (not _numbered_in_full(api) or not re.fullmatch(r"[0-9a-f]{40}", sha)
            or not re.fullmatch(r"\.github/workflows/[\w.-]+\.ya?ml", path)
            or not all(isinstance(name, str) for name in names)):
        return STEP_NAMES_UNKNOWN
    key = ("workflow-jobs", sha, path)
    if key not in seen:
        def read(_: str) -> str:
            if hasattr(github, "blob"):
                return source_text(repo, sha, path, github)
            text = git_text(repo, sha, path)  # a client with no blob read has only git
            if text is None:
                raise Refused(f"{repo}@{sha}: {path} could not be read")
            return text

        try:
            seen[key] = _workflow(yaml_module(), read, path.removeprefix(".github/workflows/"))[1]
        except Refused:
            seen[key] = None
    jobs = seen[key]
    if not isinstance(jobs, dict):
        return STEP_NAMES_UNKNOWN
    # The workflow job named like JOB, and every job whose name is not read (an expression may render as JOB's): each
    # that fits the jobs API's steps must give the same marks, so only one way of reading the steps is possible.
    named, rendered, unread = [], [], []
    for job_id, spec in jobs.items():
        if not isinstance(spec, dict):
            return STEP_NAMES_UNKNOWN
        try:
            matcher = _check_matcher(str(job_id), spec, path)
        except Refused:
            # A name _check_matcher does not read (two expressions: 'Reviewer path (${{ needs.plan.outputs.lane }},
            # ${{ matrix.family }})') still names JOB when JOB's name is its text with each expression rendered.
            (rendered if _rendered_name_fits(spec.get("name"), job.get("name")) else unread).append(spec)
            continue
        if (job.get("name") in matcher["exact"] or any(str(job.get("name", "")).startswith(start)
                                                       for start in matcher["prefixes"])):
            named.append(spec)
    # A name that only renders as JOB's names it only when no workflow job is named JOB outright; beside one that is,
    # it is a job whose name is not read, like any other (its steps, if they fit, must give the same marks). A name
    # that is one expression and no text (cmux-next.yml's cmux-scheme-compile, `${{ inputs.dev_daily == true && ...
    # || 'cmux app scheme compile (Debug)' }}`) renders as anything: read as a second job named JOB, it left every log
    # of 'cmux-next checks (god files, concurrency, crash safety, l10n)' with no headers and unplaced (cmux#44442 at
    # 656af9e3, #44349, #44164 on 2026-11-16), so each of its reds was compared whole.
    if named:
        unread += rendered
    else:
        named = rendered
    # A matrix leg is read like any job: its steps are the workflow's, in order, whatever the matrix values, and a
    # step name or script line that holds an expression is matched only up to it (_step_marks, _step_headers).
    # cmux#43014's 'Reviewer path (appstore, ipad)' (ios-review-gate.yml, matrix family) was refused because its
    # composite setup-cmux-tui-rust step printed three inner `Run` lines and no header was known to place them.
    if len(named) != 1 or "uses" in named[0]:
        return STEP_NAMES_UNKNOWN
    marks = _step_marks(named[0].get("steps"), names)
    if marks is None or any(_step_marks(spec.get("steps"), names) not in (None, marks) for spec in unread):
        return STEP_NAMES_UNKNOWN
    found = StepNames({step["number"]: mark for step, mark in zip(api, marks) if mark is not None})
    # The headers are the named job's; a job whose name is not read and whose steps fit too must give the same ones.
    found.headers = _step_headers(named[0]["steps"], api, marks)
    found.gates = _failure_gates(named[0]["steps"], api, marks)
    # Each jobs-API step's own workflow step, by number: the declared order other_pr_setup_verdict reads.
    found.specs = dict(zip([step["number"] for step, mark in zip(api, marks) if mark is not None], named[0]["steps"]))
    if any(_step_marks(spec.get("steps"), names) is not None
           and _step_headers(spec["steps"], api, marks) != found.headers for spec in unread):
        found.headers = None
    if any(_step_marks(spec.get("steps"), names) is not None and spec.get("steps") != named[0]["steps"]
           for spec in unread):
        found.specs = None
    if any(_step_marks(spec.get("steps"), names) is not None
           and _failure_gates(spec["steps"], api, marks) != found.gates for spec in unread):
        found.gates = None
    return found


def _rendered_name_fits(template, name) -> bool:
    """Whether NAME (a jobs-API job name) is TEMPLATE (a workflow job's `name:` holding `${{ }}` expressions) with
    each expression rendered as some text. Matching more than one workflow job leaves workflow_step_names unsure."""
    if not isinstance(template, str) or not isinstance(name, str) or "${{" not in template:
        return False
    parts = re.split(r"\$\{\{.*?\}\}", template)
    return re.fullmatch(".*".join(map(re.escape, parts)), name, flags=re.DOTALL) is not None


def _numbered_in_full(api: list[dict]) -> bool:
    """Whether API (a job's steps, by number) lists every step: numbered 1, 2, ... up to its trailing runner steps
    (post steps, RUNNER_TRAILING_STEPS, "Complete job"), which the runner numbers apart (cmux-next daemon tests: 1-42,
    then 81-85), and in increasing order through them."""
    numbers = [step.get("number") for step in api]
    if not all(isinstance(number, int) and not isinstance(number, bool) for number in numbers):
        return False
    head = 0
    while head < len(api) and not (str(api[head].get("name") or "").startswith("Post ")  # step-name: validate
                                   or api[head].get("name") in (*RUNNER_TRAILING_STEPS, "Complete job")):
        head += 1
    return (numbers[:head] == list(range(1, head + 1))
            and all(earlier < later for earlier, later in zip(numbers, numbers[1:])))


class StepNames(dict):
    """workflow_step_names' answer: {step number: whether its workflow step has a `name:`}, and HEADERS, {step
    number: (the STEP_START line the runner opens it with, less `##[group]`, whether that is the whole line or its
    start, whether its conclusion is strict)} for every step but "Set up job" and "Complete job" (_step_headers), or
    None. step_owners' second reading
    (_aligned_starts) reads HEADERS; a plain dict has none, and is read as before."""
    headers: dict | None = None
    gates: dict | None = None
    specs: dict | None = None  # {step number: its workflow step}, None when two workflow jobs could be it


# One `steps.<id>.outcome == 'failure'` test, the whole of a gate's disjunct (_failure_gates).
FAILURE_TEST = re.compile(r"""steps\.([A-Za-z_][A-Za-z0-9_-]*)\.outcome\s*==\s*'failure'""")


def _top_level(text: str, operator: str) -> list[str] | None:
    """TEXT split on OPERATOR (`&&`, `||`) outside parentheses and quotes, each part stripped; None when its
    parentheses or quotes do not balance."""
    parts, depth, quoted, start, n = [], 0, False, 0, 0
    while n < len(text):
        char = text[n]
        if char == "'":
            quoted = not quoted
        elif not quoted and char == "(":
            depth += 1
        elif not quoted and char == ")":
            depth -= 1
            if depth < 0:
                return None
        elif not quoted and not depth and text.startswith(operator, n):
            parts.append(text[start:n].strip())
            start = n = n + len(operator)
            continue
        n += 1
    if depth or quoted:
        return None
    return [*parts, text[start:].strip()]


def _unwrapped(text: str) -> str:
    """TEXT without the parentheses that enclose all of it (`((a || b))` is `a || b`; `(a) || (b)` stays), in one pass
    over it: each `(` outside quotes is matched to its `)`, then the outer layers whose `(` closes at the matching end
    are peeled. Unbalanced text is returned stripped and unpeeled (its _top_level is None)."""
    text = text.strip()
    closes: dict[int, int] = {}
    opened: list[int] = []
    quoted = False
    for n, char in enumerate(text):
        if char == "'":
            quoted = not quoted
        elif not quoted and char == "(":
            opened.append(n)
        elif not quoted and char == ")":
            if not opened:
                return text
            closes[opened.pop()] = n
    if opened or quoted:
        return text
    start, end = 0, len(text) - 1
    while start < end and closes.get(start) == end:
        start, end = start + 1, end - 1
        while start <= end and text[start].isspace():
            start += 1
        while end >= start and text[end].isspace():
            end -= 1
    return text[start:end + 1]


def _failure_ids(expression: str) -> set[str] | None:
    """The step ids of EXPRESSION when it is a disjunction (`||`) of `steps.<id>.outcome == 'failure'` tests and
    nothing else (one test is one), else None."""
    tests = _top_level(_unwrapped(expression), "||")
    if not tests:
        return None
    ids = [match.group(1) if (match := FAILURE_TEST.fullmatch(_unwrapped(test))) else None for test in tests]
    return set(ids) if all(ids) else None


def _gate_ids(condition: object) -> frozenset[str] | None:
    """The step ids a step's `if:` CONDITION requires one of to have failed: the condition is such a disjunction
    (_failure_ids), or a conjunction (`&&`, which binds tighter than `||`) with such a term, so the step runs only when
    one of them failed. None for any other condition: one that could run the step with none of them failed (a top-level
    `|| always()`, a negation `!(...)`) never vouches."""
    if not isinstance(condition, str):
        return None
    text = condition.strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2].strip()
    text = _unwrapped(text)
    either = _top_level(text, "||")
    if either is None:
        return None
    if len(either) > 1:
        return frozenset(_failure_ids(text) or ()) or None
    found: set[str] = set()
    for term in _top_level(text, "&&") or ():
        found |= _failure_ids(term) or set()
    return frozenset(found) or None


def _failure_gates(declared: list[dict], api: list[dict], marks: list) -> dict[int, frozenset[int]]:
    """{the jobs-API number of each workflow step in DECLARED whose `if:` runs it only when one of the job's
    continue-on-error checks failed (_gate_ids): those checks' numbers}, for gate_vouched. A gate naming an id no
    continue-on-error step of the job has is dropped whole (it is not proven to be about a check's failure)."""
    numbered: list[tuple[int, dict]] = []
    workflow = iter(declared)
    for step, mark in zip(api, marks):
        if mark is not None:
            numbered.append((step["number"], next(workflow)))
    checks = {spec["id"]: number for number, spec in numbered
              if isinstance(spec.get("id"), str) and spec.get("continue-on-error", False) is True}
    found: dict[int, frozenset[int]] = {}
    for number, spec in numbered:
        ids = _gate_ids(spec.get("if"))
        if ids and all(name in checks for name in ids):
            found[number] = frozenset(checks[name] for name in ids)
    return found


def _step_headers(declared: list[dict], api: list[dict], marks: list) -> dict[int, tuple[str, bool, bool]] | None:
    """{the number of each of the jobs-API steps API (marks: _step_marks') but the first and the last: (its header,
    exact, strict)}: a `uses:` step's `Run <uses>`, a `run:` step's `Run <its script's first line>` (only up to a `${{`,
    which the runner renders: a start), a post step's `Post job cleanup.`, a job hook's (Set up runner, Complete
    runner) any `Run ...` line. STRICT: a workflow step with no `continue-on-error`, whose conclusion says whether its
    section has an `##[error]` line (_aligned_starts). None when an unnamed step's API name is not its header (the
    jobs API names it by it), so the workflow and the job disagree."""
    found: dict[int, tuple[str, bool, bool]] = {}
    workflow = iter(declared)
    for k, (step, mark) in enumerate(zip(api, marks)):
        if mark is not None:
            spec = next(workflow)
            if isinstance(spec.get("uses"), str):
                said, exact = f"Run {spec['uses'].strip()}", True
            else:
                script = str(spec.get("run") or "").strip()
                first = script.splitlines()[0].strip() if script else ""
                said, exact = (f"Run {first}", True) if "${{" not in first else (
                    f"Run {first.split('${{', 1)[0]}", False)
            if mark is False and (not exact or step.get("name") != said):  # step-name: validate
                return None
            found[step["number"]] = (said, exact, spec.get("continue-on-error", False) is False)
        elif 0 < k < len(api) - 1:
            name = str(step.get("name") or "")  # step-name: validate
            found[step["number"]] = (("Post job cleanup.", True, False) if name.startswith("Post ")
                                     else ("Run ", False, False))
    return found


def job_step_names(repo: str, job: dict, github, seen: dict, path=None) -> dict[int, bool] | StepNamesUnknown:
    """workflow_step_names for JOB, its workflow's PATH read from its run's record when not given (rest_run, once per
    run in SEEN; an unread record is STEP_NAMES_UNKNOWN). Read for every job: its headers (StepNames) let step_owners
    place a log whose steps are not one header each (_aligned_starts), not only a step named "Run ..." (cmux#41001,
    hq#9191: every step named, so neither was read and both logs went unplaced)."""
    if path is None:
        key = ("run-record", job.get("run_id"))
        if key not in seen:
            try:
                seen[key] = rest_run(repo, job["run_id"], github, seen)
            except (KeyError, Refused):
                seen[key] = None
        record = seen[key]
        path = record.get("path") if isinstance(record, dict) else None
    return workflow_step_names(repo, job, path, github, seen)


def _step_marks(declared, names: list[str]) -> list[bool | None] | None:
    """For each of a job's jobs-API step NAMES, whether the workflow step it is (DECLARED, the job's `steps:`) has a
    `name:`, None for the runner's own steps; None when the steps do not map one to one in order
    (workflow_step_names)."""
    if not isinstance(declared, list) or not all(isinstance(step, dict) for step in declared):
        return None
    if names[:1] != ["Set up job"]:
        return None
    first = 1
    while first < len(names) and names[first] in RUNNER_LEADING_STEPS:
        first += 1
    last = first + len(declared)
    tail = names[last:]
    if (len(tail) < 1 or tail[-1] != "Complete job"
            or not all(name.startswith("Post ") or name in RUNNER_TRAILING_STEPS for name in tail[:-1])):
        return None
    for name, step in zip(names[first:last], declared):
        if "name" in step:
            said = step["name"]  # step-name: validate
            if not isinstance(said, str) or ("${{" not in said and name != said):
                return None
        elif isinstance(step.get("uses"), str):
            if name != f"Run {step['uses']}":
                return None
        elif not (isinstance(step.get("run"), str) and name.startswith("Run ")):
            return None
    return [None] * first + ["name" in step for step in declared] + [None] * len(tail)


class Unplaced:
    """signature()'s answer for a log step_owners does not place: no failed step, test or error line of it is proven
    the failed steps' own, so it has no signature. Not a tuple and not iterable, so no caller can unpack it into sets
    or subtract a base's from it; each caller refuses on it, or treats the red as new and never as the base's
    (#40542's Codex F1 at 76dc160c: next_batch's expand_job subtracted an unplaced base log's signature, whose
    passing composite printed the head's Sources/New.swift error too, and read the head's new failure as inherited)."""
    __slots__ = ()

    def __repr__(self) -> str:
        return "UNPLACED"


UNPLACED = Unplaced()
# What a caller says when signature() is UNPLACED.
# What a caller says when a placed head's failed sections name no failing test, error line or crash: compared whole.
BARE_WHY = ("its failed steps' own lines name no failing test or error line (a shell check's `FAIL:` line is one only "
            "in a whole-log comparison)")
UNPLACED_WHY = ("its log does not map one to one onto its steps (step_owners: a composite action, a silent step or a "
                "header that is not its step's own), so no line can be told to the step that printed it")
# What a placed head says when its red base verdict's log is the one step_owners does not place: compared whole too,
# never refused as the head's own red (hq#13746, whose base Fleet tests log carried a git fetch's own `##[error]`
# lines and failed the same 4 subtests).
BASE_UNPLACED_WHY = ("its red base verdict's log does not map one to one onto its steps (step_owners), so no base line "
                     "can be told to a failed step")


def signature(view: "FailedView | Unplaced") -> tuple[set[str], set[str], set[str]] | Unplaced:
    """(failed step names, failing test names, error lines with numbers masked) of VIEW (failed_view): its job's failed
    steps by the jobs API, and the tests and errors its sections print, a head's from its FAILED and ERRORED
    sections, a base's from its FAILED ones, so a line a passing step printed is never a head's red or a base's
    evidence (cmux#40542 F1: a composite's extra STEP_START line put a passing step's `Sources/New.swift` diagnostic
    in the base's errors, and judge() excused the head's new failure; its seventh Codex BLOCK: a passing step's
    `✘ Test fake()` was a head's failing test, matched the base's real one, and hid a new error). The runner's echo of
    each step's script is never a test or an error (test_reds.echoed; 2026-10-30, cmux#28145 was excused because the
    base's log echoed the same `echo "::error::..."` lines of its step's script). An UNPLACED view has no signature:
    UNPLACED, on either side."""
    if view is UNPLACED:
        return UNPLACED
    text = view_text(view)
    steps = {step["name"] for step in view.job.get("steps") or []  # step-name: classify
             if step.get("conclusion") not in (None, "success", "skipped")}
    tests = set(test_reds.failed_in(text))  # bun's too (#41158's review F1)
    return steps, tests, {error for _, error in step_errors(view)}


def owned_unnamed(own: "test_reds.Result", view: "FailedView | Unplaced",
                  unplaced: "test_reds.Steps | None" = None) -> "test_reds.Result":
    """OWN (test_reds.read of a red's raw log) with its failures no parser names read from VIEW's failed sections,
    each on its own, when VIEW is placed: a step that passed is never this red's, whatever it printed (#41244's review
    F1, the rule of #41241: evidence from passing steps never counts). An unplaced log has no step known to have
    passed: UNPLACED, its every step split by the caller and none judged pass or fail by its text (test_reds.unjudged;
    #41329's review follow-up F3), is read, each step on its own."""
    if view is UNPLACED and unplaced is None:
        return own
    steps = test_reds.read(unplaced if view is UNPLACED else view_text(view))
    # A cut-short run in a failed step that printed no `##[error]` is read there too (the raw reading judged that step
    # passed by its text): the reasons of both readings, the unnamed failures of the steps' alone.
    own.truncated = [why for why in dict.fromkeys(own.truncated + steps.truncated)
                     if not why.startswith(test_reds.UNNAMED_WHY)]
    own.unnamed = steps.unnamed
    if own.unnamed:
        own.truncated.append(test_reds.unnamed_why(own.unnamed))
    return own


def step_errors(view: FailedView) -> set[tuple[str, str]]:
    """(the name of the step that printed it, the error line with numbers masked) for each error line of VIEW
    (failed_view) signature() reads. judge() excuses a head error only when a base printed it from a failed step of
    the same name."""
    text = view_text(view)
    scope = view.lines()
    skip = test_reds.echoed(test_reds.log_lines(text))
    tests = set(test_reds.failed_in(text))
    job = view.job
    found: set[tuple[str, str]] = set()
    for n, line in enumerate(lines_of(text)):
        if n in skip or line.startswith(test_reds.TAP_MARKER) or SUMMARY_RED.match(line):
            continue
        if ((ERROR.search(line)
             or ((marker := JOB_ERROR.get(job.get("name", ""))) is not None and marker.search(line))
             or (not tests and ("default" in job.get("name", "").lower()
                                or "snapshot" in job.get("name", "").lower())
                 and SUMMARY_FAILURE.search(line)))
                and not GENERIC.search(line) and not WARNING.search(line) and not CRASH_LINE.search(line)
                and not SUCCESS_DIAGNOSTIC.search(line) and not BENIGN.match(line)):
            k = scope[n][1]
            step = str(view.steps[k].get("name") or "")  # step-name: classify
            found.add((step, normalise_error(line)))
    return found


# A log step_owners cannot place (a composite action's inner `Run` lines, a silent step, a header that is not its
# step's own: UNPLACED) has no section per step, so no line can be charged to the step that failed. Seen on
# 2026-11-11 on 'cmux-next checks (god files, concurrency, crash safety, l10n)' (cmux#40954) and 'CmuxMobileKit tests
# (macOS swift test, iOS simulator)' (cmux#40598, #40664): every red in those jobs was refused, the base's own too.
# Such a red is compared whole instead, on both sides alike, and excused only when it is within one red base verdict
# for the job: the newest, or an older one in the window the placed comparison reads (BASE_WINDOW, BASE_WINDOW_HOURS;
# a green verdict ends it), each alone: every failed step of the head (by the jobs API, (name, conclusion)), every
# failing-test line and every error line (numbers masked), each as often as that verdict has it or less, read from the
# whole log less the runner's echo of each script, with at least one. Counts, not sets: a whole log may take in a
# passing step's expected `✘ Test` or error line (#40542's Codex BLOCKs), so a head whose failing step newly prints a
# line the base printed only from a passing step prints it once more than the base, and is refused. A line the head
# prints more often than the base, or that the base never prints, is the head's own. The base may fail more: a verdict
# that fails the head's reds and others besides still proves the head's are the base's (cmux#43251 at fe4918f2 on
# 2026-11-15: 'cmux-next checks' failed 2 script tests, base run 43676446747 those 2 and 3 more, and identity refused
# it). Not covered by counts: a PR that both stops a passing step's line and makes its failing step print that same
# line; it must change two steps to look the same, and the failed steps must still be the base's. Failing tests are
# counted by name with their digits (test2() is not test3()). A log that says tests failed and names none (unnamed) is
# never compared, on either side.
# The app FFI pin's red (FFI_PIN_ERROR) is never excused by identity: its rules read the PR's paths, which a whole-log
# identity cannot stand in for, and its error masks the pinned sha. ffi_pin_step_a judges it first, from this
# signature as from a placed one (#40542 left every unplaced pin red refused, the base's own too: cmux#41086 on
# 2026-11-11), and what else is red beside a pin it sets aside is then compared whole, without the pin's parts.
# A Swift compiler diagnostic quotes its source (`53 |     static func f(_ error: Error) {`, `   | `- warning: ...`):
# context, never an error line of its own. How often a warning is quoted depends on what the build recompiled, so
# a whole-log count of it differs between two runs that fail the same way (cmux#41046's daemon tests on 2026-11-11:
# 6 against the base's 11).
SOURCE_EXCERPT = re.compile(r"^\s*\d*\s\|\s")


class UnplacedSignature(NamedTuple):
    steps: Counter  # (name, conclusion) of each failed step, counted (#41158's review F1)
    tests: Counter
    errors: Counter
    crashes: frozenset = frozenset()
    unnamed: tuple = ()  # runner lines that say tests failed where that runner's tests went unnamed (failed_tests)


def failed_step_keys(job: dict) -> Counter:
    """How many of JOB's steps failed under each (name, conclusion): an excuse key that keeps a failed step's identity.
    A step's name alone (a set of names) let two failed steps of one name match the base's one, and a cancelled step
    match the base's failure (#41158's review F1)."""
    return Counter((str(step.get("name") or ""), str(step.get("conclusion")))  # step-name: classify
                   for step in job.get("steps") or []
                   if step.get("conclusion") not in (None, "success", "skipped"))


def step_keys_text(keys: Counter) -> str:
    """KEYS (failed_step_keys) as an audit line names them: `name (conclusion)`, and `x N` when more than one."""
    return "; ".join(f"{name} ({conclusion})" + (f" x{count}" if count > 1 else "")
                     for (name, conclusion), count in sorted(keys.items()))


def unplaced_signature(job: dict, log: str) -> UnplacedSignature:
    """UnplacedSignature of JOB's whole LOG (see above): the failed steps by the jobs API, and how often each
    failing-test line and error line appears in every line but the runner's echo of a script."""
    steps = failed_step_keys(job)
    output = test_reds.lines_of(log)
    # The failing tests by name, digits kept (never normalise_error's masking: test2() is not test3()), counted by
    # test_reds' one parser (failed_tests): bun's `FILE > TEST` too (#41158's review F1: unread, two different bun
    # failures with one `expect()` headline were the same red), and every source of a name counted alike, an
    # xcresult `FAILED:` line and each listing entry (#41129's review F2; #41158's review F2).
    # No step of an unplaced log is known to have passed: every step is read, each on its own (test_reds.unjudged).
    unnamed: list = []
    tests = test_reds.failed_in(test_reds.unjudged(log), unnamed)
    named = set(tests)
    errors: Counter = Counter()
    for line in output:
        if line.startswith(test_reds.TAP_MARKER) or SUMMARY_RED.match(line) or SOURCE_EXCERPT.match(line):
            continue
        if ((ERROR.search(line)
             or ((marker := JOB_ERROR.get(job.get("name", ""))) is not None and marker.search(line))
             or SHELL_FAIL.match(line)
             or (not named and ("default" in job.get("name", "").lower()
                                or "snapshot" in job.get("name", "").lower())
                 and SUMMARY_FAILURE.search(line)))
                and not GENERIC.search(line) and not WARNING.search(line) and not CRASH_LINE.search(line)
                and not SUCCESS_DIAGNOSTIC.search(line) and not BENIGN.match(line)):
            errors[normalise_error(line)] += 1
    # The panic ratchet's RED rows word for word, counts kept (#41129's review F1): its summary error is the same at
    # any count, so 693 > baseline 686 at the head is not 692 at the base. Hit locations are left out, as ratchet_red.
    inside = False
    for line in output:
        if line == RATCHET_RED:
            inside = True
        elif inside and (line.startswith(RATCHET_END) or line.startswith("##[")):
            inside = False
        elif inside and line and not RATCHET_HIT.match(line):
            errors[f"ratchet: {line}"] += 1
    if not tests and not errors:
        errors = last_words(output)
    crashes = frozenset(first or second for first, second in CRASH.findall("\n".join(output)))
    return UnplacedSignature(steps, tests, errors, crashes, tuple(dict.fromkeys(unnamed)))


# A shell step that ends its red with a plain sentence and exit 1 names no test and no error line: only the runner's
# generic `##[error]Process completed with exit code 1.` follows it. 2026-11-20, cmuxterm-hq#15467 at 4aa7a17c
# (cmuxterm-hq#15575): 'Fleet tests' failed "Validate the fleet client install and the tag policy" on `Bundled fleet
# client is stale. Run scripts/sync-fleet-skill-client.py.`, the same step and the same line as main's run
# 44769654200, and was refused as naming nothing to compare. When a whole log names no failing test or error line, the
# last line each exit annotation follows is that failed step's error line, on both sides alike (numbers masked,
# counted): a step that fails anew, or fails on other words, still differs from the base.
EXIT_LINE = re.compile(r"^##\[error\]Process completed with exit code (\d+)\.?$")
LAST_WORDS = "last words before exit"


def last_words(output: list[str]) -> Counter:
    """For each runner exit annotation in OUTPUT (a whole log's lines less the runner's echo, test_reds.lines_of),
    `last words before exit N: LINE`, LINE the nearest non-empty line above it that is not a runner `##[` line,
    numbers masked (normalise_error), counted."""
    found: Counter = Counter()
    for n, line in enumerate(output):
        if not (exit_code := EXIT_LINE.match(line)):
            continue
        said = next((text for text in reversed(output[:n]) if text.strip()), "")
        if said and not said.startswith("##["):
            found[f"{LAST_WORDS} {exit_code[1]}: {normalise_error(said)}"] += 1
    return found


def unplaced_without_ffi_pin(head: UnplacedSignature) -> UnplacedSignature:
    """HEAD without the app FFI pin's own parts, as without_ffi_pin: its check step, its error lines and the rollup's
    line naming it. The rollup step stays: the base must have failed it too."""
    pin, rollup = normalise_error(FFI_PIN_ERROR), normalise_error(f"red check: {FFI_PIN_CHECK}")
    return head._replace(steps=Counter({key: n for key, n in head.steps.items() if key[0] != FFI_PIN_CHECK}),
                         errors=Counter({error: n for error, n in head.errors.items()
                                         if not error.startswith(pin) and error != rollup}))


def unplaced_base_evidence(repo: str, base_job: dict, github) -> UnplacedSignature:
    """unplaced_signature of red base job BASE_JOB's whole log: the one base read of an unplaced comparison."""
    return unplaced_signature(base_job, github.log(repo, base_job))


def unplaced_head_evidence(repo: str, job: dict, github) -> UnplacedSignature:
    """unplaced_signature of placed red head JOB's whole log, compared with a red base verdict not placed (hq#13746)."""
    return unplaced_signature(job, github.log(repo, job))


# A red job whose log names no failing test, error line or crash is compared by its failed steps alone (Leo, 2026-11-21
# ~03:45Z: "clearly we need to be hitting a 10x improvement in not running useless jobs"; the coordinator's rule: "a
# red job with no parsable test name is excused when the same job (same name, same failing step) is red on the base
# run"). cmuxterm-hq docs/ci/bottleneck-and-skip-candidates-2026-11-21.md: 3,765 PR heads were red only from base over
# 11-13..19, and a refused inherited red makes its owner push again. Excused only when the base verdict failed exactly
# the same steps (name and conclusion, counted: failed_step_keys) and names no failing test, error line, crash or
# unnamed test either: a base that names a failure the head does not print is another failure, never this one.
STEP_ONLY_WHY = "its log names no failing test or error line, so only its failed steps identify it"


def step_only_verdict(name: str, why: str, head: UnplacedSignature, found: UnplacedSignature, where: str) -> str:
    """The audit line for red NAME whose whole-log signature HEAD names no failing test or error line, when FOUND (the
    red base verdict at WHERE) failed the same steps and names nothing either; else Refused saying why not."""
    nothing = f"'{name}': {why}, and its log names no failing test or error line"
    if head.crashes or head.unnamed:
        raise Refused(f"{nothing}, but it crashed or reports tests it does not name; never compared by step alone")
    if found.tests or found.errors or found.crashes or found.unnamed:
        said = sorted(found.tests) or sorted(found.errors) or sorted(found.crashes) or list(found.unnamed)
        raise Refused(f"{nothing}, while {where} names its failure ({'; '.join(said)[:300]}); a red naming nothing "
                      "is not that one")
    if head.steps != found.steps:
        raise Refused(f"{nothing}; compared by step alone, its failed steps ({step_keys_text(head.steps)}) are not "
                      f"{where}'s ({step_keys_text(found.steps)})")
    return (f"excused '{name}': {STEP_ONLY_WHY}: the same failed steps ({step_keys_text(head.steps)[:300]}), as "
            f"often each, as {where}, which names no failing test or error line either")


def unplaced_verdict(repo: str, name: str, base: str, head: UnplacedSignature, found: UnplacedSignature,
                     base_run: dict, *, why: str | None = None) -> str:
    """The audit line for an unplaced red job NAME whose whole-log signature HEAD is FOUND's, the newest red base
    verdict's (the rule above); raises Refused naming what differs. REPO is the base run's own repo, which is the
    PR's unless the base is verified in another (BASE_VERDICT_REPO): nothing but BASE_RUN's URL is read from it."""
    why = UNPLACED_WHY if why is None else why
    url = base_run.get("html_url") or f"https://github.com/{repo}/actions/runs/{base_run['id']}"
    where = f"{base} run {base_run['id']} ({url})"
    if not head.steps:
        raise Refused(f"'{name}': {why}, and it names no failed step; nothing is compared with the base")
    if not head.tests and not head.errors:
        # A red that names nothing (a setup step such as `Select JDK 17` exiting 1, a shell check that prints no
        # FAIL line) is the base's when the base verdict failed the very same steps and names nothing either
        # (STEP_ONLY_WHY): its failed steps are its whole identity, as the Chromium step's is. cmux#48480 was refused
        # three times for 'seven-language live conformance', red at 'Select JDK 17' on feat-cmux-next too.
        return step_only_verdict(name, why, head, found, where)
    for side, said in (("its", head.unnamed), (f"{where}'s", found.unnamed)):
        if said:
            raise Refused(f"'{name}': {why}; compared whole, {side} log reports more failed tests than it names "
                          f"({said[0][:200]}), so no failure can be told from another")
    # Within, not equal (the rule above): each of the head's counts at most the base's; what the base fails besides
    # is the base's.
    if head.steps - found.steps:
        raise Refused(f"'{name}': {why}; compared whole, its failed steps ({step_keys_text(head.steps)}) are "
                      f"not {where}'s ({step_keys_text(found.steps)})")
    for what, mine, theirs in (("failing tests", head.tests, found.tests), ("error lines", head.errors, found.errors)):
        if more := sorted((mine - theirs).elements()):
            fewer = sorted((theirs - mine).elements())
            raise Refused(f"'{name}': {why}; compared whole, its {what} are not {where}'s"
                          f": more on this head: {'; '.join(more)[:500]}"
                          + (f"; more on the base: {'; '.join(fewer)[:300]}" if fewer else ""))
    said = sorted(head.tests) or sorted(head.errors)
    said_why = {UNPLACED_WHY: "its log does not map onto its steps",
                BASE_UNPLACED_WHY: "its base verdict's log does not map onto its steps"}.get(
                    why, "its failed steps name no failing test or error line")
    besides = sum(((found.steps - head.steps) + (found.tests - head.tests) + (found.errors - head.errors)).values())
    if besides:
        return (f"excused '{name}': {said_why}, so it was compared whole: its failed steps "
                f"({step_keys_text(head.steps)[:200]}), failing tests and error lines, each as often or less, are "
                f"within those of {where}, which fails {besides} more besides: {'; '.join(said)[:400]}")
    return (f"excused '{name}': {said_why}, so it was compared whole: the same failed steps "
            f"({step_keys_text(head.steps)[:200]}), failing tests and error lines, as often each, as {where}: "
            f"{'; '.join(said)[:400]}")


# A step the base never runs in this job (2026-11-11, cmux#41046 at b329575b and #41086 at 5d0fb077): on a pull request
# 'cmux-next daemon tests' also hosts the generated-files check (CMUX_NEXT_FOLD_GENERATED), and its 'Regenerate stale
# files' step runs regenerate-action-contracts.sh, which runs ActionSurfaceParityTests. Base pushes check generated
# files in another job ('cmux-next generated files', base tier), so the base's 'cmux-next daemon tests' skips that
# step and no base verdict of the job carries it. The base red everyMenuKeepsAShortTopLevel() (agentChat 14 > 13,
# through the pinned FFI) failed that step on every PR. Such a step is excused only when: the rest of the job is
# identical with one red base verdict of the job (UnplacedSignature: the head's failed steps less these, the same
# failing tests and error lines as often each); every extra step was skipped or absent in that verdict; one red base
# job of another name in the same workflow's base runs (the same window) failed every extra step; at least one
# failing test is extra, and every extra failing test (by name, digits kept) and every extra error line is that job's
# too. Nothing else is: a new test, a new error line, or a step the base job ran and passed is the PR's own.
PR_ONLY_STEP_SKIPPED = (None, "skipped")


def pr_only_extra(head: UnplacedSignature, same: dict, found: UnplacedSignature
                  ) -> "tuple[Counter, Counter, Counter] | None":
    """(extra failed steps by (name, conclusion), extra failing tests, extra error lines) of HEAD over FOUND, the
    red base verdict SAME of the same job, when the rest is identical and no extra step ran in SAME; else None."""
    extra = head.steps - found.steps
    if not extra or found.steps - head.steps or head.unnamed or found.unnamed:
        return None  # a log that says tests failed and names none can hide a red no test ID matches (#41253's review)
    ran = {str(step.get("name") or ""): step.get("conclusion") for step in same.get("steps") or []}  # step-name: classify
    if any(ran.get(step) not in PR_ONLY_STEP_SKIPPED for step, _ in extra):
        return None
    if found.tests - head.tests or found.errors - head.errors:
        return None
    tests, errors = head.tests - found.tests, head.errors - found.errors
    return (extra, tests, errors) if tests else None


def pr_only_step_verdict(repo: str, base: str, name: str, head: UnplacedSignature,
                         window: "list[tuple[dict, dict, UnplacedSignature]]", runs: list[dict], base_jobs: dict,
                         github) -> str | None:
    """The audit line for an unplaced red NAME whose only difference from a red base verdict of its own (WINDOW:
    (run, job, signature), newest first) is a step that verdict never ran, failing only tests another red base job
    failed (the rule above); None when no base evidence shows it. RUNS: the workflow's base runs, newest first."""
    candidates = [(run, same, found, extra) for run, same, found in window
                  if (extra := pr_only_extra(head, same, found)) is not None]
    if not candidates:
        return None
    newest = created(window[0][0])
    reads = 0
    # Newest first, a job name that passed in a base run is fixed from there back: an older red of it may predate the
    # fix and never counts (the window rule above; #41253's review: a red from before the menu fix must not excuse a
    # PR that breaks the menu again). A green run's jobs are read for that too.
    fixed: set = set()
    for run in runs:
        if run.get("conclusion") not in ("failure", "success"):  # unfinished or cancelled: no verdict either way
            continue
        if newest and created(run) and abs(newest - created(run)) > timedelta(hours=BASE_WINDOW_HOURS):
            continue
        if run["id"] not in base_jobs or base_jobs[run["id"]] is None:
            if reads >= BASE_WINDOW:
                break
            reads += 1
            base_jobs[run["id"]] = base_run_jobs(repo, run, github)
        jobs = base_jobs[run["id"]]
        passed = {other.get("name") for other in jobs if other.get("conclusion") == "success"}
        for other in jobs:
            failed = failed_step_keys(other)
            if (other.get("name") == name or other.get("conclusion") != "failure"
                    or other.get("name") in fixed | passed):
                continue
            fits = [(same_run, extra) for same_run, _, _, extra in candidates if not extra[0] - failed]
            if not fits:
                continue
            theirs = unplaced_base_evidence(repo, other, github)
            for same_run, (steps, tests, errors) in fits:
                if set(tests) <= set(theirs.tests) and set(errors) <= set(theirs.errors):
                    url = run.get("html_url") or f"https://github.com/{repo}/actions/runs/{run['id']}"
                    return (f"excused '{name}': its steps ({step_keys_text(steps)}) never run in {base} run {same_run['id']}'s "
                            f"'{name}', which fails the same way otherwise; the failing tests there "
                            f"({'; '.join(sorted(tests))[:300]}) fail in {base} run {run['id']}'s "
                            f"'{other.get('name')}' ({url}), in the same steps")
        fixed |= passed
    return None

# A sub-check the base ran and passed (2026-11-16, cmux#44614 at fb973a17 and cmux#44622 at 071af5f5). One step runs
# many checks, concurrently through scripts/ci/run-checks-concurrently.sh, which prints one
# `::group::<command>: ok, <n>s` line per check that passed and `::error title=check failed::<command>` for each that
# failed. Both heads' only red was 'cmux-next checks (god files, concurrency, crash safety, l10n)', failing
# ./scripts/lint-ios-package-conventions.sh on three namespace-type violations in files neither PR touches, which base
# commit f48280ea767 justified after their merge-base. The base ran that lint and passed it, so compared whole each
# head had error lines the base lacked, and both reds read as the PRs' own with nothing said about what to do: the
# fix was already on the base and a base merge would have cleared them. So when every base verdict read ran and
# passed the script the head's extra error lines name, the refusal says that by name, and says to merge the base. It
# excuses nothing by itself: a red is still only excused by a base verdict that fails the same lines.
# Read from the extension back, never forward from a path's start: a line of "scripts/scripts/scripts/..." makes
# every start scan the whole rest of it, which is quadratic in the line (PrLogPatternsScale). Each backward
# walk stops at the end of the previous match, so the whole reading is linear.
SUB_CHECK_END = re.compile(r"\.(?:sh|py|mjs|js|ts)(?![\w.-])")
# What a path of a script a step runs is made of.
SUB_CHECK_PATH = "_./-"


def sub_checks(error: str) -> frozenset:
    """The scripts an error line names (`./scripts/lint-ios-package-conventions.sh`), which is how a step's log says
    which check printed it; empty when the line names none. Only a script a step runs (`scripts/...`, with or without
    a leading `./`), so a compiler error naming a source file is no sub-check."""
    found: set = set()
    stop = 0
    for end in SUB_CHECK_END.finditer(error):
        begin = end.start()
        while begin > stop and (error[begin - 1].isalnum() or error[begin - 1] in SUB_CHECK_PATH):
            begin -= 1
        stop = end.end()
        path = error[begin:end.end()].removeprefix("./")
        if path.startswith("scripts/") and "//" not in path:
            found.add(path)
    return frozenset(found)


# What scripts/ci/run-checks-concurrently.sh prints for a check that passed: `::group::<command>: ok, <n>s`, which the
# runner renders as `##[group]<command>: ok, 22s`. Not a step header (STEP_START reads `##[group]Run `), and the one
# line that tells a check that ran and passed from a name a step merely echoes.
CHECK_GROUP = "##[group]"


def check_passed_in(log: str, marker: str) -> bool:
    """Whether LOG says the concurrent check runner ran MARKER and it passed (`##[group]<command>: ok, 22s`)."""
    return any(line.startswith(CHECK_GROUP) and not STEP_START.match(line) and f"{marker}: ok," in line
               for line in lines_of(log))


def passed_on_base_verdict(repo: str, base: str, name: str, head: UnplacedSignature,
                           seen: "list[tuple[dict, dict, UnplacedSignature]]", github) -> None:
    """Raises Refused naming the script when the head's extra error lines over every base verdict read (SEEN:
    (run, job, signature)) name one that each of those verdicts ran and passed; returns None when no base log says
    so. A refusal only: it never excuses a red."""
    markers: set = set()
    # Whether merging the base clears the whole red, so whether that is said: no extra error line of the head names
    # another script, and no failed step is the head's alone. A line naming no script at all (a check's own summary,
    # `FAIL: convention violations found`) cannot be told from the passed check's own output, so it does not count
    # against it; a line naming a script that did not pass on the base is other work a base merge leaves.
    whole = True
    for _, job, found in seen:
        extra = sorted((head.errors - found.errors).elements())
        if not extra:
            return None
        asked = {marker for error in extra for marker in sub_checks(error)}
        log = github.log(repo, job) or ""
        asked = {marker for marker in asked if check_passed_in(log, marker)}
        if not asked:
            return None
        whole = whole and not any(sub_checks(error) and not (sub_checks(error) & asked) for error in extra)
        markers = asked if not markers else markers & asked
        if not markers:
            return None
    # No base verdict was read at all (every log read failed): there is nothing to name.
    if not seen or not markers:
        return None
    if head.steps - sum((found.steps for _, _, found in seen), Counter()):
        whole = False  # a failed step of its own, beside these lines
    run = seen[0][0]
    url = run.get("html_url") or f"https://github.com/{repo}/actions/runs/{run['id']}"
    said = "; ".join(sorted(markers))[:200]
    raise Refused(f"'{name}': {base} run {run['id']} ran {said} in '{name}' and it passed there ({url}), so this red "
                  f"is not {base}'s"
                  + (f"; when {base} fixed what it reports after this PR's merge-base, merge {base} into the branch "
                     "and the red goes" if whole
                     else f"; {base} may have fixed what it reports after this PR's merge-base, and this head fails "
                          "more besides, which a base merge does not clear"))



# A setup red another pull request shares (2026-11-15, cmux#41892 at d1631b27, run 43737949394). ios-e2e.yml runs on
# pull requests only, so no feat-cmux-next run has a verdict for its jobs, and each red of them was refused as "no
# feat-cmux-next run of its workflow has a verdict for it to compare with", infrastructure reds that hit every PR whose
# changes trigger it too: 'backend' failed 'Join tailnet' (`sudo failed with exit code 1`, after the Tailscale OIDC
# exchange's 403: hq#10808) and 'mac-ios-e2e' failed 'Install build prerequisites' (`cameroncooke/axe/axe: undefined
# method 'run' for an instance of Homebrew::InstallSteps::DSL`: cmux#43820), and cmux#43755's run 43737950292 failed
# both the same way. With no base verdict, such a red is excused only as a setup red another PR fails the same way:
# - the PR does not change the workflow file, and its steps are read from the workflow at the merge-base, never the
#   head's own edit of it (a PR could rename or reorder a step into "setup"); the PR's changed files and commits are
#   read from one compare with the base, refused when GitHub lists fewer than the PR has (COMPARE_FILES_CAP);
# - every failed step of the job failed (a cancelled or timed-out step is no verdict; a crash or a cut-short run was
#   refused by read_head, a cancelled job by judge) and is a workflow step before the job's first test step in its
#   workflow's own step order (StepNames.specs), and is no test step itself: one whose name says it tests
#   (TEST_STEP_NAME) or whose script starts a test runner (runs_tests). A job with no test step (the backend) only
#   sets up another job's tests;
# - every failed step runs no code the PR can change (runs_no_pr_code): a `uses:` step of an action outside the
#   repository (not `./...`), or a step SETUP_ONLY_STEPS names, whose scripts the PR does not change. Every other step
#   before the tests runs the PR's code and its error lines are generic: PR #43876's review (FIX FIRST at b7f6aff6c64,
#   issuecomment-6899154268): 'Start per-run backend' serves the PR's workers and fails on `backend health: iroh-v2
#   never answered at ...`, 'Wait for the per-run backend' and 'Sign in and pair simulator' fail on the PR's own
#   backend or sign-in in words an outage prints too, and 'Install dependencies' fails on a stale lockfile the same
#   way on any two PRs. Excused by another PR's identical line, a PR that breaks its backend would land, and each later
#   PR would excuse the next, since iOS E2E never runs on the base;
# - each of those steps' error lines, masked (step_errors, normalise_error; read whole when step_owners cannot place
#   the log, only for a job with one failed step), is printed by the step of the same name, failed, in the job of the
#   same name, failed, of one run of the same workflow for another pull request: another head branch, and PR numbers
#   none of which is the head's (a run that names no PR is no evidence), completed in the last OTHER_PR_HOURS. A run
#   of this PR never counts, nor a log that crashed or was cut short, nor a run of a commit that shares a commit with
#   this PR beyond the base (one is the other's ancestor, or their merge-base is one of this PR's commits: a stacked
#   lane, a reland, two lanes of one change), told by one compare of the two heads (shares_commits);
# - the match is on step names and error lines alone: a PR's title, body or branch name is never read for one;
# - the reads are bounded: one list of the workflow's failed pull_request runs (OTHER_PR_LIST, newest first), at most
#   OTHER_PR_RUNS job lists (base_run_jobs, its disk cache) and OTHER_PR_LOGS logs, each read once per judgement.
# An aggregate of such jobs (ios-e2e-status, a run rollup of ROLLUPS_FILE) is judged by its failed children, each as
# itself (head_jobs), so it is excused only when every one is.
OTHER_PR_HOURS = 24
OTHER_PR_LIST = 50
OTHER_PR_RUNS = 8
OTHER_PR_LOGS = 4
# A pull request's run comes from `pull_request` or from `pull_request_target`, and a workflow triggered by one has no
# run of the other anywhere: every listing of another PR's runs of the workflow names the red run's own event
# (2026-11-22, cmux#50878: cla-policy-guard.yml is triggered by pull_request_target alone, so `event=pull_request`
# listed none of its runs, no other PR could ever be found, and its red was refused here on every PR, for ever;
# handoff cmux#51045, leo-workspace#8742 fixes the same gap in land-judge's pr_only_peer_excuse).
PR_EVENTS = ("pull_request", "pull_request_target")


def peer_event(run: dict) -> str:
    """The event another PR's run of RUN's workflow must have: RUN's own when it is a pull request's (PR_EVENTS)."""
    event = str(run.get("event") or "")
    return event if event in PR_EVENTS else "pull_request"


TEST_STEP_NAME = re.compile(r"(?i)\b(?:tests?|testing|e2e|specs?|suites?)\b")
# A test runner a step's script starts (runs_tests), read word by word so no pattern rescans a script: a runner by
# name, a build tool's test verb, or a script whose file name says it tests.
TEST_RUNNERS = frozenset({"pytest", "vitest", "jest", "ctest", "xctest"})
TEST_VERB_TOOLS = frozenset({"swift", "cargo", "go", "bun", "deno", "npm", "pnpm", "yarn", "xcodebuild"})
TEST_VERBS = frozenset({"test", "nextest", "test-without-building"})
SCRIPT_WORD = re.compile(r"[^\s;|&()<>'\"`]+")


def runs_tests(script: str) -> bool:
    """Whether SCRIPT, a workflow step's `run:`, starts a test runner (TEST_RUNNERS; a TEST_VERB_TOOLS tool given a
    TEST_VERBS verb; a .sh or .py file whose name has `test` or `e2e-run` in it)."""
    words = [word.rsplit("/", 1)[-1].lower() for word in SCRIPT_WORD.findall(script)]
    if any(word in TEST_RUNNERS or (word.endswith((".sh", ".py")) and ("test" in word or "e2e-run" in word))
           for word in words):
        return True
    return bool(TEST_VERB_TOOLS & set(words)) and bool(TEST_VERBS & set(words))


# The steps before a workflow's tests that run a script of the repository and still run no code the PR can change, by
# workflow file: {step name: every repository path it reads}: the scripts it runs, the files and submodules they
# source, run or read, and the toolchain pins it runs under. Excused only while the PR changes none of them. PR
# #43876's second review (FIX FIRST at f5c717cd260, issuecomment-6899360740): listing only the scripts let a PR that
# bumps .xcode-version past its pool's Xcode fail 'Select Xcode' with the same masked floor line a runner image
# missing the pin prints, and be excused. tests/test_base_red_excuse.py's SetupOnlyStepsReadNothingUnlisted scans the
# scripts for the repository paths they read and fails on one no entry lists.
XCODE_PINS = (".xcode-version", "scripts/ci/xcode-pins.txt")  # select-ci-xcode.sh's: the Xcode every later step runs
SETUP_ONLY_STEPS = {
    ".github/workflows/ios-e2e.yml": {
        # Installs build tools: zig (install-zig-ci.sh: its version from ghostty-zig-version.sh and the submodules'
        # build.zig.zon, the reviewed versions from toolchains.json and the Zig SDK's build.zig.zon, the tarball's
        # sha256 from zig-tarballs.sha256), the prebuilt GhosttyKit for the pinned ghostty submodule
        # (download-prebuilt-ghosttykit.sh, through the LAN cache broker when there is one: lan_cache_fetch.py; else
        # ensure-ghosttykit.sh: the checksum manifest, the archive validator,
        # ghostty.h, ensure-metal-toolchain.sh) and AXe (install-axe-ci.sh), under the selected Xcode. No app, worker or
        # test code.
        "Install build prerequisites": (
            "scripts/install-zig-ci.sh", "scripts/ghostty-zig-version.sh", "scripts/ci/zig-tarballs.sha256",
            "cmux-tui/build-support/notices/toolchains/toolchains.json", "cmux-tui/bindings/zig/build.zig.zon",
            "scripts/download-prebuilt-ghosttykit.sh", "scripts/ci/lan_cache_fetch.py", "scripts/ensure-ghosttykit.sh",
            "scripts/ghosttykit-checksums.txt", "scripts/validate-xcframework-archive.py",
            "scripts/ensure-metal-toolchain.sh", "ghostty.h", "ghostty", "ghostty-next", ".gitmodules",
            "scripts/install-axe-ci.sh",
            # ensure-ghosttykit.sh's Zig package prefetch (zig-fetch-all.sh): the package lock, its R2 mirror and
            # cache, the archive seeder, and the release download helper behind them.
            "scripts/cmux-next/zig-fetch-all.sh", "scripts/ci/zig-packages.lock", "scripts/ci/zig-packages-r2.sh",
            "scripts/ci/seed-zig-package-archives.sh", "scripts/ci/r2-cache.sh",
            "scripts/ci/github-release-download.sh", "scripts/ci/github_release_asset.py", *XCODE_PINS),
        # Picks the runner's Xcode from the pins (toolchain setup).
        "Select Xcode": ("scripts/select-ci-xcode.sh", *XCODE_PINS),
        # xcrun and xcodebuild only, of the selected Xcode: the runner's simulator runtime (toolchain setup).
        "Ensure iOS simulator runtime": XCODE_PINS,
    },
}
# The checkout action fetches the submodules .gitmodules names at the commits the PR pins: a PR that changes either
# can fail it on its own (a pin that cannot be fetched), so its red is then never excused (runs_no_pr_code). So can a
# gitlink the PR adds or moves without a .gitmodules entry (`fatal: No url found for submodule path ...`, #43915):
# every changed path the compare shows as a submodule, or cannot show as a file, counts as one (compare_gitlinks).
CHECKOUT_ACTION = "actions/checkout@"
SUBPROJECT_LINE = re.compile(r"(?m)^[-+ ]?Subproject commit [0-9a-f]")


def gitmodule_paths(text: str | None) -> frozenset[str]:
    """The submodule paths a .gitmodules TEXT names (None: none)."""
    return frozenset(match[1] for match in re.finditer(r"(?m)^[ \t]*path[ \t]*=[ \t]*(\S+)[ \t]*$", text or ""))


def compare_gitlinks(files: list) -> frozenset[str]:
    """The paths of compare FILES entries that are, or may be, a submodule (a gitlink, mode 160000), whether or not
    .gitmodules names it: a PR that adds one without an entry there fails Checkout on its own (#43915). GitHub's
    compare serves no file mode; a gitlink's entry has no blob_url or raw_url (null) and a `Subproject commit <sha>`
    patch, so an entry with either sign, or without a blob URL at all, counts as one (and its previous path too)."""
    return frozenset(path for found in files if isinstance(found, dict)
                     and (not isinstance(found.get("blob_url"), str) or not found.get("blob_url")
                          or SUBPROJECT_LINE.search(str(found.get("patch") or "")))
                     for path in (found.get("filename"), found.get("previous_filename")) if isinstance(path, str))


def runs_no_pr_code(spec: dict, path: str, title: str, changed: set[str],
                    submodules: Callable[[], frozenset[str]]) -> str | None:
    """None when workflow step SPEC (TITLE, of workflow PATH, as declared at the merge-base) runs no code a PR with
    CHANGED paths can change: a `uses:` action outside the repository (the checkout action only while the PR changes
    neither .gitmodules nor a submodule SUBMODULES() names: .gitmodules' at the merge-base, and each gitlink the PR
    changes), or a SETUP_ONLY_STEPS step whose paths are unchanged;
    else why it runs the PR's code."""
    uses = spec.get("uses")
    if isinstance(uses, str):
        if uses.strip().startswith("./"):
            return f"its failed step '{title}' runs the PR's code (the local action {uses.strip()})"
        if uses.strip().startswith(CHECKOUT_ACTION) and (pins := sorted(changed & ({".gitmodules"} | submodules()))):
            return f"its failed step '{title}' checks out submodules this PR changes ({', '.join(pins)[:300]})"
        return None
    listed = SETUP_ONLY_STEPS.get(path, {})
    if title not in listed:
        return (f"its failed step '{title}' runs the PR's code (a `run:` step, and not one {path}'s SETUP_ONLY_STEPS "
                "names as running none)")
    if touched := sorted(file for file in changed if any(file == own or file.startswith(own + "/")
                                                         for own in listed[title])):
        return f"its failed step '{title}' runs files this PR changes ({', '.join(touched)[:300]})"
    return None


def shares_commits(repo: str, other: str, sha: str, mine: set[str], github) -> bool:
    """Whether OTHER, another PR's tested commit, shares a commit with SHA beyond the base: one is the other's
    ancestor, or their merge-base is one of MINE (SHA's commits beyond its own merge-base). One compare read."""
    if other == sha:
        return True
    found = github.json(f"repos/{repo}/compare/{other}...{sha}?per_page=1")
    if not isinstance(found, dict) or found.get("status") in (None, "identical", "ahead", "behind"):
        return True  # unread is shared: never evidence
    return str((found.get("merge_base_commit") or {}).get("sha") or "") in mine


def completed(job: dict) -> datetime | None:
    """JOB's completed_at, or None when it is not a time with its zone (never compared with an aware now)."""
    try:
        when = datetime.fromisoformat(str(job.get("completed_at")).replace("Z", "+00:00"))
    except ValueError:
        return None
    return when if when.tzinfo is not None else None


def setup_red_steps(job: dict, names, path: str, changed: set[str],
                    submodules: Callable[[], frozenset[str]] = frozenset) -> "tuple[list[str], str | None] | str":
    """(the names of JOB's failed steps, in order, and its first test step after them or None) when each is a setup
    step that runs no PR code (runs_no_pr_code, PATH its workflow, CHANGED the PR's paths) by the rule above, NAMES
    the workflow's step names at the merge-base; else why not."""
    specs = getattr(names, "specs", None)
    if not specs:
        return "its steps could not be matched to its workflow's, so no step is known to run before its tests"
    failed: list[str] = []
    first_test = None
    for step in sorted(job.get("steps") or [], key=lambda step: step.get("number")
                       if isinstance(step.get("number"), int) else -1):
        title = str(step.get("name") or "")  # step-name: classify
        spec = specs.get(step.get("number"))
        testing = spec is not None and bool(TEST_STEP_NAME.search(title)
                                            or runs_tests(str(spec.get("run") or "")))
        if step.get("conclusion") not in (None, "success", "skipped"):
            if step.get("conclusion") != "failure":
                return f"its step '{title}' is {step.get('conclusion')}, no verdict"
            if spec is None:
                return f"its failed step '{title}' is the runner's, not its workflow's"
            if testing:
                return f"its failed step '{title}' runs tests"
            if first_test is not None:
                return f"its failed step '{title}' runs after its test step '{first_test}'"
            if (why := runs_no_pr_code(spec, path, title, changed, submodules)) is not None:
                return why
            failed.append(title)
        if testing and first_test is None:
            first_test = title
    return (failed, first_test) if failed else "no step of it failed"


def setup_errors(view: "FailedView | Unplaced", whole: "UnplacedSignature | None",
                 steps: list[str]) -> set[tuple[str, str]] | None:
    """(failed step, error line masked) for each of STEPS, a job's failed setup steps: VIEW's own (step_errors), or,
    for an unplaced VIEW of one failed step, WHOLE's error lines (its unplaced_signature), that step's; None when a
    step prints no error line or no line can be charged to its step."""
    if view is UNPLACED:
        if whole is None or len(steps) != 1:
            return None
        pairs = {(steps[0], error) for error in whole.errors}
    else:
        pairs = {(step, error) for step, error in step_errors(view) if step in steps}
    return pairs if {step for step, _ in pairs} == set(steps) else None


def other_pr_setup_verdict(repo: str, base: str, name: str, job: dict, head: "Head", workflow_info: dict,
                           workflow: int, github, run_reads: dict, evidence: "Evidence") -> tuple[bool, str]:
    """(True, the audit line) for red head JOB (NAME, read as HEAD by read_head), whose workflow (WORKFLOW, its run
    WORKFLOW_INFO) has no BASE verdict, when it is a setup red another pull request's run fails the same way (the rule
    above); else (False, why not)."""
    path = str(workflow_info.get("path") or "").split("@", 1)[0]
    # The head's own step names first (read by read_head already): a red no rule here can excuse costs no read.
    if isinstance(why := setup_red_steps(job, job_step_names(repo, job, github, run_reads), path, set()), str):
        return False, why
    sha = str(job.get("head_sha") or "")
    diff = github.json(f"repos/{repo}/compare/{base}...{sha}")
    files, commits = diff.get("files"), diff.get("commits")
    merge_base = evidence.merge_base(sha, diff)
    if (not re.fullmatch(r"[0-9a-f]{40}", merge_base) or not isinstance(files, list) or not isinstance(commits, list)
            or len(files) >= COMPARE_FILES_CAP or diff.get("total_commits", len(commits)) != len(commits)):
        return False, f"its changed files and commits against {base} could not be read in full"
    # A rename counts at both paths: a PR that moves a listed script away changes it (#43915).
    changed = {str(name) for file in files if isinstance(file, dict)
               for name in (file.get("filename"), file.get("previous_filename")) if name is not None}
    gitlinks = compare_gitlinks(files)
    if path in changed:
        return False, f"this PR changes its workflow ({path}), so no step of it is known to be the base's setup"
    # The workflow as the base declares it, at the merge-base: its step order and each step's `uses:` or script.
    setup = setup_red_steps(job, workflow_step_names(repo, dict(job, head_sha=merge_base), path, github, run_reads),
                            path, changed,
                            lambda: gitlinks | gitmodule_paths(source_text_if_present(repo, merge_base, ".gitmodules",
                                                                                      github)))
    if isinstance(setup, str):
        return False, setup
    steps, first_test = setup
    mine = setup_errors(head.view, head.unplaced, steps)
    branch = workflow_info.get("head_branch")
    numbers = {pull.get("number") for pull in workflow_info.get("pull_requests") or [] if isinstance(pull, dict)}
    if not mine or not branch:
        return False, "its failed setup steps print no error line to match, or its run names no branch"
    own_commits = {str(commit.get("sha")) for commit in commits if isinstance(commit, dict)}
    shared = 0
    event = peer_event(workflow_info)
    listed = github.json(f"repos/{repo}/actions/workflows/{workflow}/runs?event={event}&status=failure"
                         f"&per_page={OTHER_PR_LIST}")
    now, window = datetime.now().astimezone(), timedelta(hours=OTHER_PR_HOURS)
    runs = sorted((run for run in (listed.get("workflow_runs") if isinstance(listed, dict) else None) or []
                   if isinstance(run, dict)), key=lambda run: run.get("created_at") or "", reverse=True)
    reads = logs = 0
    for run in runs:
        theirs = {pull.get("number") for pull in run.get("pull_requests") or [] if isinstance(pull, dict)}
        if (run.get("event") != event or run.get("id") == job.get("run_id")
                or run.get("head_branch") in (None, branch) or not theirs or theirs & numbers):
            continue  # this PR's own run, or one that names no other PR
        if reads >= OTHER_PR_RUNS or logs >= OTHER_PR_LOGS:
            break
        reads += 1
        for other in base_run_jobs(repo, run, github):
            failed = {step for step, conclusion in failed_step_keys(other) if conclusion == "failure"}
            if (other.get("name") != name or other.get("conclusion") != "failure" or not set(steps) <= failed
                    or (when := completed(other)) is None or now - when > window):
                continue
            if logs >= OTHER_PR_LOGS:
                break
            logs += 1
            other = dict(other, run_id=other.get("run_id") or run["id"])
            text = github.log(repo, other)
            own = test_reds.read(text)
            if own.crashes or [why for why in own.truncated if not why.startswith(test_reds.UNNAMED_WHY)]:
                continue  # a crash or a cut-short run is no evidence
            view = failed_view(other, text, step_names=workflow_step_names(repo, other, run.get("path"), github,
                                                                           run_reads), base=True)
            found = setup_errors(view, unplaced_signature(other, text) if view is UNPLACED else None,
                                 sorted(failed) if view is UNPLACED else steps)
            if found is None or not mine <= found:
                continue
            tested = str(run.get("head_sha") or other.get("head_sha") or "")
            if not re.fullmatch(r"[0-9a-f]{40}", tested) or shares_commits(repo, tested, sha, own_commits, github):
                shared += 1  # the same change on two PRs never excuses itself
                continue
            url = run.get("html_url") or f"https://github.com/{repo}/actions/runs/{run['id']}"
            said = "; ".join(f"'{step}': {error}" for step, error in sorted(mine))
            before = f"its first test step '{first_test}'" if first_test else "any test step (the job runs none)"
            return True, (f"excused '{name}': not this PR (a setup red other PRs share): no {base} run of its "
                          f"workflow has a verdict, and its failed setup step{'s' if len(steps) > 1 else ''} "
                          f"({'; '.join(steps)}), before {before}, runs no code this PR changes and failed the same "
                          f"way in PR #{', #'.join(str(n) for n in sorted(theirs))}'s run {run['id']} ({url}), job "
                          f"{other.get('id')}, completed {other.get('completed_at')}, tested {tested[:12]}, which "
                          f"shares no commit with this PR: {said[:500]}")
    return False, ("no other PR's run of its workflow in the last "
                   f"{OTHER_PR_HOURS} h failed its setup steps ({'; '.join(steps)}) the same way"
                   + (f" (the {shared} that did share commits with it)" if shared else ""))


# A red of a workflow with no base verdict, read against other pull requests' heads (2026-11-21, docs/handbook in
# cmuxterm-hq: pr-only-workflow-has-no-base-verdict.md). A workflow that runs on pull requests only (ios-e2e.yml since
# cmux#42973) never runs on a base push, so every red of it was refused here as "no feat-cmux-next run of its
# workflow has a verdict for it to compare with" unless other_pr_setup_verdict matched it line for line: cmux#45422,
# hq#13487 and glaeda#2103 were refused that way for a red every PR into the base shared, while land-judge's
# pr_only_peer_excuse (leo-workspace tools/land_judge/engine.py) let the same red through. One rule for both judges,
# with land-judge's constants and path patterns:
# - a red job is the workflow's, not this PR's, when the same job failed at the same first failed step (or at none on
#   both) on PR_ONLY_PEERS other PRs' heads into the same base, each in its newest completed run of the workflow under
#   the red run's own event (pull_request, or pull_request_target: a workflow triggered by the latter alone has no
#   pull_request run anywhere), completed in the last OTHER_PR_HOURS. Any failed step counts, not only a setup step:
#   a PR that breaks the app fails a later step (the tests) than an outage (a tailnet, a brew install), so the two do
#   not match;
# - the workflow's files are its .yml and every repo path its text at the head names (workflow_files: WORKFLOW_PATH,
#   under .github/ or scripts/, or a script or config file by its extension; a named directory stands for every file
#   under it). A PR that changes one of them is never excused this way: it must be green on the workflow. A peer that
#   changes one is no witness;
# - a peer is another PR: distinct PR numbers, never one of this PR's, never this branch or this head; a peer that
#   shares a commit with this PR beyond the base (shares_commits) is no witness, nor one whose changed files cannot
#   be read in full from one compare with the base (COMPARE_FILES_CAP);
# - the reads are bounded as land-judge's are: one list of the workflow's PR_ONLY_PEER_RUNS newest completed
#   runs of the red run's event, at most PR_ONLY_PEER_READS job lists (base_run_jobs, its disk cache), and the
#   compares only once PR_ONLY_PEERS heads have matched on the job lists. No log and no PR text is read.
PR_ONLY_PEERS = 3  # other PRs' heads that must fail the same job at the same step
PR_ONLY_PEER_RUNS = 30  # the workflow's newest completed runs of the red run's event listed
PR_ONLY_PEER_READS = 10  # job lists read among them at most
PR_ONLY_RED = frozenset({"failure", "timed_out", "startup_failure"})
# A peer run that ended with no verdict (skipped: a labeled or edited event the workflow's own `if:` turns away;
# cancelled: superseded by the PR's next push) is passed over: it neither spends one of PR_ONLY_PEER_READS nor stands
# for its PR's newest run. pr-router.yml (no feat-cmux-next run) had 17 skipped and 1 cancelled among its 30 newest
# completed pull_request runs on 2026-11-26 12:58Z, so the ten reads met few failed runs, and #58337 and #58408 needed
# LAND_JUDGE_OVERRIDE for a 'pr pipeline / linux' red that failed the same way on #56579, #58486 and #58590.
# land-judge's pr_only_peer_excuse got the same rule (leo-workspace#12031).
PR_ONLY_NO_VERDICT_RUN = frozenset({"skipped", "cancelled", "neutral", "stale", "action_required"})
# A repo path a workflow names: two or more segments, not a variable's ($RUNNER_TEMP/x), a URL's or another path's
# tail. Kept when it is under .github/ or scripts/, or names a script or config file (its extension).
WORKFLOW_PATH = re.compile(r"(?<![\w$/.:@{}-])(?:\./)?((?:[\w-][\w.-]*/)+[\w.-]*[\w-])")
WORKFLOW_PATH_EXT = re.compile(r"\.(?:sh|bash|py|js|mjs|cjs|ts|swift|rb|zig|ya?ml|json|toml)$")


def workflow_files(path: str, text: str) -> list[str]:
    """The workflow at PATH and every repo path its TEXT names (WORKFLOW_PATH): the files whose change makes the
    workflow's red the PR's own. A named directory (scripts/e2e) stands for every file under it."""
    found = {path}
    for match in WORKFLOW_PATH.finditer(text or ""):
        named = match.group(1).rstrip("/")
        if named.startswith((".github/", "scripts/")) or WORKFLOW_PATH_EXT.search(named) or "/scripts/" in named:
            found.add(named)
    return sorted(found)


def workflow_file_hits(files, owned: list[str]) -> list[str]:
    """The FILES that are one of OWNED or under one of them (a directory)."""
    return sorted({f for f in files for p in owned if f == p or f.startswith(p.rstrip("/") + "/")})


def first_red_step(job: dict) -> str | None:
    """The name of JOB's first failed step (PR_ONLY_RED), by step number, or None when no step failed."""
    for step in sorted((step for step in job.get("steps") or [] if isinstance(step, dict)),
                       key=lambda step: step.get("number") if isinstance(step.get("number"), int) else -1):
        if str(step.get("conclusion") or "").lower() in PR_ONLY_RED:
            return str(step.get("name") or "")  # step-name: classify
    return None


def changed_in_full(repo: str, base: str, sha: str, github) -> tuple[set[str], set[str]] | None:
    """(the paths SHA changes against BASE, a rename at both paths; its commits beyond the base) from one compare, or
    None when GitHub lists fewer than it has (COMPARE_FILES_CAP) or the answer cannot be read."""
    diff = github.json(f"repos/{repo}/compare/{base}...{sha}")
    files, commits = (diff.get("files"), diff.get("commits")) if isinstance(diff, dict) else (None, None)
    if (not isinstance(files, list) or not isinstance(commits, list) or len(files) >= COMPARE_FILES_CAP
            or diff.get("total_commits", len(commits)) != len(commits)):
        return None
    return ({str(name) for file in files if isinstance(file, dict)
             for name in (file.get("filename"), file.get("previous_filename")) if name is not None},
            {str(commit.get("sha")) for commit in commits if isinstance(commit, dict)})


def other_pr_peer_verdict(repo: str, base: str, name: str, job: dict, workflow_info: dict, workflow: int,
                          github) -> tuple[bool, str]:
    """(True, the audit line) for red head JOB (NAME), whose workflow (WORKFLOW, its run WORKFLOW_INFO) has no BASE
    verdict, when it failed at the same first failed step on PR_ONLY_PEERS other PRs' heads that change none of the
    workflow's files, and this PR changes none either (the rule above); else (False, why not)."""
    path = str(workflow_info.get("path") or "").split("@", 1)[0]
    sha = str(job.get("head_sha") or workflow_info.get("head_sha") or "")
    if not path or not re.fullmatch(r"[0-9a-f]{40}", sha):
        return False, "its run names no workflow file or head commit"
    try:
        own = changed_in_full(repo, base, sha, github)
        owned = workflow_files(path, source_text(repo, sha, path, github)) if own is not None else []
    except Refused as why:
        return False, f"its changed files or its workflow could not be read ({str(why)[:200]})"
    if own is None:
        return False, f"its changed files and commits against {base} could not be read in full"
    changed, own_commits = own
    if mine := workflow_file_hits(changed, owned):
        return False, (f"this PR changes the workflow's files ({', '.join(mine)[:300]}), so its red is its own: it "
                       "must be green on it")
    step = first_red_step(job)
    said = f"at step '{step}'" if step is not None else "at no step"
    branch = workflow_info.get("head_branch")
    numbers = {str(pull.get("number")) for pull in workflow_info.get("pull_requests") or [] if isinstance(pull, dict)}
    event = peer_event(workflow_info)
    listed = github.json(f"repos/{repo}/actions/workflows/{workflow}/runs?event={event}&status=completed"
                         f"&per_page={PR_ONLY_PEER_RUNS}")
    runs = sorted((run for run in (listed.get("workflow_runs") if isinstance(listed, dict) else None) or []
                   if isinstance(run, dict)), key=lambda run: run.get("created_at") or "", reverse=True)
    now, window = datetime.now().astimezone(), timedelta(hours=OTHER_PR_HOURS)
    matched: list[str] = []
    pending: list[tuple[str, str]] = []  # (PR number, head) matched on its job list, its compares not read yet
    aside: Counter = Counter()  # why a matching head was no witness
    seen: set[str] = set()
    reads = 0
    for run in runs[:PR_ONLY_PEER_RUNS]:
        if len(matched) >= PR_ONLY_PEERS or reads >= PR_ONLY_PEER_READS:
            break
        if str(run.get("conclusion") or "").lower() in PR_ONLY_NO_VERDICT_RUN:
            continue  # no verdict: no read spent, and the PR's newest run with one still stands for it
        theirs = [str(pull.get("number")) for pull in run.get("pull_requests") or [] if isinstance(pull, dict)
                  and ((pull.get("base") or {}).get("ref")) == base]
        tested = str(run.get("head_sha") or "")
        if (run.get("event") != event or run.get("id") == job.get("run_id") or tested == sha
                or run.get("head_branch") in (None, branch) or not theirs or set(theirs) & numbers
                or theirs[0] in seen or not re.fullmatch(r"[0-9a-f]{40}", tested)):
            continue  # this PR's own run, one into another base or naming no PR, or a PR already read
        seen.add(theirs[0])  # each PR's newest run alone
        reads += 1
        found = [other for other in base_run_jobs(repo, run, github) if other.get("name") == name]
        if (len(found) != 1 or str(found[0].get("conclusion") or "").lower() not in PR_ONLY_RED
                or first_red_step(found[0]) != step or (when := completed(found[0])) is None
                or now - when > window):
            continue
        pending.append((theirs[0], tested))
        while pending and len(matched) < PR_ONLY_PEERS <= len(matched) + len(pending):
            number, other = pending.pop(0)
            try:
                if shares_commits(repo, other, sha, own_commits, github):
                    aside["shares a commit with this PR"] += 1
                    continue
                files = changed_in_full(repo, base, other, github)
            except Refused:
                files = None
            if files is None:
                aside["its changed files could not be read in full"] += 1
            elif workflow_file_hits(files[0], owned):
                aside["changes the workflow's files"] += 1
            else:
                matched.append(f"#{number} at {other[:12]}")
    if len(matched) >= PR_ONLY_PEERS:
        return True, (f"excused '{name}': not this PR (its workflow's red on other PRs): no {base} run of its workflow "
                      f"has a verdict, and '{name}' failed {said} the same way on {', '.join(matched)}, other PRs' "
                      f"heads into {base} in the last {OTHER_PR_HOURS} h that share no commit with this PR and, like "
                      f"it, change none of the workflow's {len(owned)} file(s) ({path} and the paths it names)")
    # A head matched on its job list alone is named too: too few to excuse, its compares were never read.
    named = matched + [f"#{number} at {other[:12]}" for number, other in pending]
    return False, (f"'{name}' failed {said} the same way on {len(named)} other PR head(s) "
                   f"({', '.join(named) or 'none'}), under {PR_ONLY_PEERS}, in {reads} of its workflow's newest "
                   f"completed pull_request runs read"
                   + (f" ({'; '.join(f'{n} {why}' for why, n in sorted(aside.items()))}: no witness)" if aside else ""))


# A compiler or lint red another base job prints (2026-11-12, cmux#40935 at d2e676e6 and #41633): e0d3bb0ec2f left
# `error: variant `RootEntries` is never constructed` (cmux-tui/crates/acpmux/src/chats/watch.rs, built on Linux only)
# red on feat-cmux-next's 'clippy (changed cmux-tui packages)'. A PR that changes acpmux also runs 'acpmux simulation
# (seeds)', whose `cargo clippy -p acpmux --features sim --test sim` step fails on that same error; base pushes skip
# that step (they do not change acpmux's test inputs), so the job is green on base and the red was refused as the PR's
# own, and the two logs never matched line for line anyway (times, run paths, line numbers, order and the other
# errors differ). Such a red is the base's when every compiler error it prints is one error a red base job prints, in
# a file the PR does not change. An error is compared by its signature (compile_errors): the rustc or clippy error code,
# the file its `-->` line names (repo_path: the checkout root masked, never the line or column), and its message with
# numbers and shas masked (normalise_error, so a file name keeps its digits). Strict, so a PR's own error never hides:
# - every error line of the head's red (its failed sections, or its whole log when step_owners cannot place it) is such
#   a located diagnostic, or the summary cargo prints after one (`could not compile ...`, `aborting due to ...`: never
#   compared, since its count differs whenever the base job prints more errors); any other error line, a failing
#   test, a crash, a panic ratchet row or a runner's unnamed failure leaves the red to the rules above;
# - each failed step of the head job was skipped, absent or failed in the base verdict of the same job: a step the base
#   ran and passed is the PR's own red;
# - ONE red base job, in one run of the workflow in the window (BASE_WINDOW job lists within BASE_WINDOW_HOURS of the
#   newest, COMPILE_ERROR_LOGS logs), prints every head signature; a job that passed in a newer base run is fixed
#   from there back and never counts (pr_only_step_verdict's rule);
# - no file a signature names is one the PR changes (pr_paths; cargo prints a path from its workspace, so a PR path
#   that ends with it, or that it ends with, is the same file).
DIAGNOSTIC = re.compile(r"^error(?:\[(?P<code>[A-Z]\d{4})\])?: (?P<message>\S.*)$")
DIAGNOSTIC_AT = re.compile(r"^\s*--> (?P<path>\S.*?):\d+(?::\d+)?\s*$")
DIAGNOSTIC_SUMMARY = re.compile(r"^error: (?:could not compile `[^`]+`|aborting due to )")
# The lines .github/scripts/cmux-tui-clippy-changed.py prints after clippy's own: the run's scope, and each red file
# outside the diff with the base commit that last changed it. They name no error of their own (each is a located
# diagnostic above them), and differ between a PR and the base by scope and commit, so they are never compared; the
# file a base-red line names must still be one the PR does not change.
# Since lints stopped failing the check (2026-11-20) the scope line says "clippy found compile errors in"; older
# base logs still say "clippy -D warnings failed for", so both are read.
CLIPPY_SCOPE = re.compile(r"^##\[error\]clippy (?:-D warnings failed for|found compile errors in) [^;]+; run `cargo clippy ")
CLIPPY_BASE_RED = re.compile(r"^##\[error\](?P<path>\S+) is red and this change does not touch it: ")
COMPILE_ERROR_LOGS = 6  # base job logs read for one red, at most


class CompileErrors(NamedTuple):
    located: frozenset  # (error code or "", repo_path of the file, message with numbers masked)
    summaries: frozenset  # cargo's summary lines, numbers masked: read, never compared
    other: tuple  # every other error line: a red that has one is not judged by its compile errors
    named: frozenset  # the files the clippy wrapper's base-red lines name (CLIPPY_BASE_RED)
    counts: Counter  # how often each located signature is printed: a base error once is not the PR's twice


def compile_errors(lines: list[str], job: dict) -> CompileErrors:
    """CompileErrors of LINES (a job's lines with stamps, colours and script echoes removed): each error line the
    classifier reads (the filter unplaced_signature applies), sorted into located diagnostics, summaries and the rest."""
    located, summaries, other, named, counts = set(), set(), [], set(), Counter()
    for n, line in enumerate(lines):
        if line.startswith(test_reds.TAP_MARKER) or SUMMARY_RED.match(line) or SOURCE_EXCERPT.match(line):
            continue
        if not ((ERROR.search(line) or DIAGNOSTIC.match(line.strip())  # `error[E0425]:` has no `error:`
                 or ((marker := JOB_ERROR.get(job.get("name", ""))) is not None and marker.search(line))
                 or SHELL_FAIL.match(line))
                and not GENERIC.search(line) and not WARNING.search(line) and not CRASH_LINE.search(line)
                and not SUCCESS_DIAGNOSTIC.search(line) and not BENIGN.match(line)):
            continue
        said = line.strip()
        if CLIPPY_SCOPE.match(said):
            continue
        if (wrapper := CLIPPY_BASE_RED.match(said)) is not None:
            named.add(repo_path(wrapper["path"]))
            continue
        if DIAGNOSTIC_SUMMARY.match(said):
            summaries.add(normalise_error(said))
            continue
        found = DIAGNOSTIC.match(said)
        # rustc prints a diagnostic's `-->` on the line right after its header. Only that line is its location: a
        # later one may be another diagnostic's (an unlocated error before a warning's `-->`, Codex F1 on #42028).
        at = DIAGNOSTIC_AT.match(lines[n + 1]) if found and n + 1 < len(lines) else None
        if found is None or at is None:
            other.append(said)
            continue
        key = (found["code"] or "", repo_path(at["path"]), normalise_error(found["message"]))
        located.add(key)
        counts[key] += 1
    return CompileErrors(frozenset(located), frozenset(summaries), tuple(other), frozenset(named), counts)


def signature_text(error: tuple) -> str:
    code, path, message = error
    return f"{path}: {'[' + code + '] ' if code else ''}{message}"


def touched_by(path: str, changed: list[str]) -> list[str]:
    """The PR paths in CHANGED that are the file PATH names: the same path, or one that ends with the other at a
    directory boundary (cargo prints `crates/x/src/a.rs` for `cmux-tui/crates/x/src/a.rs`)."""
    said = path.lstrip("/")
    return [p for p in changed if p == said or p.endswith("/" + said) or said.endswith("/" + p)]


def compile_errors_verdict(repo: str, base: str, sha: str, name: str, job: dict, view: "FailedView | Unplaced",
                           head: "CompileErrors | None", unplaced: "UnplacedSignature | None", same_job: dict | None,
                           runs: list[dict], base_jobs: dict, github, run_reads: dict,
                           verdict_repo: str | None = None) -> str | None:
    """The audit line for red job NAME (JOB, its failed_view VIEW, its whole-log UNPLACED, and HEAD, read_head's
    compile_errors of it) when every compiler error it prints is one red base job's in a file the PR does not change
    (the rule above); None when the rule does not apply or no base job shows it. SAME_JOB: the base verdict of the
    same job; RUNS: the workflow's base runs, newest first. VERDICT_REPO: the repo whose runs are the base's
    verdict of record (Evidence.verdict_repo), REPO when None; every base read below is of it, while the paths this
    PR changes stay REPO's."""
    vrepo = verdict_repo or repo
    if view is UNPLACED:
        if unplaced is None or unplaced.tests or unplaced.crashes or unplaced.unnamed:
            return None
        if any(error.startswith("ratchet: ") for error in unplaced.errors):
            return None
    else:
        _, tests, errors = signature(view)
        if tests or crash_signals(view) or any(RATCHET_SCOPE.match(error) for error in errors):
            return None
        if test_reds.read(view_text(view)).unnamed:
            return None
        # Each failed section is a compile red of its own: a second failed step that prints no located error (a
        # sim run that exits 1 on `seed 42 diverged`) is never excused by the clippy step's base errors.
        if any(not compile_errors(list(lines_of("\n".join(lines))), job).located
               for _, _, lines in view.sections):
            return None
    if head is None or head.other or not head.located:
        return None
    # Each head failed step against the same job's base verdict by (name, how many): a name the base has fewer times
    # than the head failed it, or one it ran and passed, is the PR's own (Codex F2 on #42028: names in a dict hid a
    # second failed step of one name).
    mine = Counter(step for step, _ in failed_step_keys(job).elements())
    theirs = Counter(str(step.get("name") or "")  # step-name: classify
                     for step in (same_job or {}).get("steps") or []
                     if step.get("conclusion") in ("skipped", "failure"))
    known = Counter(str(step.get("name") or "") for step in (same_job or {}).get("steps") or [])  # step-name: classify
    if any(known[step] and theirs[step] < n for step, n in mine.items()):
        return None
    if view is UNPLACED and sum(mine.values()) != 1:
        return None  # no line of an unplaced log is known to be its step's: one failed step, or nothing is compared
    try:
        _, changed = pr_paths_once(repo, base, sha, github, run_reads)
    except Final:
        raise
    except Refused:
        return None
    if any(touched_by(path, changed) for path in {path for _, path, _ in head.located} | head.named):
        return None
    newest = created(runs[0]) if runs else None
    fixed: set = set()
    reads = compared = 0
    for run in runs:
        if run.get("conclusion") not in ("failure", "success"):
            continue
        if newest and created(run) and abs(newest - created(run)) > timedelta(hours=BASE_WINDOW_HOURS):
            continue
        if run["id"] not in base_jobs or base_jobs[run["id"]] is None:
            if reads >= BASE_WINDOW:
                break
            reads += 1
            base_jobs[run["id"]] = base_run_jobs(vrepo, run, github)
        jobs = base_jobs[run["id"]]
        passed = {other.get("name") for other in jobs if other.get("conclusion") == "success"}
        for other in jobs:
            if other.get("conclusion") != "failure" or other.get("name") in fixed | passed:
                continue
            if compared >= COMPILE_ERROR_LOGS:
                return None
            compared += 1
            theirs = compile_base_evidence(vrepo, run, other, github, run_reads)
            if all(theirs.counts[error] >= n for error, n in head.counts.items()):
                url = run.get("html_url") or f"https://github.com/{vrepo}/actions/runs/{run['id']}"
                return (f"excused '{name}': every compiler error it prints is one {base} run {run['id']}'s red "
                        f"'{other.get('name')}' prints ({url}), in files this PR does not change: "
                        f"{'; '.join(sorted(signature_text(error) for error in head.located))[:400]}")
        fixed |= passed
    return None


# The shared generated-files check reads its host job's verdict and prints nothing of its own (GENERATED_VERDICT_JOB).
# A 'stale' verdict from a host whose regeneration could not run is the host's red, not a stale file: when that host's
# red on this head was excused by pr_only_step_verdict (its regeneration failed only on base reds), the shared check's
# stale line is excused with it. A 'catalog' verdict or a host that is not excused stays the PR's own.
GENERATED_STALE = re.compile(r"^##\[error\]\s*Generated cmux-next files are stale\. (swift-test|daemon-test)'s ")
GENERATED_HOSTS = {"swift-test": "cmux-next swift test", "daemon-test": "cmux-next daemon tests"}


def shared_generated_host(repo: str, job: dict, github) -> str | None:
    """generated_stale_host of the shared generated-files check JOB's log: its one read."""
    return generated_stale_host(github.log(repo, job))


def generated_stale_host(log: str) -> str | None:
    """The host job name of a shared generated-files check whose one red is its host's 'stale' verdict; else None."""
    lines = [text for text in test_reds.lines_of(log) if text.startswith("##[error]")
             and not text.startswith("##[error]Process completed with exit code")]
    if len(lines) != 1 or not (match := GENERATED_STALE.match(lines[0])):
        return None
    return GENERATED_HOSTS[match.group(1)]


# A 'catalog' verdict the base fails too (2026-11-15, cmux#43469 at 7562e83f, run 43697059936): the FFI re-pin of
# #43603 added app.menu.run, so the action catalog checks failed on every head and on feat-cmux-next alike. A PR's
# shared check printed its green host's 'catalog' verdict and was refused, since base pushes never run the shared check
# (they check generated files in 'cmux-next generated files', base tier) and so no base verdict carries its name. It
# is the base's when: its one error line is the host's 'catalog' verdict (generated_catalog_host); the host job's
# whole log (unplaced_signature, as pr_only_step_verdict reads it: a green host's every failing test and error line is
# a continue-on-error check's) names at least one failing test and none unnamed, and every failing test (by name,
# digits kept) and error line in it is one ONE red base 'cmux-next generated files' fails, in the window (BASE_WINDOW
# verdicts within BASE_WINDOW_HOURS of the newest; a pass ends it, pr_only_step_verdict's rule); and the PR changes
# none of the catalog's inputs (CATALOG_INPUTS: judge-action-exports.sh's GENERATOR_INPUTS and its own scripts).
# Anything else stays the PR's own.
GENERATED_CATALOG = re.compile(r"^##\[error\]\s*The action catalog checks fail on (swift-test|daemon-test) with fresh "
                               r"exports too: a catalog failure, not stale files\.")
GENERATED_BASE_JOB = "cmux-next generated files"
CATALOG_INPUTS = ("Packages/", "plans/cmux-next/", "scripts/cmux-next/regenerate-action-contracts.sh",
                  "scripts/cmux-next/judge-action-exports.sh", "scripts/cmux-next/check-action-surfaces.sh")


def shared_catalog_host(repo: str, job: dict, github) -> str | None:
    """generated_catalog_host of the shared generated-files check JOB's log: its one read."""
    return generated_catalog_host(github.log(repo, job))


def generated_catalog_host(log: str) -> str | None:
    """The host job name of a shared generated-files check whose one red is its host's 'catalog' verdict; else None."""
    lines = [text for text in test_reds.lines_of(log) if text.startswith("##[error]")
             and not text.startswith("##[error]Process completed with exit code")]
    if len(lines) != 1 or not (match := GENERATED_CATALOG.match(lines[0])):
        return None
    return GENERATED_HOSTS[match.group(1)]


def shared_catalog_verdict(repo: str, base: str, sha: str, name: str, job: dict, host: str, github,
                           evidence: "Evidence", base_jobs: dict, job_reads: dict, suites: "SuiteChecks",
                           run_reads: dict) -> str:
    """The audit line for the shared generated-files check JOB (NAME) whose one red is HOST's 'catalog' verdict, when
    the base fails that catalog the same way (the rule above); raises Refused naming what differs."""
    why = f"'{name}': its one red is the 'catalog' verdict of '{host}'"
    found = [other for other in base_run_jobs(repo, {"id": job.get("run_id")}, github) if other.get("name") == host]
    if len(found) != 1:
        raise Refused(f"{why}, and run {job.get('run_id')} has {len(found)} jobs of that name; nothing to compare")
    mine = unplaced_base_evidence(repo, found[0], github)
    if mine.unnamed:
        raise Refused(f"{why}; its log reports more failed tests than it names ({mine.unnamed[0][:200]})")
    if not mine.tests:
        raise Refused(f"{why}, and its log names no failing test; nothing to compare with the base")
    if mine.crashes:
        raise Refused(f"{why}, and its log shows a crash ({sorted(mine.crashes)[0][:200]}); never a base red")
    workflow_info = run_reads.get(("run-record", job["run_id"]))
    if not isinstance(workflow_info, dict):
        workflow_info = rest_run(repo, job["run_id"], github, run_reads)
    workflow = workflow_info.get("workflow_id")
    if not isinstance(workflow, int):
        raise Refused(f"{why}; run {job['run_id']} came back without its workflow_id; nothing to compare")
    newest, read, closest, ended = None, 0, None, False
    for run, theirs_job in base_verdicts(repo, workflow, GENERATED_BASE_JOB, github, evidence, base_jobs, job_reads,
                                         suites):
        newest = newest or created(run)
        if read >= BASE_WINDOW or (newest and created(run)
                                   and newest - created(run) > timedelta(hours=BASE_WINDOW_HOURS)):
            ended = True
            break
        read += 1
        if theirs_job.get("conclusion") != "failure":
            raise Refused(f"{why}; '{GENERATED_BASE_JOB}' passed in {base} run {run['id']}, so an older red of it "
                          "never counts" + (f" ({closest})" if closest else ""))
        theirs = unplaced_base_evidence(repo, theirs_job, github)
        tests, errors = set(mine.tests) - set(theirs.tests), set(mine.errors) - set(theirs.errors)
        if theirs.unnamed or tests or errors:
            closest = closest or (f"{base} run {run['id']} does not fail: "
                                  + "; ".join(sorted(tests) + sorted(errors))[:400])
            continue
        number, paths = pr_paths_once(repo, base, sha, github, run_reads)
        if touched := [path for path in paths if path.startswith(CATALOG_INPUTS)]:
            raise Refused(f"{why}, which {base} run {run['id']}'s '{GENERATED_BASE_JOB}' fails too, but #{number} "
                          f"changes the action catalog's inputs ({', '.join(touched[:5])[:300]}): it may be the PR's")
        url = run.get("html_url") or f"https://github.com/{repo}/actions/runs/{run['id']}"
        return (f"excused '{name}': its one red is the 'catalog' verdict of '{host}', whose failing tests and error "
                f"lines all fail in {base} run {run['id']}'s red '{GENERATED_BASE_JOB}' ({url}), and #{number} "
                f"changes none of the action catalog's inputs: {'; '.join(sorted(mine.tests))[:400]}")
    if not ended and (cut := search_cut(job_reads, GENERATED_BASE_JOB, workflow)) is not None:
        # The window was not read to its end: a matching red may be in the runs left unread (#47687's review F4).
        raise Refused(f"{cut_refusal(name, base, cut)} ({why}, whose base job '{GENERATED_BASE_JOB}' it searched)"
                      + (f"; so far: {closest}" if closest else ""))
    raise Refused(f"{why}; no red '{GENERATED_BASE_JOB}' of {base} in the window fails all its failing tests and "
                  f"error lines" + (f": {closest}" if closest else ""))


def no_verdict(log: str) -> str | None:
    """The line where a compile check says it gave no verdict, if it does."""
    return next((text for text in lines_of(log) if NO_VERDICT.match(text)), None)


def summary_red(log: str) -> str | None:
    """The line where a summary gate names its failed needs (SUMMARY_RED), if it does."""
    return next((text for text in test_reds.lines_of(log) if SUMMARY_RED.match(text)), None)


def summary_no_verdict(log: str) -> str | None:
    """The line where a summary gate says nothing it summarizes was judged (SUMMARY_NO_VERDICT), if it does."""
    return next((text for text in test_reds.lines_of(log) if SUMMARY_NO_VERDICT.match(text)), None)


def generated_no_verdict(log: str) -> str | None:
    """The shared generated-files check's fail-closed prerequisite diagnostic, if it printed one.

    ``test_reds.lines_of`` removes the runner's echoed shell script, which also contains the ``echo
    ::error::`` branch.  Only the live annotation is evidence that the prerequisite produced no verdict.
    """
    return next((text for text in test_reds.lines_of(log) if GENERATED_NO_VERDICT.match(text)), None)


def compile_job_pass_at(repo: str, sha: str, github) -> str | None:
    """compile_pass_at's first source: the newest Mac Release compile job at SHA that ran, when it passed."""
    candidates = []
    # Every attempt (filter=all): one rerun into startup_failure ran no jobs and must not hide the pass before it.
    for page in github.json(f"repos/{repo}/commits/{sha}/check-runs?filter=all&per_page=100", paginate=True):
        for check in page.get("check_runs") or []:
            if (check.get("name") in COMPILE_PASS_CHECKS and check.get("head_sha") == sha
                    and check.get("app", {}).get("slug") == "github-actions" and check.get("status") == "completed"
                    and check.get("conclusion") != "skipped"):
                candidates.append(check)
    # Newest first; the same name is also release-compile-fast-admission's (a Linux wrapper that compiles
    # nothing), so only a job with the Mac compile's own steps counts, and the newest such attempt decides.
    for check in sorted(candidates, key=lambda found: found.get("id", -1), reverse=True):
        # The check run's own Actions job, from its details link (a check run id is not a job id).
        link = re.fullmatch(r"https://github\.com/" + re.escape(repo) + r"/actions/runs/(\d+)/job/(\d+)",
                            check.get("details_url") or "")
        if not link:
            continue
        job = github.json(f"repos/{repo}/actions/jobs/{link[2]}")
        if (job.get("head_sha") != sha or job.get("name") != check.get("name")
                or job.get("run_id") != int(link[1])):
            continue
        steps = {step.get("name"): step.get("conclusion") for step in job.get("steps") or []}  # step-name: classify
        if not COMPILE_STEPS & steps.keys():
            continue
        if job.get("conclusion") == "success" and any(steps.get(name) == "success" for name in COMPILE_STEPS):
            return f"'{check['name']}' (job {link[2]})"
        break
    return None


def compile_pass_at(repo: str, sha: str, github) -> str | None:
    """What compiled SHA itself and passed: the newest Mac Release compile job at SHA that ran (its
    `Release compile` or `Reuse that pass` step succeeded), a cmux-next/compile success its one poster made
    (compile_status_at: never a look-alike by anyone else), or else the fleet's compile
    receipt for SHA reading "pass" (compile_receipt: this repository, that exact commit, recipe 2, release-onone).

    The receipt is what cmux-next/compile publishes (cmux-next.yml's compile-status step maps the same fields to the
    same verdict), and the fleet keeps one for every same-repository PR head whether or not that job runs: a PR whose
    route skips the status job has no status, but its receipt still says whether the app compiled. The fleet compiles
    each head as the app executable (`--app --release`, compiled and linked), resolving the binary targets the
    head's own manifest pins (its url and checksum), so a pass compiled the app against the head's pin
    (cmux#39251, 2026-11-10: every app compile check skipped by routing, the receipt at 3c886d8d a pass). An unread
    receipt, or one of another commit, repository or recipe, refuses (compile_receipt)."""
    # Each source is another way to know; a read of one that fails (a 503) moves on to the next, and only when none
    # passes is it named (review of cmux#41151 at fd50c9b7, F1: an extra read never turns a pass into a refusal).
    unread = []
    try:
        if (found := compile_job_pass_at(repo, sha, github)) is not None:
            return found
    except Refused as why:
        unread.append(f"its compile jobs ({str(why)[:200]})")
    # A cmux-next/compile success its one poster made at this exact commit (compile_pass_status_at): a look-alike by
    # anyone else never passes, and a later no-verdict post never hides it.
    try:
        passed, newest = compile_pass_status_at(repo, sha, github)
    except Refused as why:
        passed, newest = None, None
        unread.append(f"its {COMPILE_PASS_STATUS} statuses ({str(why)[:200]})")
    if passed is not None:
        return f"the {COMPILE_PASS_STATUS} status"
    try:
        receipt = compile_receipt(repo, sha)
    except ReceiptUnreachable as down:
        # The receipts host is down or slow (cmux#40722, 2026-11-10: "TimeoutError: The read operation timed out"):
        # the poster's status above was the other way to know, and it holds no pass. Refused, naming both.
        said = (f"{newest.get('state')}: {(newest.get('description') or 'no description')[:120]}" if newest
                else "none posted")
        raise Refused(f"{down}; and no {COMPILE_PASS_STATUS} success from its poster at {sha[:12]} (its newest: "
                      f"{said}): neither the receipts nor the overflow compile's verdict says it compiled"
                      + (f"; unread: {'; '.join(unread)}" if unread else "")) from down
    if receipt is not None and receipt.get("state") == "pass":
        return (f"the fleet's app compile receipt (job {receipt.get('job_id') or 'unnamed'}, recipe "
                f"{receipt['recipe_version']}, {receipt['configuration']})")
    if unread:
        raise Refused(f"no compile pass at {sha[:12]} was read, and " + "; ".join(unread) + " could not be read")
    return None


# An inherited compile red (2026-11-09): cmux#38644 and #38631 branched from feat-cmux-next while #39301 had broken
# its cmux-tui compile, and the fleet's receipt for each head read "fail" with the base's own error. The fleet Release
# compile runs only on pull requests, so no base run has its job, and its cmux-next/compile status links the source
# run, which has no job of that name: both reds were refused with nothing to compare. The fleet's receipts are kept
# per commit, base pushes included, so the head's red is the base's when the head's receipt is a real "fail" and so is
# its merge-base's. Every other receipt state (no verdict, unread, another commit) stays the head's.
COMPILE_RECEIPTS = os.environ.get("BASE_RED_EXCUSE_COMPILE_RECEIPTS", "https://gh-events.cmux.com/compile-checks/v1")
COMPILE_RECEIPT_SECONDS = 20
# The receipts host sits behind a proxy that answers Python's default User-Agent ("Python-urllib/3.x") with HTTP 403
# (error code 1010, a refused client signature), so every read was refused and no compile red could be judged
# (cmux#39582, 2026-11-09). Name the client.
COMPILE_RECEIPT_USER_AGENT = "cmux-base-red-excuse"
# The body of that refusal. It comes from the CDN's edge, not the receipts host, so it says nothing about the service:
# it is neither "down" (ReceiptUnreachable, which hands the red to GitHub) nor a receipt answer, and its refusal says
# which it is, so nobody reads it as the results service being down (2026-11-10: the probe of the same host failed
# three runs in a row this way while the receiver was up).
CDN_REFUSED_SIGNATURE = "error code: 1010"
COMPILE_RECEIPT_RECIPE = (2, "release-onone")
FLEET_COMPILE_JOB = "cmux-next fleet Release compile"
FLEET_COMPILE_FAIL = re.compile(r"^##\[error\]\s*cmux-next/compile is not a pass for [0-9a-f]{40} \(fail\)")
# A gate that depends on one service (2026-11-10): from about 01:00Z the fleet controller was off, the receipts host
# answered HTTP 530 for every commit, and every compile red inherited_compile_red judged was refused on the unread
# receipt (cmux#40025, #40030, #40059 held with a SHIP at their heads). A busy or missing service makes a merge slower,
# never impossible: when the receipts host is unreachable (a connection error, a timeout, any 5xx), the same question is
# asked of GitHub instead (github_compile_red). GitHub's cmux-next/compile status is what compile-status posts from the
# same receipt, so a head that reads "The app did not compile" is compared with that status at its merge-base, or, when
# the merge-base has none completed, at the newest of the BASE_STATUS_COMMITS newest base commits that has one. Only
# the same failure there excuses; a pass there is the head's red, and no completed status anywhere refuses, saying so.
COMPILE_STATUS_FAIL = "The app did not compile"
COMPILE_RECEIPT_DOWN = 500  # an HTTP answer at or above this (5xx, Cloudflare's 52x and 530) is the service down


# The cmux-next/compile descriptions of compile-status that are no verdict (unavailable, no result in 40 minutes, a
# result for another head); only "The app did not compile" (COMPILE_STATUS_FAIL) is a fail. With the controller off
# every PR's status read "No compile result for this head in 40 minutes": no receipt and no base status can judge
# that (github_compile_red refuses it), but a compile that passed at the head elsewhere can. A no-verdict status is
# judged like the no-verdict job (NO_VERDICT_JOBS): another compile's pass at the head (compile_pass_at, the Mac
# Release compile first) ignores it, so a down controller makes landing slower, never impossible.
# cmux-next.yml starts every no-verdict description with COMPILE_STATUS_NO_VERDICT_MARKER (its note-84), and this keys
# on it; the prose stays matched too, for statuses posted before the marker (and the results service down, cmux#40667:
# "No compile verdict: ...", whose description says it on its own), so either change may land first.
COMPILE_STATUS_NO_VERDICT_MARKER = "[no-verdict]"
COMPILE_STATUS_NO_VERDICT = re.compile(re.escape(COMPILE_STATUS_NO_VERDICT_MARKER) + r"|No compile result for this head|"
                                       r"The compile check gave no verdict|The compile result does not match this head|"
                                       r"No compile verdict:")


class ReceiptUnreachable(Refused):
    """The receipts host did not answer (a connection error, a timeout, a 5xx): no verdict, and no answer about the
    receipt either, so a caller may ask GitHub instead (github_compile_red)."""


def receipt_http_refusal(error) -> str:
    """What a 4xx answer to a receipt read says: "HTTP N", or, for the CDN's refused client signature, that the
    reader's User-Agent was refused at the edge and the receipts host was never asked."""
    try:
        detail = (error.read(300) or b"").decode(errors="replace").strip()
    except Exception:  # noqa: BLE001 - an unreadable body is only a bare status
        detail = ""
    if error.code == 403 and CDN_REFUSED_SIGNATURE in detail:
        return (f"HTTP 403: {CDN_REFUSED_SIGNATURE}: the CDN refused this reader's signature (its User-Agent), "
                "so the receipts host was not reached: name the client (COMPILE_RECEIPT_USER_AGENT)")
    return f"HTTP {error.code}"


@once_per_judgement("receipt")
def compile_receipt(repo: str, sha: str) -> dict | None:
    """The fleet's compile receipt for SHA (one anonymous read, no wait), or None when it has none (404). Any other
    answer refuses: an unread receipt is no verdict."""
    import urllib.error
    import urllib.request
    url = f"{COMPILE_RECEIPTS}/{sha}?repo={urllib.parse.quote(repo, safe='')}&wait=0"
    try:
        request = urllib.request.Request(url, headers={"User-Agent": COMPILE_RECEIPT_USER_AGENT})
        with urllib.request.urlopen(request, timeout=COMPILE_RECEIPT_SECONDS) as answer:
            receipt = json.loads(answer.read(1 << 16))
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        if error.code >= COMPILE_RECEIPT_DOWN:
            raise ReceiptUnreachable(f"the compile receipt of {sha[:12]}: HTTP {error.code}") from error
        raise Refused(f"the compile receipt of {sha[:12]}: {receipt_http_refusal(error)}") from error
    except OSError as error:  # URLError, a refused connection, a timeout: the service did not answer
        raise ReceiptUnreachable(f"the compile receipt of {sha[:12]}: {type(error).__name__}: {error}") from error
    except ValueError as error:
        raise Refused(f"the compile receipt of {sha[:12]}: {type(error).__name__}: {error}") from error
    if not isinstance(receipt, dict) or receipt.get("sha") != sha or receipt.get("repo") != repo:
        raise Refused(f"the compile receipt of {sha[:12]} names another commit")
    # The receipt the workflow trusts (cmux-next.yml's compile-status step): recipe 2, Release at -Onone.
    if (receipt.get("recipe_version"), receipt.get("configuration")) != COMPILE_RECEIPT_RECIPE:
        raise Refused(f"the compile receipt of {sha[:12]} is of another recipe (recipe_version "
                      f"{receipt.get('recipe_version')}, configuration {receipt.get('configuration')})")
    return receipt


# A merge-base receipt that reads "superseded" (2026-11-25): cmux#50979's head changed only Swift, its fleet receipt
# failed on a cmux-tui crate the PR does not touch, and the merge-base fc7c32be read "superseded". That is the
# controller's word for a push tip it will not check because a newer push tip is checked instead, whose check covers
# this commit (fleet_compile_result.judge): no verdict about the merge-base at all, yet it was read as "the red is this
# head's". The receipt that covers it decides, followed through its `superseded_by` tip; with no tip to follow the
# receipts gave no base verdict, so GitHub is asked the same question (github_compile_red).
COMPILE_RECEIPT_SUPERSEDED = "superseded"
COMPILE_RECEIPT_SUPERSEDED_HOPS = 4


class BaseReceiptNoVerdict(Refused):
    """The merge-base's receipt says nothing about the merge-base itself and points at nothing to follow: no receipt
    answer about the base, so the same question may be asked of GitHub (github_compile_red)."""


def covering_compile_receipt(repo: str, merge_base: str, at_base: dict) -> tuple[dict | None, str]:
    """(the receipt that covers MERGE_BASE, the sha it was read at), following AT_BASE's `superseded_by` tips while
    each reads "superseded", at most COMPILE_RECEIPT_SUPERSEDED_HOPS of them. BaseReceiptNoVerdict when a receipt
    names no covering tip, names one already followed, or the chain runs past that bound: the receipts gave no
    verdict about MERGE_BASE."""
    seen = [merge_base]
    receipt, at = at_base, merge_base
    for _ in range(COMPILE_RECEIPT_SUPERSEDED_HOPS):
        tip = str((receipt or {}).get("superseded_by") or "")
        if not re.fullmatch(r"[0-9a-f]{40}", tip):
            raise BaseReceiptNoVerdict(f"the compile receipt of {at[:12]} reads superseded and names no covering tip "
                                       f"to follow ({tip or 'no superseded_by'}): the receipts gave no verdict about "
                                       f"the merge-base {merge_base[:12]}")
        if tip in seen:
            raise BaseReceiptNoVerdict(f"the compile receipts of {merge_base[:12]} are superseded in a cycle "
                                       f"({' -> '.join(short[:12] for short in seen)} -> {tip[:12]}): no verdict "
                                       "about the merge-base")
        seen.append(tip)
        receipt, at = compile_receipt(repo, tip), tip
        if (receipt or {}).get("state") != COMPILE_RECEIPT_SUPERSEDED:
            return receipt, at
    raise BaseReceiptNoVerdict(f"the compile receipt of {merge_base[:12]} is superseded through "
                               f"{COMPILE_RECEIPT_SUPERSEDED_HOPS} tips without a verdict "
                               f"({' -> '.join(short[:12] for short in seen)}): no verdict about the merge-base")


def inherited_compile_red(repo: str, base: str, sha: str, name: str, github,
                          evidence: "Evidence | None" = None) -> str:
    """The audit line excusing NAME's compile red at SHA when the head's fleet receipt and its merge-base's both read
    "fail", else Refused. A merge-base receipt that reads "superseded" is no verdict about the merge-base: the receipt
    that covers it decides (covering_compile_receipt). When the receipts host is unreachable, or they gave no verdict
    about the base at all, GitHub decides (github_compile_red, over EVIDENCE's commits)."""
    try:
        head = compile_receipt(repo, sha)
    except ReceiptUnreachable as down:
        return github_compile_red(repo, base, sha, name, github, down, evidence)
    if (head or {}).get("state") != "fail":
        raise Refused(f"'{name}': the compile receipt of {sha[:12]} is {(head or {}).get('state') or 'missing'}, not "
                      "a fail: no verdict to compare with the base")
    evidence = evidence or Evidence(repo, base, github)
    merge_base = evidence.merge_base(sha)
    if not re.fullmatch(r"[0-9a-f]{40}", merge_base):
        raise Refused(f"'{name}': no merge-base of {sha[:12]} with {base} to compare its compile receipt with")
    try:
        at_base = compile_receipt(repo, merge_base)
    except ReceiptUnreachable as down:
        return github_compile_red(repo, base, sha, name, github, down, evidence)
    covers = ""
    if (at_base or {}).get("state") == COMPILE_RECEIPT_SUPERSEDED:
        try:
            at_base, at = covering_compile_receipt(repo, merge_base, at_base or {})
        except (ReceiptUnreachable, BaseReceiptNoVerdict) as unanswered:
            return github_compile_red(repo, base, sha, name, github, unanswered, evidence)
        covers = f" (superseded: read at {at[:12]}, the push tip whose check covers it)"
    if (at_base or {}).get("state") != "fail":
        raise Refused(f"'{name}': the compile receipt of {sha[:12]} is a fail, and its merge-base {merge_base[:12]} "
                      f"on {base}{covers} reads {(at_base or {}).get('state') or 'no receipt'}: the red is this "
                      "head's")
    tip = evidence.tip(sha)
    now = ""
    if re.fullmatch(r"[0-9a-f]{40}", tip) and tip != merge_base:
        try:
            at_tip = compile_receipt(repo, tip) or {}
            now = f"; {base} {tip[:12]} reads {at_tip.get('state') or 'no receipt'}"
        except Refused:
            now = ""
    log_decider(f"'{name}' at {sha[:12]} was decided by the fleet's compile receipts")
    return (f"excused '{name}': the compile receipt of {sha[:12]} is a fail, and so is its merge-base "
            f"{merge_base[:12]}'s on {base}{covers} (an inherited base red{now}; merge the base for a new verdict)")


def log_decider(message: str) -> None:
    """Which path decided a compile red (the receipts or GitHub), on stderr beside the audit."""
    print(f"base_red_excuse: {message}", file=sys.stderr)


def trusted_poster(status: dict) -> bool:
    """Whether STATUS was posted by an account that posts cmux-next/compile (COMPILE_STATUS_POSTERS)."""
    creator = status.get("creator")
    return isinstance(creator, dict) and any(all(creator.get(key) == value for key, value in poster.items())
                                             for poster in COMPILE_STATUS_POSTERS)


# Pages of a commit's statuses list read for its poster's compile status. GitHub keeps at most 1000 statuses per
# context and commit, so ten full pages before it are anything but a real history: refused, never read as "none".
COMPILE_STATUS_PAGES = 10


def compile_status_at(repo: str, sha: str, github) -> dict | None:
    """SHA's newest cmux-next/compile commit status its poster made (COMPILE_STATUS_POSTER), or None only when the
    whole list has none. The commit's statuses list, newest first, names who posted each (the combined status does
    not), so a look-alike posted by anyone else is skipped: it can neither pass a head nor stand for a base's red.
    The list is read page by page until that status or a short page; COMPILE_STATUS_PAGES full pages without it
    (a flood of other statuses) refuse, because "none" there would let a base red be looked for on another commit
    (cmux#40609 review F1)."""
    for page in range(1, COMPILE_STATUS_PAGES + 1):
        statuses = github.json(f"repos/{repo}/commits/{sha}/statuses?per_page=100&page={page}") or []
        if not isinstance(statuses, list):
            raise Refused(f"the statuses of {sha[:12]} are not a list")
        found = next((status for status in statuses if isinstance(status, dict)
                      and status.get("context") == COMPILE_PASS_STATUS and trusted_poster(status)), None)
        if found is not None:
            return found
        if len(statuses) < 100:
            return None
    raise Refused(f"the statuses of {sha[:12]}: {COMPILE_STATUS_PAGES} full pages hold no {COMPILE_PASS_STATUS} "
                  "from its poster; too many statuses to tell whether it has one")


def compile_pass_status_at(repo: str, sha: str, github) -> tuple[dict | None, dict | None]:
    """(a cmux-next/compile success its poster made at SHA that no later real verdict replaced, or None; the
    poster's newest status at SHA, or None). Its poster posts a success only for a compile of this exact commit
    (compile-status from the receipt, the overflow compile's poster from its run). A later post that is no verdict
    (pending, or a COMPILE_STATUS_NO_VERDICT failure: a re-run of compile-status with the receipts host down) does not
    undo that compile; a later real failure does. Read like compile_status_at: page by page, COMPILE_STATUS_PAGES at
    most, and refused past them."""
    newest = None
    for page in range(1, COMPILE_STATUS_PAGES + 1):
        statuses = github.json(f"repos/{repo}/commits/{sha}/statuses?per_page=100&page={page}") or []
        if not isinstance(statuses, list):
            raise Refused(f"the statuses of {sha[:12]} are not a list")
        for status in statuses:
            if not (isinstance(status, dict) and status.get("context") == COMPILE_PASS_STATUS and trusted_poster(status)):
                continue
            newest = newest or status
            if status.get("state") == "success":
                return status, newest
            if status.get("state") in ("failure", "error") and \
                    not COMPILE_STATUS_NO_VERDICT.match(status.get("description") or ""):
                return None, newest  # a real verdict, newer than any pass below it
        if len(statuses) < 100:
            return None, newest
    raise Refused(f"the statuses of {sha[:12]}: {COMPILE_STATUS_PAGES} full pages read without its poster's "
                  f"{COMPILE_PASS_STATUS} verdict; too many statuses to tell whether it passed")


def github_compile_red(repo: str, base: str, sha: str, name: str, github, down: Refused,
                       evidence: "Evidence | None" = None) -> str:
    """inherited_compile_red's question asked of GitHub when the receipts could not answer it (DOWN: the host
    unreachable, or no verdict about the base): the audit line
    excusing NAME's compile red at SHA when GitHub's cmux-next/compile at SHA reads a real compile fail and the same
    status at the merge-base (else the newest of the BASE_STATUS_COMMITS newest BASE commits with one completed) reads
    the same fail, else Refused naming why. Reads: one status, one compare, at most BASE_STATUS_COMMITS + 2 more; no
    wait and no retry, so a GitHub that cannot answer refuses too. The base commits are EVIDENCE's
    (Evidence.status_commits: a stacked parent's head alone)."""
    why = (f"the receipts gave no verdict about the base ({down})" if isinstance(down, BaseReceiptNoVerdict)
           else f"the receipts host is unreachable ({down})")
    log_decider(f"'{name}' at {sha[:12]}: {why}; GitHub decides")
    head = compile_status_at(repo, sha, github) or {}
    said = head.get("description") or ""
    if head.get("state") not in ("failure", "error") or not said.startswith(COMPILE_STATUS_FAIL):
        raise Refused(f"'{name}': {why}, and GitHub's {COMPILE_PASS_STATUS} at {sha[:12]} reads "
                      f"{head.get('state') or 'no status'}: {said or 'no description'}; only a real compile fail can "
                      "be the base's (a no-verdict compile never is), so neither path can decide")
    evidence = evidence or Evidence(repo, base, github)
    merge_base = evidence.merge_base(sha)
    if not re.fullmatch(r"[0-9a-f]{40}", merge_base):
        raise Refused(f"'{name}': {why}, and GitHub names no merge-base of {sha[:12]} with {base}")
    candidates = [merge_base] + [commit for commit in evidence.status_commits() if commit != merge_base]
    for commit in candidates:
        found = compile_status_at(repo, commit, github)
        if found is None or found.get("state") == "pending":
            continue
        where = "its merge-base" if commit == merge_base else f"{base}"
        if found.get("state") == head.get("state") and (found.get("description") or "") == said:
            log_decider(f"'{name}' at {sha[:12]} was decided by GitHub: {where} {commit[:12]} fails the same way")
            return (f"excused '{name}': {why}; GitHub's {COMPILE_PASS_STATUS} at {sha[:12]} reads \"{said}\", and so "
                    f"does {where} {commit[:12]} (an inherited base red, decided over GitHub; merge the base for a "
                    "new verdict)")
        log_decider(f"'{name}' at {sha[:12]} was decided by GitHub: {where} {commit[:12]} reads {found.get('state')}")
        raise Refused(f"'{name}': {why}; GitHub's {COMPILE_PASS_STATUS} at {sha[:12]} reads \"{said}\", but {where} "
                      f"{commit[:12]} reads {found.get('state')}: {found.get('description') or 'no description'}: "
                      "the red is this head's")
    log_decider(f"'{name}' at {sha[:12]}: neither the receipts nor GitHub can decide")
    raise Refused(f"'{name}': {why}, and GitHub has no completed {COMPILE_PASS_STATUS} at its merge-base "
                  f"{merge_base[:12]} or the {BASE_STATUS_COMMITS} newest {base} commits to compare with: neither path "
                  "can decide; re-run it once the fleet answers")


# The Rust panic ratchet (scripts/cmux-next/rust_panic_ratchet.py, run by .github/scripts/cmux-tui-clippy-changed.py).
# Its error line names the packages the run checked, and a base run may check the whole workspace while a PR checks
# only its changed packages, so that line never matches (2026-10-31: cmux#26849's run 41176610742 failed on two rows
# that base run 41176544319 failed on word for word, and was refused). Its red is judged by the rows of its RED
# block instead (ratchet_red): each head row `CRATE: clippy::LINT N > WHERE` must be on the base with the same
# crate, lint and WHERE (`baseline M` or `new crate (must be 0)`) and a count at least the head's; every other
# line of the block but a hit location must be on the base word for word. A red with no row is never excused.
RATCHET_SCOPE = re.compile(r"^the panic ratchet is red for .+; its log above names each new hit")
RATCHET_RED, RATCHET_END = "rust-panic-ratchet: RED", "Fix the hit "
RATCHET_ROW = re.compile(r"^(\S+): clippy::(\w+) (\d+) > (baseline \d+|new crate \(must be 0\))$")
RATCHET_HIT = re.compile(r"^[^\s:]+\.rs:\d+:\d+$")


def ratchet_red(view: FailedView) -> tuple[dict[tuple[str, str, str], int], set[str]]:
    """({(crate, lint, where): count} of the ratchet's RED rows in VIEW (failed_view), its other RED lines), hit
    locations left out."""
    rows: dict[tuple[str, str, str], int] = {}
    other: set[str] = set()
    said = view_text(view)
    skip = test_reds.echoed(test_reds.log_lines(said))
    inside = False
    for n, text in enumerate(lines_of(said)):
        if n in skip:
            continue
        if text == RATCHET_RED:
            inside = True
        elif inside and (text.startswith(RATCHET_END) or text.startswith("##[")):
            inside = False
        elif inside and text:
            if row := RATCHET_ROW.match(text):
                crate, lint, count, where = row.groups()
                key = (crate, lint, where)
                rows[key] = max(rows.get(key, 0), int(count))
            elif not RATCHET_HIT.match(text):
                other.add(text)
    return rows, other


def ratchet_unmatched(head: FailedView, base: FailedView) -> list[str]:
    """The head's panic ratchet failures its base run does not have (empty when every one is covered), each side read
    from its failed_view."""
    head_rows, head_other = ratchet_red(head)
    if not head_rows:
        raise Refused("the panic ratchet is red with no per-lint row to compare with the base "
                      "(a clippy run that did not finish, say)")
    base_rows, base_other = ratchet_red(base)
    missing = [f"{crate}: clippy::{lint} {count} > {where}" + (
                   f" (the base has {base_rows[(crate, lint, where)]})" if (crate, lint, where) in base_rows else "")
               for (crate, lint, where), count in sorted(head_rows.items())
               if base_rows.get((crate, lint, where), -1) < count]
    return missing + sorted(head_other - base_other)


def crash_signals(view: FailedView) -> set[str]:
    """The signals a test helper died on, from SwiftPM's or the hang sampler's lines in VIEW (failed_view)."""
    return {first or second for first, second in CRASH.findall(view_text(view))}


def refused_at_setup(job: dict, log: str | None = None) -> bool:
    steps = job.get("steps") or []
    if not steps or any(step.get("name") in SETUP_STEPS  # step-name: classify
                        and step.get("conclusion") == "failure" for step in steps):
        return True
    return log is not None and HOOK_REFUSAL in log


def guard_routes_view(repo: str, guard: dict, github) -> "FailedView | Unplaced":
    """The failed_view of routed rollup job GUARD's log, after the gates its raw log is read for, each of which only
    refuses: a runner refusal at setup, a no-verdict summary (scripts/ci/needs_verdict.py's rule: no verdict is
    re-run, never compared), a crash or a run cut short."""
    name = guard["name"]
    text = github.log(repo, guard)
    if refused_at_setup(guard, text):
        raise Refused(f"'{name}' was refused at setup by its runner")
    if (said := summary_no_verdict(text)) is not None:
        raise Refused(f"'{name}' gave no verdict ({said[:300]}): nothing it summarizes was judged, so it is "
                      "neither a pass nor this PR's own red; re-run it")
    report = test_reds.read(text)
    if report.crashes or report.truncated:
        raise Refused(f"'{name}': routing process crashed or ended early")
    return failed_view(guard, text, step_names=job_step_names(repo, guard, github, {}), base=False)


def validate_guard_routes(repo: str, sha: str, guard: dict, children: list[dict], github) -> None:
    """A Guard status red must report only failed routes backed by concrete children.

    The wrapper also validates routing inputs and required-but-skipped jobs.
    Those failures cannot be waived by an unrelated child that is red on base.
    Children returned by head_jobs are still compared with base by judge.
    """
    name = guard["name"]
    found = routed_rollup(name, repo)
    if found is None:
        raise Refused(f"'{name}': not a routed rollup of {ROLLUPS_FILE.name}")
    contract, prefix = found
    routed = contract["routes"]
    if guard.get("head_sha") not in (None, sha):
        raise Refused(f"'{name}': job is not for the exact SHA {sha}")
    if guard.get("status") != "completed" or guard.get("conclusion") != "failure":
        raise Refused(f"'{name}': no completed failure verdict for its routes")
    view = guard_routes_view(repo, guard, github)
    found = signature(view)
    if found is UNPLACED:
        raise Refused(f"'{name}': {UNPLACED_WHY}; its routes are not judged")
    steps, _, errors = found
    if steps != {"Check routed guard jobs"}:
        raise Refused(f"'{name}': non-routing failed steps: {'; '.join(sorted(steps))}")
    if errors:
        raise Refused(f"'{name}': routing error: {'; '.join(sorted(errors))[:600]}")
    routes = []
    inputs = {route["route"] for route in routed.values() if route["route"]}
    report = rf"({ROUTE_REPORT}|{'|'.join(re.escape(key) for key in sorted(set(routed) | inputs))}): (.+)"
    # Only the failed step's own lines (failed_view): no passing step's. The runner's preamble (token permissions, and
    # a called workflow's echoed `Inputs`, whose `linux_guard_tests: true` reads like a route report) ends at its
    # `Complete job name:` line, should a failed "Set up job" section hold it; no step prints before it.
    lines = lines_of(view_text(view))
    started = next((at for at, line in enumerate(lines) if line.startswith("Complete job name: ")), None)
    for line in lines if started is None else lines[started + 1:]:
        match = re.fullmatch(report, line)
        if not match:
            continue
        route, result = match.groups()
        result_match = re.fullmatch(r"failure(?: \(route ([\w]+)=(true|false)\))?", result)
        if not result_match:
            raise Refused(f"'{name}': {route}: {result}")
        reported_route, enabled = result_match.groups()
        if route not in routed:
            raise Refused(f"'{name}': unknown routed job {route}")
        expected_route = routed[route]["route"]
        if reported_route is not None and (reported_route != expected_route or enabled != "true"):
            raise Refused(f"'{name}': route {reported_route} does not map to {route} (expected {expected_route}=true)")
        if reported_route is None and expected_route is not None:
            raise Refused(f"'{name}': {route} has no route mapping in its failure report")
        if not any(child.get("conclusion") == "failure" and matches(routed[route], child.get("name", ""), prefix)
                   for child in children):
            raise Refused(f"'{name}': no failed child for routed failure {route}")
        routes.append(route)
    if not routes:
        raise Refused(f"'{name}': no routed failure report to compare with its children")


# A job state that is no verdict either way: nothing it was to judge was judged, so there is nothing to compare with
# the base and the red is neither a pass nor the pull request's own. Such a job is re-run, never compared (the same
# reading single jobs already get: "is cancelled: it has no verdict to compare with the base; re-run it").
NO_VERDICT_CONCLUSIONS = ("cancelled", "timed_out", "stale", "skipped", "action_required")


def rerun_step(repo: str, run_id: object) -> str:
    """The runnable step for a red nothing judged, named in full rather than left to the reader.

    `[refusal-next-step]`: a refusal names its step. The front door is leo-workspace's `run-requeue`, which cancels
    only what never started and re-runs it; for a run that already completed it refuses ("is completed, not queued")
    and names the direct call itself (tools/run_requeue.py `next_step`), so both are named here and no reader has to
    guess one (leo-workspace#7840's cycle guessed a call that does not exist).
    """
    if not run_id:
        return "re-run it"
    return (f"re-run it: `run-requeue {repo} {run_id}`; a run that already completed is not queued, and run-requeue "
            f"then names `gh run rerun {run_id} -R {repo} --failed`")


def verdictless_needs(under: dict, children: list[dict]) -> list[str]:
    """The jobs under a rollup's needs that hold no verdict (NO_VERDICT_CONCLUSIONS): "job (state)" each, sorted."""
    return sorted(f"{child.get('name')} ({child.get('conclusion')})" for child in children
                  if child.get("conclusion") in NO_VERDICT_CONCLUSIONS
                  and any(matches(m, child.get("name", "")) for m in under.values()))


def rollup_has_failed_need(name: str, children: list[dict], repo: str = HOME_REPO) -> bool:
    """Whether a job under run rollup NAME's needs (ROLLUPS_FILE) failed: when one did, that child is what the base
    is compared with and nothing else about the rollup is read."""
    under = rollups(repo)["run"][name]["under"]
    return any(child.get("conclusion") == "failure" and any(matches(m, child.get("name", "")) for m in under.values())
               for child in children)


def rollup_no_verdict(repo: str, rollup: dict, github) -> str | None:
    """Rollup job ROLLUP's own `no verdict: ` line (scripts/ci/needs_verdict.py), read at the layer that reads logs
    and handed to validate_run_rollup as plain data: a comparator never fetches a log of its own, the readers do
    (read_head, guard_routes_view; FailedViewIsTheOnlyReader). None when its log names none or cannot be read: an
    unreadable log is no evidence, and the job states the comparator already holds still decide."""
    try:
        return summary_no_verdict(github.log(repo, rollup))
    except Exception:  # noqa: BLE001  (an unreadable log is no evidence; the job states below still decide)
        return None


def validate_run_rollup(name: str, children: list[dict], repo: str = HOME_REPO, rollup: dict | None = None,
                        said: str | None = None) -> None:
    """Run rollup NAME (ci-status), red, needs a failed job under it (its needs, ROLLUPS_FILE): a red run whose only
    failed jobs are outside them did not turn it red, so its own verdict did, and nothing here can compare that.

    When no job under its needs failed, why it has nothing to compare decides what this says. A dependency that holds
    no verdict (cancelled, or skipped though required: NO_VERDICT_CONCLUSIONS, and the gate's own `no verdict: `
    line, SAID, which its caller read for it with rollup_no_verdict) is an inability, not a verdict, and gets named
    with its state and the call that resolves it. Saying only "no failed job under its needs" rendered that
    inability in the words of a negative verdict: a lander, which
    may not judge a red by its own reading, read it as the pull request's own red and parked the row with no step on
    it (`red_not_excused`). Run 45093415114's `web / Web status` was red because `web / web-subarea-scope` was
    cancelled, and nothing said so.
    """
    if rollup is not None and refused_at_setup(rollup):
        # A runner that refused the rollup itself (a pool job hook, run 44690650796) is not "no failed job under its
        # needs": that sent readers hunting for a missing child (claude-sr2-coord, 2026-11-20).
        raise Refused(f"'{name}' was refused at setup: re-run")
    under = rollups(repo)["run"][name]["under"]
    if rollup_has_failed_need(name, children, repo):
        return
    run_id = (rollup or {}).get("run_id") or next((c.get("run_id") for c in children if c.get("run_id")), None)
    step = rerun_step(repo, run_id)
    # The gate's own words first: scripts/ci/needs_verdict.py names every dependency it could not read a verdict from,
    # including a required job GitHub shows `skipped`, which head_jobs never lists as a child at all. Its caller read
    # that line (rollup_no_verdict); this decides on it.
    if said is not None:
        raise Refused(f"'{name}' gave no verdict ({said[:300]}): nothing it summarizes was judged, so it is "
                      f"neither a pass nor this PR's own red; {step}")
    if (verdictless := verdictless_needs(under, children)):
        raise Refused(f"'{name}' cannot be compared with the base: no job under its needs failed, and "
                      f"{', '.join(verdictless)} under them holds no verdict, which is what turned it red. This is "
                      f"not a verdict on this PR's red: {step}")
    raise Refused(f"'{name}': no failed job under its needs ({', '.join(sorted(under))}) to compare with the base")


# A red run rollup was named by no line of its own: judge() judged the failed jobs under it, and merge_hold covered the
# rollup's name only by deriving the repo's rollups again in a process of its own, which named nothing when that
# derivation failed or ran past its bound. hq#12466 at ffe04af7 (2026-11-17) was refused "never named 'Skill
# documentation tests' as excused" although its one failed child, 'Skill test scope', was excused as a base red. Its
# line says so only when (a) every failed job under its needs is excused, at least one, and (b) every step of its own
# that failed reads its needs (the contract's "reports", _needs_steps). Anything else is refused: a rollup whose own
# step failed beside its needs (a step-time check, a lint) is a red no child stands behind.
def run_rollup_line(repo: str, rollup: dict, audit: list[str], jobs: list[dict]) -> str:
    """The audit line naming red run rollup job ROLLUP excused, once judge() judged the failed jobs under it (JOBS, its
    AUDIT lines so far); refused unless every failed child is excused and its own failed steps only report them."""
    name = rollup.get("name", "")
    contract = rollups(repo)["run"][name]
    reports = contract.get("reports")
    if not isinstance(reports, list):
        raise Refused(f"'{name}': its rollups contract names no step that reports its needs; not excused")
    own = failed_step_keys(rollup)
    if not own:
        raise Refused(f"'{name}': job {rollup.get('id')} shows no failed step, so what turned it red is unread")
    beside = sorted(f"{step} ({conclusion})" for step, conclusion in own
                    if step not in reports or conclusion != "failure")
    if beside:
        raise Refused(f"'{name}': its own step {', '.join(beside)} failed, which does not report its needs "
                      f"({', '.join(reports) or 'none'}); no failed child stands behind it")
    under = contract["under"]
    children = sorted({job.get("name", "") for job in jobs
                       if job.get("run_id") == rollup.get("run_id") and job.get("conclusion") == "failure"
                       and any(matches(m, job.get("name", "")) for m in under.values())})
    if not children:
        raise Refused(f"'{name}': no failed job under its needs ({', '.join(sorted(under))}) was judged")
    said = {child: next((line for line in audit if line.startswith(f"excused '{child}'")), None) for child in children}
    if not all(said.values()):
        raise Refused(f"'{name}': its failed job(s) {', '.join(c for c, line in said.items() if line is None)} are "
                      "not excused, so neither is it")
    fixed = all(line.startswith(f"excused '{child}': fixed on base (") for child, line in said.items())
    what = (f"run {rollup.get('run_id')} job {rollup.get('id')}: a rollup of the failed jobs under its needs, each "
            f"judged above: {', '.join(map(repr, children))}; its failed step(s) "
            f"{', '.join(sorted(step for step, _ in own))} only report them")[:700]
    return f"excused '{name}': " + (f"fixed on base ({what})" if fixed else f"its jobs are excused ({what})")


# A status-only check (2026-11-02, cmux#30294): a same-tree run reports its verdict as a commit status on the
# head it tested ('cmux-next daemon tests (same-tree)', cmux-next.yml's "Report the same-tree result on the tested
# commit"), so the head has no check run of that name and every such red was refused as "has not run on exact
# head", even when the base failed the same tests. The status is judged by the job that gave it: the job of the
# same name without the " (same-tree)" suffix, in the run its target_url links (else the newest run that tested
# the head and has that job). It is then compared per test like any job; a run that cannot be found is refused.
# Once excused, its audit line names the status context too (cmux#37038 at 1f4963c0): land-judge covers each red
# at the head only by a line naming it, and named only the job, it refused 'cmux-next daemon tests (same-tree)'.
SAME_TREE_SUFFIX = " (same-tree)"
# cmux-next-fast-gates.yml's status: the PR head merged with the base named in its description (`base <sha>`). A
# dispatched run's head_sha is the feat-cmux-next tip, not the PR head, so its red is never compared by the run: it is
# the PR's own at that base (a merger reruns one at a stale base), never a base red (cmux#38640, 2026-11-09).
FAST_GATES_STATUS = "cmux-next/fast-gates"
# The controller's required-checks pool posts its verdicts as commit statuses (manaflow-checks[bot]); a failed one says
# "failed on the cmux pool (exit 1); rerun: POST /v1/required-checks/rerun?head=<sha>". cmux#49885 at 8b11f0c2
# (2026-11-22): 'clippy (changed cmux-tui packages)' failed there while its Actions twin of the same name was skipped by
# path routing, so this script judged the skipped twin and said "re-run it": an Actions rerun comes back skipped, and
# nothing moved until a person POSTed the pool's rerun by hand. Leo: "should've been caught and fixed faster. hell,
# maybe even should've been automatic...". A pool red is never judged by its Actions twin: it is refused with the
# base's newest status of the same context beside it and the pool's own rerun as the next step (land-judge's
# pool_rerun_note makes that POST once per head). Its description names no failure, so the base sharing it excuses
# nothing.
POOL_CONTROLLER_DEFAULT = "http://100.89.225.106:18765"  # scripts/ci/expected_wait.py DEFAULT_CONTROLLER


def pool_controller() -> str:
    """The controller a pool rerun goes to: CMUX_CI_CONTROLLER, else POOL_CONTROLLER_DEFAULT."""
    base = (os.environ.get("CMUX_CI_CONTROLLER") or "").strip()
    return (base if base.startswith(("http://", "https://")) else POOL_CONTROLLER_DEFAULT).rstrip("/")


def pool_base_seen(repo: str, base: str, name: str, github, evidence: "Evidence | None" = None) -> str:
    """The base's newest commit status NAME (or why it is unread), for a pool red's refusal."""
    seen = ""
    if base:
        try:
            for commit in (evidence or Evidence(repo, base, github)).status_commits():
                statuses = github.json(f"repos/{repo}/commits/{commit}/status?per_page=100").get("statuses") or []
                if (found := next((s for s in statuses if s.get("context") == name), None)) is not None:
                    seen = (f"; base {commit[:12]} has it {found.get('state')}: "
                            f"{found.get('description') or 'no description'}")
                    break
            else:
                seen = f"; no recent {base} commit has a status '{name}'"
        except (Refused, RuntimeError, OSError, ValueError, AttributeError) as why:
            seen = f"; its {base} status is unread ({str(why)[:160]})"
    return seen


# cmux-tui-artifacts.yml's darwin-fallback-plan posts `cmux-tui/linux-cross` = failure when the Linux cross build of
# the macOS targets ended badly, and the same run then rebuilds those targets on a Mac (build-darwin-fallback). Its
# own comment says the status "blocks nothing (no ruleset requires cmux-tui/linux-cross)" and names the failed step
# so the cross build gets fixed: it is a notice, not a verdict. Nothing posts it on a base commit and no job carries
# its name, so every comparison path refused it, and cmux#52253 at 5f1fbbacaa51 (2026-11-24) was unlandable for a red
# whose writer had already covered it. It is excused only on the proof of the cover: the fallback built the targets
# in that run. A fallback that failed is its own red at the head and refuses on its own.
LINUX_CROSS_STATUS = "cmux-tui/linux-cross"
LINUX_CROSS_COVERED = re.compile(r"^linux-cross: failed at .+, covered by macOS fallback$")
LINUX_CROSS_FALLBACK = "build-darwin-fallback / build "
LINUX_CROSS_RUN = re.compile(r"/actions/runs/(\d+)")


def linux_cross_covered(repo: str, sha: str, name: str, state: str, status: dict, github) -> str:
    """The audit line excusing the `cmux-tui/linux-cross` notice on SHA when the macOS fallback it names covered the
    targets in the run its target_url points at, else Refused. A build job is covered when it succeeded; one that is
    skipped built nothing and is not a cover on its own."""
    description = str(status.get("description") or "")
    run = LINUX_CROSS_RUN.search(str(status.get("target_url") or ""))
    if run is None:
        raise Refused(f"'{name}': a {state} notice ({description}) whose target_url names no run of {repo}: "
                      "nothing proves the macOS fallback covered it")
    jobs = [job for job in last_real_jobs(repo, int(run[1]), github)
            if str(job.get("name") or "").startswith(LINUX_CROSS_FALLBACK)]
    if not jobs:
        raise Refused(f"'{name}': a {state} notice ({description}), and run {run[1]} has no "
                      f"'{LINUX_CROSS_FALLBACK}...' job: the macOS fallback never ran, so nothing covered the cross "
                      "build; re-run the run")
    unfinished = [job for job in jobs if job.get("status") != "completed"]
    if unfinished:
        raise Refused(f"'{name}': a {state} notice ({description}), and the macOS fallback has not finished in run "
                      f"{run[1]}: {', '.join(sorted(str(job.get('name')) for job in unfinished))}")
    red = [job for job in jobs if job.get("conclusion") not in ("success", "skipped")]
    if red:
        raise Refused(f"'{name}': a {state} notice ({description}), and the macOS fallback did not cover it in run "
                      f"{run[1]}: " + ", ".join(f"{job.get('name')} is {job.get('conclusion')}"
                                                for job in sorted(red, key=lambda job: str(job.get("name")))))
    built = [job for job in jobs if job.get("conclusion") == "success"]
    if not built:
        raise Refused(f"'{name}': a {state} notice ({description}), and every macOS fallback job in run {run[1]} was "
                      "skipped: nothing was rebuilt, so nothing covered the cross build")
    return (f"excused '{name}': a notice, not a verdict (\"{description}\"); no ruleset requires it and the macOS "
            f"fallback covered it in run {run[1]}: "
            + ", ".join(f"{job.get('name')} succeeded" for job in sorted(built, key=lambda job: str(job.get("name")))))


# The controller's required-checks pool posts its verdicts as commit statuses (manaflow-checks[bot]); a failed one says
# "failed on the cmux pool (exit 1); rerun: POST /v1/required-checks/rerun?head=<sha>". cmux#49885 at 8b11f0c2
# (2026-11-22): 'clippy (changed cmux-tui packages)' failed on the pool while the Actions job of that name was skipped
# by path routing, and the only refusal said "'...' is skipped: ... re-run it": a re-run of the Actions job comes back
# skipped, so the loop never ended without a person. A pool red is named as the pool's, with the controller's rerun
# as its step. The pool posts nothing on base commits, so there is no base verdict of its own to compare: it is
# refused, never excused, as before.
POOL_RERUN = re.compile(r"\brerun: POST (?P<path>/v1/required-checks/rerun\?head=(?P<head>[0-9a-fA-F]{7,40}))")


def pool_status_refusal(sha: str, name: str, status: dict | None, seen: str = "") -> "Refused | None":
    """The refusal for STATUS, the head's commit status NAME, when it is a failed required-checks pool status for SHA
    (POOL_RERUN in its description), else None. SEEN is pool_base_seen's note of the base's own status of NAME."""
    if not isinstance(status, dict) or status.get("state") not in ("failure", "error"):
        return None
    description = str(status.get("description") or "")
    match = POOL_RERUN.search(description)
    if match is None or not sha.lower().startswith(match["head"].lower()):
        return None
    url = str(status.get("target_url") or "")
    origin = re.match(r"https?://[^/?#\s]+", url)
    post = f"{origin[0] if origin else ''}{match['path']}"
    return Refused(f"'{name}': pool status red at {sha[:12]} ({status.get('state')}: {description[:160]}): its verdict "
                   "is the controller's required-checks pool, not an Actions job (one of that name, if any, has no "
                   "verdict to give: path routing left it out); rerun it through the controller (POST "
                   f"{post})" + (f", its log is at {url}" if url else "") + (
                       f"{seen}. Its description names no failure to compare with the base: rerun the pool: POST "
                       f"{pool_controller()}/v1/required-checks/rerun?head={sha}" if seen else
                       "; the pool posts nothing on the base, so no base verdict is compared"))


def head_status(repo: str, sha: str, name: str, github) -> dict | None:
    """The newest commit status NAME on SHA (the combined status lists the newest per context), or None."""
    statuses = github.json(f"repos/{repo}/commits/{sha}/status?per_page=100").get("statuses") or []
    return next((found for found in statuses if found.get("context") == name), None)


def status_job(repo: str, sha: str, name: str, github, base: str | None = None,
               suites: SuiteChecks | None = None, evidence: "Evidence | None" = None) -> dict | str | None:
    """The completed Actions job behind commit status NAME on SHA, or None when SHA has no status NAME. A red
    status no Actions job gave (Vercel's) is the audit line of base_status when BASE (EVIDENCE's) shares it, else
    refused."""
    status = head_status(repo, sha, name, github)
    if status is None:
        return None
    if (pool := pool_status_refusal(sha, name, status)) is not None:
        raise pool_status_refusal(sha, name, status, pool_base_seen(repo, base, name, github, evidence)) if base else pool
    state, job_name = status.get("state"), name.removesuffix(SAME_TREE_SUFFIX)
    if state == "pending":
        raise Refused(f"'{name}': its status is still pending on {sha}")
    if name == FAST_GATES_STATUS and state in ("failure", "error"):
        description = status.get("description") or ""
        tested = re.search(r"\bbase ([0-9a-f]{40})\b", description)
        run = re.search(r"/actions/runs/(\d+)", status.get("target_url") or "")
        raise Refused(f"'{name}': {state} at base {tested[1][:12] if tested else '(none named)'}"
                      f"{f' (run {run[1]})' if run else ''} is the pull request's own: the fast gates ran on it merged "
                      "with that base, never a base red; fix it, or dispatch them again on the tip if that base is stale")
    if (name == LINUX_CROSS_STATUS and state in ("failure", "error")
            and LINUX_CROSS_COVERED.match(status.get("description") or "")):
        return linux_cross_covered(repo, sha, name, state, status, github)
    if name == COMPILE_PASS_STATUS and base and state in ("failure", "error"):
        description = status.get("description") or ""
        if COMPILE_STATUS_NO_VERDICT.match(description):
            try:
                proof, unread = compile_pass_at(repo, sha, github), ""
            except Refused as why:  # the receipt is read last: nothing before it passed
                proof, unread = None, f"; {why}"
            if proof is None:
                raise Refused(f"'{name}' gave no compile verdict ({description[:140]}) and nothing else compiled "
                              f"{sha}{unread}: a no-verdict compile is never a base red; re-run it once the fleet "
                              "answers, or once the Mac Release compile passes at this head")
            return f"ignored '{name}': it gave no compile verdict, but {proof} compiled {sha} and passed"
        # Its target_url is the source run, with no job of this name (inherited_compile_red).
        return inherited_compile_red(repo, base, sha, name, github, evidence)
    url = status.get("target_url") or ""
    match = re.fullmatch(r"https://github\.com/" + re.escape(repo) + r"/actions/runs/(\d+)(?:/job/\d+)?/?", url)
    if match:
        runs = [github.json(f"repos/{repo}/actions/runs/{match[1]}")]
        if tested_sha(runs[0]) != sha:
            raise Refused(f"'{name}': its status links run {match[1]}, which tested {tested_sha(runs[0])[:12]}, "
                          f"not {sha}")
    else:
        listed = github.json(f"repos/{repo}/actions/runs?head_sha={sha}&per_page=100")
        runs = [run for run in listed.get("workflow_runs") or [] if tested_sha(run) == sha]
    suites = suites or SuiteChecks(github, repo)
    for index, run in enumerate(runs):
        # A run whose suite has no check run of that name has no such job in any attempt (the sweep limit, above).
        if not match and not may_hold(suites, runs, index, job_name, verdict=False):
            continue
        found = next((job for job in last_real_jobs(repo, run["id"], github) if job.get("name") == job_name), None)
        if found is None:
            continue
        if found.get("status") != "completed":
            raise Refused(f"'{name}': job '{job_name}' in run {run['id']} has not completed")
        if found.get("conclusion") == "success" or state == "success":
            raise Refused(f"'{name}': its status is {state} but job '{job_name}' in run {run['id']} is "
                          f"{found.get('conclusion')}; nothing to compare with the base")
        return found
    if not match and base and state in ("failure", "error"):
        return base_status(repo, base, name, state, status.get("description") or "", github, sha=sha,
                           evidence=evidence)
    where = f"run {match[1]} (its target_url)" if match else f"any run that tested {sha}"
    raise Refused(f"'{name}': a status ({state}: {status.get('description') or 'no description'}) with no job "
                  f"'{job_name}' in {where} to compare with the base")


# A status no Actions job gave (2026-11-04, cmuxterm-hq#7039): Vercel posts "Deployment rate limited — retry in 24
# hours." on every commit, the base's included, while its build limit lasts, and there is no job or log behind it to
# compare per test. It is the base's only when the newest of the BASE_STATUS_COMMITS newest base commits that has a
# status of that context has it in the same state with the same description; one the base does not share, or shares
# with another description, stays the head's.
BASE_STATUS_COMMITS = 10

# Vercel's build quota (2026-11-05, cmuxterm-hq#7192): the head reads "Deployment rate limited — retry in 24 hours."
# while the base's newest Vercel status is a build Vercel skipped ("Canceled by Ignored Build Step"), so the two never
# match. A rate-limited deploy built nothing, so it is no result rather than a red, but only when the base did not
# build either (an ignored or canceled build, never a real success) and the PR changes nothing under web/, the tree
# Vercel deploys. Any other Vercel failure, or a PR that touches web/, still refuses.
VERCEL_RATE_LIMITED = re.compile(r"Deployment rate limited\b")
VERCEL_NOT_BUILT = re.compile(r"(?i)\bIgnored Build Step\b|\bcancel(?:l?ed)?\b")
VERCEL_TREE = "web/"
# A PR's files are read PR_FILES_PAGE at a time through files(after:) until the last page (cmux#37362 at 54470673
# changes 108 files; one page of 100 refused it). The PR's head and base commits must stay the same on every page, so
# the pages all list one diff.
PR_FILES_PAGE = 100
PR_FILES_PAGES = 30  # 3000 files, GitHub's own limit on a PR's file list
PR_FILES_QUERY = ("query($owner: String!, $name: String!, $oid: GitObjectID!, $after: String) { repository(owner: "
                  "$owner, name: $name) { object(oid: $oid) { ... on Commit { associatedPullRequests(first: 10) { "
                  f"nodes {{ number baseRefName baseRefOid headRefOid changedFiles files(first: {PR_FILES_PAGE}, "
                  "after: $after) { nodes { path } pageInfo { hasNextPage endCursor } } } } } } } }")


def pr_paths_once(repo: str, base: str, sha: str, github, seen: dict | None) -> tuple[int, list[str]]:
    """pr_paths, read once per head into SEEN (judge's run_reads) when given: the app FFI pin rule may ask twice for
    one job, its whole-log reading and its rollup reading."""
    if seen is None:
        return pr_paths(repo, base, sha, github)
    key = ("pr-paths", repo, base, sha)
    if key not in seen:
        seen[key] = pr_paths(repo, base, sha, github)
    return seen[key]


def pr_paths(repo: str, base: str, sha: str, github) -> tuple[int, list[str]]:
    """The open PR into BASE whose head is SHA, and every path it changes, over GraphQL (no REST), page by page.
    Refused when there is no such PR, when its base moves while it is read, or when GitHub lists fewer files than
    the PR changes."""
    owner, _, name = repo.partition("/")
    number, base_oid, paths, after, pr, info = None, None, [], None, {}, {}
    for _page in range(PR_FILES_PAGES):
        found = json.loads(github.run(["api", "graphql", "-f", f"query={PR_FILES_QUERY}", "-f", f"owner={owner}",
                                       "-f", f"name={name}", "-f", f"oid={sha}",
                                       "-F" if after is None else "-f", f"after={after or 'null'}"]))
        commit = (((found.get("data") or {}).get("repository") or {}).get("object") or {}) \
            if isinstance(found, dict) else {}
        pr = next((node for node in (commit.get("associatedPullRequests") or {}).get("nodes") or []
                   if node.get("headRefOid") == sha and node.get("baseRefName") == base
                   and (number is None or node.get("number") == number)), None)
        if pr is None:
            if number is None:
                raise Refused(f"no PR into {base} has head {sha} to read its changed files from")
            raise Refused(f"#{number}: no longer a PR into {base} with head {sha} while its files were read")
        if number is None:
            number, base_oid = pr.get("number"), pr.get("baseRefOid")
        elif pr.get("baseRefOid") != base_oid:
            raise Refused(f"#{number}: its base moved from {base_oid} to {pr.get('baseRefOid')} while its files "
                          "were read")
        files = pr.get("files") or {}
        paths += [node.get("path") for node in files.get("nodes") or [] if isinstance(node.get("path"), str)]
        info = files.get("pageInfo") or {}
        after = info.get("endCursor")
        if not info.get("hasNextPage") or not after:
            break
    if info.get("hasNextPage") or len(paths) != pr.get("changedFiles"):
        raise Refused(f"#{number}: GitHub listed {len(paths)} of its {pr.get('changedFiles')} changed files, too "
                      f"few to judge what it changes")
    return number, paths


# A step-A Rust change (cmux#37292, 2026-11-06): the app links one pinned release of the app FFI, and
# scripts/cmux-next/check-app-ffi-pin.sh reports "error: the app FFI sources changed since the pinned source" on any PR
# that changes its inputs. app-ffi-release.yml publishes only from a feat-cmux-next push, so such a PR can never carry
# its own pin: its merge is what publishes the release the re-pin then names. That error alone, in the cmux-next checks
# job, is excused when the PR changes FFI inputs, leaves the pin (app-ffi-pin.json, and Package.swift, which reads it)
# alone and changes no Swift, so no app code calls a symbol or op the pinned library lacks. Any other red in the job is
# judged as before.
#
# Neither rule excuses a PR that changes a file that decides the pin verdict (FFI_PIN_CHECK_CODE; 2026-11-09, review of
# cmux#39194): it could make the pin error print for any change, and the published base pin rule excuses nearly every
# PR, since a head inherits the base's published pin.
#
# A published base pin (2026-11-07): step-A PRs change the FFI sources faster than releases publish, so a step-B PR (its
# Swift, or a re-pin) could never pin a release built from its own sources. Any other PR with that error has it excused
# when both hold: (a) the release its head pins (app-ffi-pin.json, read strictly by app_ffi_pin.py: this repository's
# own cmux-app-ffi-<sha> release download and its checksum, with Package.swift holding the one fixed loader block that
# reads that file, its checksum comment line equal to that checksum, and no pin of its own; or, at a head that predates
# the pin file, Package.swift's template-form canonical CCmuxAppFFI block; any other shape refuses) is
# published, its SOURCE_SHA names that sha, its SHA256SUMS carries that checksum for the archive, and that sha is on
# the PR's base (an ancestor of the base tip); (b) the app compile check passed at the
# PR's exact head (compile_pass_at: the Mac Release compile, cmux-next/compile, or the fleet's compile receipt for that
# head, which cmux-next/compile publishes and which a PR whose route skips the status job still has). The pin file at
# the head is the pin that compile built with: the loader hands its URL and checksum to the binary target, and SwiftPM
# resolves it from those, nothing else. Drift since the pinned source can then only be
# other PRs' additive FFI changes, and the compile proves the symbols the app calls are in the pinned library.
FFI_PIN_JOB = CHECKS_JOB_NAME
FFI_PIN_CHECK = "Check the app FFI pin"
FFI_PIN_ROLLUP_STEP = "Fail on any red check"  # the job's last step, red when a continue-on-error check is
FFI_PIN_ERROR = "error: the app FFI sources changed since the pinned source"
FFI_PIN_MANIFEST = "Packages/macOS/CmuxNext/Package.swift"
FFI_PIN_FILE = "Packages/macOS/CmuxNext/app-ffi-pin.json"
FFI_PIN_PATHS = (FFI_PIN_FILE, FFI_PIN_MANIFEST)  # a PR changing either moves the pin
# cmux-tui/bindings/rust is a crate cmux-app-ffi reaches through a Cargo path dependency (check-app-ffi-pin.sh
# --list-inputs); the other bindings (cpp, python, rust-sidebar) are not.
FFI_INPUTS = ("cmux-tui/crates/", "cmux-tui/bindings/rust/", "cmux-tui/rust-toolchain.toml",
              "scripts/cmux-next/build-app-ffi.sh")
FFI_CRATE_PARENTS = ("cmux-tui/crates/",)  # each folder below one is a crate; the other FFI_INPUTS folders are crates


def ffi_input(path: str) -> bool:
    """PATH may change the app FFI library: under FFI_INPUTS, and not in a crate's tests/, benches/ or examples/,
    which Cargo never builds into it (app_ffi_pin.NOT_BUILT, the one definition check-app-ffi-pin.sh and the router
    read). The pin check keeps such a folder an input when a library file names it; this tree-free reading calls
    it not an input, the stricter verdict here: a pull request that changes no input needs a published base pin."""
    if not any(touches(path, read) for read in FFI_INPUTS):
        return False
    crate = next((parent + path[len(parent):].split("/", 1)[0] for parent in FFI_CRATE_PARENTS
                  if path.startswith(parent)), None)
    crate = crate or next((read.rstrip("/") for read in FFI_INPUTS if read.endswith("/") and path.startswith(read)),
                          None)
    return crate is None or app_ffi_pin.is_input(path, [crate], [f"{crate}/{n}" for n in app_ffi_pin.NOT_BUILT])
# The files that decide the pin check's verdict: the check, the pin reader it runs, every step's BASH_ENV, this
# classifier and the workflow holding the pin step and its rollup (the checks job uses no .github/actions/). A PR
# changing one could make the pin error print for any change, so neither rule below excuses it (review of cmux#39194,
# the main copy of the step-A rule). Only these: a new FFI crate also changes app-ffi-release.yml, the router and the
# licence list (cmux#37869), which do not decide the verdict (review of cmux#39471).
FFI_PIN_CHECK_CODE = ("scripts/cmux-next/check-app-ffi-pin.sh", "scripts/ci/app_ffi_pin.py", "scripts/ci/api_call_log/",
                      "scripts/ci/base_red_excuse.py", ".github/workflows/cmux-next.yml")
# Generated Swift that is data only, never a call into the app FFI: step A's "changes Swift" rule ignores it. A step-A
# Rust PR that changes the daemon's request schema regenerates it in the same PR (generated-files.json keeps it fresh),
# so the rule refused every such PR (cmux#40449 at d375f032 and #40455, 2026-11-12: their one Swift file is this). Only
# a file whose generator emits literals and nothing callable belongs here.
FFI_PIN_DATA_SWIFT = frozenset({
    # scripts/cmux-next/gen-phone-lane-fields.py from cmux-tui/spec/sdk-schema.json: one [String: Set<String>] literal.
    "Packages/macOS/CmuxNext/Sources/CmuxNextMobile/DaemonLane/DaemonLanePolicy+Fields.generated.swift",
})
FFI_RELEASE_SECONDS = 30
FFI_ASSET = "CCmuxAppFFI.xcframework.zip"


# The pin is read by scripts/ci/app_ffi_pin.py (2026-11-07), shared with check-app-ffi-pin.sh, the repin picker and the
# repin script: the pin file strictly, and Package.swift only for its one fixed loader block; anything else refuses.
_spec = importlib.util.spec_from_file_location("app_ffi_pin", Path(__file__).with_name("app_ffi_pin.py"))
app_ffi_pin = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(app_ffi_pin)
_spec = importlib.util.spec_from_file_location("github_release_download",
                                          Path(__file__).with_name("github_release_download.py"))
release_download = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(release_download)


def ffi_binary_target(pin_file: str | None, manifest: str | None, repo: str) -> tuple[str | None, str | None, str]:
    """(source sha, checksum, "") of the head's pin; else (None, None, why). With PIN_FILE (app-ffi-pin.json's text) it
    is that file's pin, read strictly, and MANIFEST (Package.swift's text) must hold the one fixed loader block and no
    pin of its own (app_ffi_pin.read and check_manifest). Without it (None: the head predates the pin file) it is
    MANIFEST's template-form canonical CCmuxAppFFI block (app_ffi_pin.read_template), so a PR still in that form is
    read as before. None for MANIFEST means it is missing at that commit."""
    if manifest is None:
        return None, None, f"{FFI_PIN_MANIFEST} is missing"
    try:
        if pin_file is not None:
            sha, checksum = app_ffi_pin.read(pin_file, repo)
            app_ffi_pin.check_manifest(manifest, checksum)
        else:
            sha, checksum = app_ffi_pin.read_template(manifest, repo)
    except app_ffi_pin.NotCanonical as why:
        return None, None, str(why)
    return sha, checksum, ""


def ffi_pin_file_at(repo: str, sha: str, github) -> str | None:
    """app-ffi-pin.json's text at SHA, or None only when SHA definitely has none (the head is in the template form).
    A file that could not be read (a failed request, an unreadable blob) raises Refused: an unread pin file is never
    taken for an absent one, which would judge the head by its inline Package.swift pin instead."""
    return source_text_if_present(repo, sha, FFI_PIN_FILE, github)


@once_per_judgement("release")
def ffi_release_file(repo: str, tag: str, name: str) -> str | None:
    """File NAME of the published release TAG of REPO, read anonymously from its release download (no API quota), or
    None when it is not published (404, or a release without it). A download that fails otherwise is read through
    the release-assets API (github_release_download.py; 2026-11-08 every release download answered 503 or 504 and
    every merge was held). Any other failure raises: an unread release is no answer."""
    import urllib.error
    url = f"https://github.com/{repo}/releases/download/{tag}/{name}"
    try:
        with tempfile.TemporaryDirectory(prefix="cmux-ffi-release-") as tmp:
            out = Path(tmp) / name
            release_download.download(url, out, FFI_RELEASE_SECONDS,
                                      log=lambda message: print(f"base_red_excuse: {message}", file=sys.stderr))
            with open(out, "rb") as answer:
                return answer.read(1 << 16).decode("utf-8", "replace")
    except release_download.NoAsset:
        return None
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise Refused(f"{url}: HTTP {error.code}; the pinned release could not be read") from error
    except (OSError, ValueError) as error:
        raise Refused(f"{url}: {type(error).__name__}: {error}; the pinned release could not be read") from error


def ffi_published_base_pin(repo: str, base: str, sha: str, github) -> tuple[str | None, str]:
    """(audit, "") when the head SHA's app FFI pin (its one CCmuxAppFFI binary target) is a published release of REPO
    built from a commit on BASE, its checksum the release's archive entry, and the app compile check passed at SHA
    (the published base pin rule above); else (None, the part of that rule that does not hold)."""
    pin, checksum, why = ffi_binary_target(ffi_pin_file_at(repo, sha, github),
                                           source_text(repo, sha, FFI_PIN_MANIFEST, github), repo)
    if pin is None:
        return None, why
    tag = f"cmux-app-ffi-{pin}"
    source = ffi_release_file(repo, tag, "SOURCE_SHA")
    sums = ffi_release_file(repo, tag, "SHA256SUMS") if source is not None else None
    if source is None or sums is None:
        return None, f"the pinned release {tag} is not published (its {'SOURCE_SHA' if source is None else 'SHA256SUMS'} is 404)"
    if source.strip() != pin:
        return None, f"the pinned release {tag} records SOURCE_SHA {source.strip()[:40]!r}, not {pin}"
    if f"{checksum}  {FFI_ASSET}" not in sums.splitlines():
        return None, f"the pinned checksum {checksum[:12]} is not {tag}'s SHA256SUMS entry for {FFI_ASSET}"
    status = github.json(f"repos/{repo}/compare/{base}...{pin}?per_page=1").get("status")
    if status not in ("behind", "identical"):
        return None, f"the pinned release's source {pin[:12]} is not an ancestor of {base} (it is {status or 'unread'})"
    proof = compile_pass_at(repo, sha, github)
    if proof is None:
        return None, (f"no app compile check passed at {sha} (cmux-next/compile, the Release compile, or the fleet's "
                      f"compile receipt), so nothing proves the app builds against {tag}")
    return (f"pins {tag}, a published release built from {pin[:12]}, which is on {base}, and {proof} compiled {sha} "
            "against that pin and passed"), ""


# The checks job's rollup ("Fail on any red check") lets a style guard's red pass as a warning: it lists each one
# under "### N style guard(s) reported findings (warn-only)" and gives it no `red check:` line. Its step is
# continue-on-error, so a placed head view keeps its ERRORED section, and that guard's `##[error]` lines (cmux#40449 at
# d375f032: `##[error]./scripts/lint-ios-package-conventions.sh`, run-checks-concurrently.sh's line for a failed
# check) stood beside the pin as another red and set the step-A excuse aside, though the job was red on the pin alone.
# The pin rule drops the error lines that only those listed steps printed. The list is the head's own rollup, but a PR
# that edits it edits cmux-next.yml, which FFI_PIN_CHECK_CODE refuses first; the pin's own step is never warn-only.
WARN_ONLY_HEADER = re.compile(r"^### \d+ style guard\(s\) reported findings \(warn-only\)$")
WARN_ONLY_ITEM = re.compile(r"^- (\S.*)$")


def warn_only_steps(view: "FailedView | Unplaced") -> frozenset[str]:
    """The step names VIEW's rollup step (FFI_PIN_ROLLUP_STEP) lists as warn-only style guards (WARN_ONLY_HEADER),
    never FFI_PIN_CHECK; empty for an unplaced view or a rollup that lists none."""
    if view is UNPLACED:
        return frozenset()
    found: set[str] = set()
    for step, lines in section_lines(view):
        if step.get("name") != FFI_PIN_ROLLUP_STEP:  # step-name: classify
            continue
        listing = False
        for line in lines:
            text = STAMP.sub("", line, count=1).strip()
            if WARN_ONLY_HEADER.match(text):
                listing = True
            elif listing and (item := WARN_ONLY_ITEM.match(text)):
                found.add(item[1].strip())
            elif listing and text:
                listing = False
    return frozenset(found - {FFI_PIN_CHECK})


def without_warn_only(view: FailedView, errors: set[str]) -> set[str]:
    """ERRORS less each line printed only by steps VIEW's rollup lists as warn-only (warn_only_steps)."""
    warned = warn_only_steps(view)
    if not warned:
        return errors
    printers: dict[str, set[str]] = {}
    for step, error in step_errors(view):
        printers.setdefault(error, set()).add(step)
    return {error for error in errors if not (printers.get(error) and printers[error] <= warned)}


def ffi_pin_step_a(repo: str, base: str, sha: str, name: str, steps: Counter, errors: set[str], tests: set[str],
                   crashes: set[str], github, *, seen: dict | None = None) -> tuple[str | None, str | None]:
    """The audit line for a cmux-next checks job whose only red is the stale app FFI pin of a step-A Rust PR, or of a
    PR whose pin is a published base release its app compile passed against (the rules above). Wherever the pin error
    shows, the PR must be one a rule covers, whatever else is red: Refused when it changes Swift or Package.swift or no
    FFI input and its pin is not a published base release it compiled against, since the base comparison may set the
    error aside beside another red the base shares (review of d5c11dd8). None when there is no pin error, or when
    something else is red too (another failed step, a failing test, a crash, another error): that red is judged as
    before. The caller asks only after test_reds.read found no crash or cut-short run. STEPS: the job's failed steps
    by (name, conclusion), counted (failed_step_keys), on both paths, so no duplicate step is lost. CRASHES:
    crash_signals of a placed view, or an unplaced head's whole-log ones (UnplacedSignature.crashes).

    Returns (audit line, set-aside line). The first is the excuse when the pin is the job's only red. The second, when
    other reds stand beside a pin a rule covers, says why the pin's own parts (without_ffi_pin) leave the base
    comparison: before 2026-11-07 they stayed in it, and since the base never has the pin error, a step-A PR whose
    job also carried reds the base shares (cmux#37767: the iOS CmuxTabsKit notice, a next-batch line) was refused."""
    pin, rollup = normalise_error(FFI_PIN_ERROR), normalise_error(f"red check: {FFI_PIN_CHECK}")
    if name != FFI_PIN_JOB or not any(error.startswith(pin) for error in errors):
        return None, None
    number, paths = pr_paths_once(repo, base, sha, github, seen)
    if check_code := [path for path in paths if any(touches(path, code) for code in FFI_PIN_CHECK_CODE)]:
        raise Refused(f"'{name}': its app FFI pin is red, and #{number} changes the app FFI pin check's code "
                      f"({'; '.join(check_code[:5])}): a PR never excuses its own red by changing the check; land "
                      "the check change on its own, with the pin check green")
    if moved := [path for path in FFI_PIN_PATHS if path in paths]:
        why = (f"#{number} changes {moved[0]}: a PR that moves the pin must pin a release built from its own "
               "sources")
    elif swift := [path for path in paths if path.endswith(".swift") and path not in FFI_PIN_DATA_SWIFT]:
        why = (f"#{number} changes Swift ({'; '.join(swift[:5])}): app code may call what the pinned library lacks; "
               "land the Rust alone, then the Swift after the re-pin")
    elif not any(ffi_input(path) for path in paths):
        why = f"#{number} changes no app FFI input"
    else:
        why = None
    published = None
    if why is not None:
        published, missing = ffi_published_base_pin(repo, base, sha, github)
        if published is None:
            raise Refused(f"'{name}': its app FFI pin is red, and {why}; nor is its pin a published base release it "
                          f"compiled against: {missing}")
    others = {error for error in errors if not error.startswith(pin)} - {rollup}
    reason = (f"#{number} {published}" if published is not None else
              f"#{number} changes app FFI inputs, not {FFI_PIN_FILE}, {FFI_PIN_MANIFEST} or other Swift: a step-A Rust "
              "change, pinned by the release its merge publishes")
    # The rollup must have named the pin as its red check: a rollup that failed before saying so is another red.
    # STEPS are failed_step_keys: the pin's steps alone, each failed once. A step name read twice (a failure and a
    # cancelled one, say) is two reds, never the pin's one (#41158's review, F1 at 5fa1ea1d).
    if (tests or crashes or not steps or others or rollup not in errors
            or any(step not in (FFI_PIN_CHECK, FFI_PIN_ROLLUP_STEP) or conclusion != "failure" or count != 1
                   for (step, conclusion), count in steps.items())
            or len({step for step, _ in steps}) != len(steps)):
        return None, f"set aside '{FFI_PIN_CHECK}' (\"{FFI_PIN_ERROR}\"): {reason}"
    return f"excused '{name}': only '{FFI_PIN_CHECK}' is red (\"{FFI_PIN_ERROR}\"), and {reason}", None


def rollup_signature(repo: str, job: dict, github, run_reads: dict) -> tuple[Counter, set[str]] | None:
    """(failed steps, error lines) of head JOB, a rollup job whose log step_owners does not place, read from the jobs
    API and its rollup alone: None unless every step the jobs API does not call a success or skipped is a rollup step
    (ROLLUP_STEPS) and rolled_up_reds names its reds. A step that is not continue-on-error fails in the jobs API, and
    every continue-on-error check that fails is on the rollup's list, so these are all of the job's reds; the steps are
    the rollup and the checks it names, the errors its `red check: NAME` lines. 2026-11-11: cmux#40552's checks job
    (run 42895363602, job 130212680188) had more steps in one second than step_owners can tell apart, so since
    #40542 the app FFI pin rule never saw it, and read whole (UnplacedSignature) its passing steps' error lines set the
    pin aside; read this way it is excused as before."""
    failing = failed_step_keys(job)
    if not failing or any(step not in ROLLUP_STEPS for step, _ in failing):
        return None
    named = rolled_up_reds(repo, job, github, run_reads.setdefault("rollup-annotations", {}),
                           run_reads.get("rollup-log-reds"))
    if named is None:
        return None
    # Each named check is one red step, keyed as failed_step_keys keys one: the rollup names a check that failed.
    return failing + Counter((red, "failure") for red in named), {normalise_error(f"red check: {red}") for red in named}


def without_ffi_pin(head: tuple[set[str], set[str], set[str]]) -> tuple[set[str], set[str], set[str]]:
    """HEAD's signature (failed steps, failing tests, error lines) without the app FFI pin's own parts: its check step,
    its error lines and the rollup's line naming it. The rollup step stays: the base must have failed it too."""
    steps, tests, errors = head
    pin, rollup = normalise_error(FFI_PIN_ERROR), normalise_error(f"red check: {FFI_PIN_CHECK}")
    return (steps - {FFI_PIN_CHECK}, tests,
            {error for error in errors if not error.startswith(pin) and error != rollup})


def vercel_not_built(repo: str, base: str, sha: str | None, name: str, description: str, found: dict, github) -> str | None:
    """The audit line for a rate-limited Vercel deploy on SHA when the base's own Vercel status is a skipped build and
    the PR changes nothing under web/; None when the rule does not apply (the caller refuses as before)."""
    if not (sha and name.startswith("Vercel") and VERCEL_RATE_LIMITED.match(description)):
        return None
    if not VERCEL_NOT_BUILT.search(found.get("description") or ""):
        return None
    number, paths = pr_paths(repo, base, sha, github)
    if web := [path for path in paths if path.startswith(VERCEL_TREE)]:
        raise Refused(f"'{name}': \"{description}\" and #{number} changes {VERCEL_TREE} ({'; '.join(web[:5])}), "
                      "which Vercel deploys")
    return (f"excused '{name}': no result: \"{description}\" (Vercel built nothing), base status "
            f"{found.get('state')} \"{found.get('description')}\" (a skipped build), and #{number} changes no "
            f"{VERCEL_TREE} files")


def base_status(repo: str, base: str, name: str, state: str, description: str, github, *, sha: str | None = None,
                evidence: "Evidence | None" = None) -> str:
    """The audit line excusing jobless status NAME (STATE, DESCRIPTION) when the base has the same, else Refused. The
    base commits are EVIDENCE's (Evidence.status_commits: a stacked parent's head alone)."""
    if not description:
        raise Refused(f"'{name}': a status ({state}) with no description and no job: nothing to compare with the base")
    evidence = evidence or Evidence(repo, base, github)
    commits = evidence.status_commits()
    for commit in commits:
        statuses = github.json(f"repos/{repo}/commits/{commit}/status?per_page=100").get("statuses") or []
        found = next((found for found in statuses if found.get("context") == name), None)
        if found is None:
            continue
        if (found.get("state"), found.get("description") or "") != (state, description):
            if line := vercel_not_built(repo, base, sha, name, description, found, github):
                return line
            raise Refused(f"'{name}': a status ({state}: {description}) with no job, and {base} {commit} has "
                          f"it {found.get('state')}: {found.get('description') or 'no description'}")
        return f"excused '{name}': base {commit} status {state} \"{description}\""
    if evidence.parent is not None:
        raise Refused(f"'{name}': a status ({state}: {description}) with no job, and {base} is {evidence.where()}, "
                      f"which has no status '{name}' to compare with")
    raise Refused(f"'{name}': a status ({state}: {description}) with no job, and none of the {BASE_STATUS_COMMITS} "
                  f"newest {base} commits has a status '{name}' to compare with")


# A run's jobs as its last real attempt left them (cmux#35906, 2026-11-05). GitHub's latest-attempt views
# (jobs?filter=latest, and check-runs with no filter) show only the newest attempt, and an attempt that ended in
# startup_failure runs no jobs: after two such reruns of run 41931705470 they showed no job at all, its 'publish
# tree-addressed cmux-tui' red included, and the head read as having no red. Such an attempt is no result, never a
# green, so every attempt is read (filter=all) and each job name keeps the jobs of the newest attempt that ran it. A
# real rerun (red, then green) still decides; a run whose only attempt ran nothing has no jobs, which is no result.
def last_real_jobs(repo: str, run: int, github) -> list[dict]:
    jobs = [job for page in github.json(f"repos/{repo}/actions/runs/{run}/jobs?filter=all&per_page=100", paginate=True)
            for job in page.get("jobs") or []]
    for job in jobs:
        # glaeda's slim job list names no run_id (and a --jq projection of it reads null); the run read is the job's
        # run (superseding_check reads it)
        if job.get("run_id") is None:
            job["run_id"] = run
    newest: dict[str, int] = {}
    for job in jobs:
        newest[job.get("name", "")] = max(newest.get(job.get("name", ""), 0), job.get("run_attempt") or 1)
    return [job for job in jobs if (job.get("run_attempt") or 1) == newest[job.get("name", "")]]


# The sweep limit (2026-11-06, cmux#36958). glaeda-gh refuses a caller that reads the jobs of more than 30 different
# runs or jobs in ten minutes, and this script read one job list per run it looked in. A status with no run link
# ('next-autoland / verdict') read the job list of every run that tested the head, 32 of them, looking for a job of its
# name; a base red read a job list per base run until one had a verdict for it, up to BASE_JOB_READS per workflow, most
# of them runs that skipped or cancelled the job. land-judge asks about every red of a head in one call, so a head with
# a few reds was refused partway through its reads. Now which runs hold a job of a name is asked of their check suites
# over GraphQL, SUITES_PER_QUERY suites a request: every Actions job is a check run of its run's suite under the same
# name, one per attempt. A run is read only when its suite can answer: for a base verdict, a check run of the name
# with a verdict conclusion; for a status, a check run of the name. The job of a run's newest attempt is one of those
# check runs, so a run passed over could not have answered and every verdict is the same. A run with no check suite
# id, or a suite GraphQL did not answer in full, is read over REST as before.
#
# A passed-over base run is not counted toward BASE_JOB_READS (2026-11-13, cmux#42047 at 69e5e634): it costs no job
# read, and counting it as one let the runs that never build a job push the one that did out of the window. Most
# feat-cmux-next pushes of cmux-tui artifacts reuse a published tree and run no Mac build at all; 51 of them landed
# between 22:08Z and 00:00Z on 2026-11-12, so 'build / build x86_64-apple-darwin', red at the head and red in base run
# 43317021662, was refused as "no feat-cmux-next run of its workflow has a verdict for it to compare with". And an
# agent host's GitHub broker refuses a `nodes` root field, so there every suite read failed and every run was read over REST:
# when `nodes` is refused, the suites are asked by their commits under `repository` (SUITE_COMMITS_QUERY) instead.
SUITES_PER_QUERY = 25
SUITE_CHECKS_QUERY = ("query($name: String!) {{ nodes(ids: [{ids}]) {{ ... on CheckSuite {{ id checkRuns(first: 100, "
                      "filterBy: {{checkType: ALL, checkName: $name}}) {{ nodes {{ conclusion }} pageInfo "
                      "{{ hasNextPage }} }} }} }} }}")
# The same answer read by commit: every check suite of each commit (a cmux commit has about 50), with its check runs
# of the name. $name is the repo's name here, as the broker reads it; the check's name is $check.
SUITE_COMMITS_QUERY = ("query($owner: String!, $name: String!, $check: String!) {{ repository(owner: $owner, "
                       "name: $name) {{ {commits} }} }}")
SUITE_COMMIT = ("c{n}: object(oid: {sha}) {{ ... on Commit {{ checkSuites(first: 100) {{ pageInfo {{ hasNextPage }} "
                "nodes {{ id checkRuns(first: 100, filterBy: {{checkType: ALL, checkName: $check}}) {{ nodes "
                "{{ conclusion }} pageInfo {{ hasNextPage }} }} }} }} }} }}")
COMMIT_SHA = re.compile(r"[0-9a-f]{40}")
NODE_ID = re.compile(r"[A-Za-z0-9_=+/-]{1,200}")


class SuiteChecks:
    """The conclusions of each check suite's check runs of a name, every attempt, read in batches over GraphQL."""

    def __init__(self, github, repo: str = ""):
        self.github, self.repo = github, repo
        self.known: dict[tuple[str, str], frozenset[str] | None] = {}
        self.rooted = False  # `nodes` was refused: suites are read by commit (SUITE_COMMITS_QUERY)

    def conclusions(self, runs: list[dict], index: int, name: str) -> frozenset[str] | None:
        """The conclusions ('' for one not finished) of every check run named NAME in RUNS[INDEX]'s check suite, or
        None when that cannot be told. The unread suites after it in RUNS are asked in the same request."""
        suite = suite_id(runs[index])
        if suite is None:
            return None
        if (suite, name) not in self.known:
            batch: dict[str, str] = {}  # suite: its run's head commit
            for run in runs[index:]:
                other = suite_id(run)
                if other is not None and (other, name) not in self.known and other not in batch:
                    batch[other] = str(run.get("head_sha") or "")
                    if len(batch) == SUITES_PER_QUERY:
                        break
            self.read(batch, name)
        return self.known.get((suite, name))

    def read(self, suites: dict[str, str], name: str) -> None:
        self.known.update(((suite, name), None) for suite in suites)
        if not self.rooted:
            # Suite IDs name no repository: gh must use their repository even in a judge started from another
            # checkout. On cmuxterm-hq#22832 the unscoped read spent the jobs budget on twelve empty base runs.
            query = SUITE_CHECKS_QUERY.format(ids=", ".join(json.dumps(suite) for suite in suites))
            try:
                found = json.loads(self.github.run(["api", "graphql", "-f", f"query={query}", "-f", f"name={name}"],
                                                   repo=self.repo))
            except Refused as why:
                if "root field nodes is refused" not in str(why):
                    return  # read over REST instead, as before
                self.rooted = True
            except ValueError:
                return
            else:
                if isinstance(found, dict) and not found.get("errors") and isinstance(found.get("data"), dict):
                    self.keep(found["data"].get("nodes") or [], set(suites), name)
                return
        self.read_by_commit(suites, name)

    def read_by_commit(self, suites: dict[str, str], name: str) -> None:
        """read() under `repository`, by the commits SUITES' runs tested: a suite missing from its commit's whole
        list (no next page) has no check run of NAME."""
        owner, _, repo = self.repo.partition("/")
        shas = sorted({sha for sha in suites.values() if COMMIT_SHA.fullmatch(sha)})
        if not owner or not repo or not shas:
            return
        query = SUITE_COMMITS_QUERY.format(commits=" ".join(SUITE_COMMIT.format(n=n, sha=json.dumps(sha))
                                                            for n, sha in enumerate(shas)))
        try:
            found = json.loads(self.github.run(["api", "graphql", "-f", f"query={query}", "-f", f"owner={owner}",
                                                "-f", f"name={repo}", "-f", f"check={name}"]))
        except (Refused, ValueError):
            return
        data = found.get("data") if isinstance(found, dict) and not found.get("errors") else None
        listed = data.get("repository") if isinstance(data, dict) else None
        if not isinstance(listed, dict):
            return
        for n, sha in enumerate(shas):
            commit = listed.get(f"c{n}")
            page = commit.get("checkSuites") if isinstance(commit, dict) else None
            nodes = page.get("nodes") if isinstance(page, dict) else None
            if (not isinstance(nodes, list) or (page.get("pageInfo") or {}).get("hasNextPage") is not False
                    or not all(isinstance(node, dict) for node in nodes)):
                continue
            mine = {suite for suite, at in suites.items() if at == sha}
            self.keep(nodes, mine, name)
            for suite in mine - {node.get("id") for node in nodes}:
                self.known[(suite, name)] = frozenset()

    def keep(self, nodes: list, suites: set[str], name: str) -> None:
        for node in nodes:
            checks = node.get("checkRuns") if isinstance(node, dict) else None
            if (not isinstance(checks, dict) or node.get("id") not in suites
                    or (checks.get("pageInfo") or {}).get("hasNextPage") is not False
                    or not isinstance(checks.get("nodes"), list)
                    or not all(isinstance(check, dict) for check in checks["nodes"])):
                continue
            self.known[(node["id"], name)] = frozenset(str(check.get("conclusion") or "").lower()
                                                       for check in checks["nodes"])


def suite_id(run: dict) -> str | None:
    suite = run.get("check_suite_node_id")
    return suite if isinstance(suite, str) and NODE_ID.fullmatch(suite) else None


def may_hold(suites: SuiteChecks, runs: list[dict], index: int, name: str, verdict: bool) -> bool:
    """Whether RUNS[INDEX] can hold a job NAME (with a verdict conclusion, when VERDICT): False only when its check
    suite was read and has no such check run in any attempt."""
    found = suites.conclusions(runs, index, name)
    return found is None or bool(found & VERDICTS if verdict else found)


def cancelled_tier_without_verdict(suites: SuiteChecks, runs: list[dict], index: int, name: str) -> bool:
    """Whether RUNS[INDEX] is a cancelled base tier run whose check suite shows no verdict for job NAME: passed over
    before it counts toward a job-list limit (never_carries' note)."""
    return cancelled_base_tier(runs[index]) and not may_hold(suites, runs, index, name, verdict=True)


# A completed base run's job list, kept on disk so the next merge check on the same base reads none of them again.
# Keyed by run, attempt and updated_at: a re-run changes both, so a kept list is the one GitHub would serve.
JOBS_CACHE_ENV = "BASE_RED_EXCUSE_JOBS_CACHE"  # a directory, or "off"
JOBS_CACHE_SECONDS = 6 * 3600


# The jobs cache's size bound, beside each directory's age bound (JOBS_CACHE_SECONDS for kept job lists,
# SETTLED_KEEP_SECONDS for settled reads): past JOBS_CACHE_MAX_BYTES (BASE_RED_EXCUSE_JOBS_CACHE_MAX_BYTES) in one
# directory, its oldest answers go first until it is under. A spare file a crashed write left (".NAME.PID") goes after
# KEPT_SPARE_SECONDS. Every kept answer is only a saved read: one removed is read from GitHub again.
JOBS_CACHE_MAX_BYTES_ENV = "BASE_RED_EXCUSE_JOBS_CACHE_MAX_BYTES"
JOBS_CACHE_MAX_BYTES = 256 * 1024 * 1024
KEPT_SPARE_SECONDS = 3600


def jobs_cache_max_bytes() -> int:
    raw = os.environ.get(JOBS_CACHE_MAX_BYTES_ENV, "")
    try:
        value = int(raw) if raw else JOBS_CACHE_MAX_BYTES
    except ValueError:
        return JOBS_CACHE_MAX_BYTES
    return value if value > 0 else JOBS_CACHE_MAX_BYTES


def prune_kept(where: Path, keep_seconds: float) -> None:
    """Prune one kept-answers directory WHERE: answers older than KEEP_SECONDS, spare files older than
    KEPT_SPARE_SECONDS, then the oldest answers until the rest fit in jobs_cache_max_bytes()."""
    now, kept = time.time(), []
    for entry in os.scandir(where):
        try:
            if not entry.is_file(follow_symlinks=False):
                continue
            stat = entry.stat(follow_symlinks=False)
        except OSError:
            continue
        spare = entry.name.startswith(".")
        if not spare and not entry.name.endswith(".json"):
            continue
        if now - stat.st_mtime > (KEPT_SPARE_SECONDS if spare else keep_seconds):
            Path(entry.path).unlink(missing_ok=True)
        elif not spare:
            kept.append((stat.st_mtime, stat.st_size, entry.path))
    total, cap = sum(size for _, size, _ in kept), jobs_cache_max_bytes()
    for _, size, path in sorted(kept):
        if total <= cap:
            break
        Path(path).unlink(missing_ok=True)
        total -= size


def jobs_cache() -> Path | None:
    named = os.environ.get(JOBS_CACHE_ENV)
    if named == "off":
        return None
    if named:
        return Path(named)
    return Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "base-red-excuse" / "jobs"


def base_run_jobs(repo: str, run: dict, github) -> list[dict]:
    """The jobs of base RUN's newest attempt (jobs?filter=latest): a kept list first (kept_run_jobs: the disk cache
    when RUN is completed, or the settled store), else one live read, counted against the judgement's one budget
    (job_budget) whatever path asks. Past it, or refused by glaeda-gh's sweep guard, JobBudgetCut: never a read."""
    kept = kept_run_jobs(repo, run)
    if kept is not None:
        return kept
    where, key = jobs_cache(), None
    if (where is not None and run.get("status") == "completed" and isinstance(run.get("run_attempt"), int)
            and re.fullmatch(r"[0-9TZ:.+-]{10,40}", str(run.get("updated_at") or ""))):
        stamp = re.sub(r"[^0-9]", "", run["updated_at"])
        key = where / f"{repo.replace('/', '--')}-{int(run['id'])}-{run['run_attempt']}-{stamp}.json"
    budget = job_budget()
    if budget is not None and run["id"] not in budget["read"] and (
            budget["spent"] or len(budget["read"]) >= CALL_JOB_READS):
        budget["spent"] = True
        raise JobBudgetCut(len(budget["read"]), budget["name"])
    try:
        jobs = [found for page in github.json(f"repos/{repo}/actions/runs/{run['id']}/jobs?filter=latest&per_page=100",
                                              paginate=True)
                for found in page.get("jobs") or []]
    except Refused as why:
        if budget is None or not SWEEP_GUARD_REFUSED.search(str(why)):
            raise
        budget["spent"] = True
        raise JobBudgetCut(len(budget["read"]), budget["name"]) from None
    if budget is not None:
        budget["read"].add(run["id"])
    for job in jobs:  # a --jq projection of glaeda's slim list reads a null run_id; the cache check above needs it
        if job.get("run_id") is None:
            job["run_id"] = run["id"]
    if key is not None:
        try:
            key.parent.mkdir(parents=True, exist_ok=True)
            spare = key.with_name(f".{key.name}.{os.getpid()}")
            spare.write_text(json.dumps(jobs))
            os.replace(spare, key)
            prune_kept(key.parent, JOBS_CACHE_SECONDS)
        except OSError:
            pass
    return jobs


# A cancelled job with a newer run of its name: the newest completed run of a check name is its verdict, as glaeda-gh
# reads a head ("superseded: ... cancelled (not counted)"). cmux#36965 at 004465b3: run 42179149655's 'risk evidence'
# was cancelled by concurrency while run 42179187468 of the same workflow passed it, and the cancelled one refused the
# merge as a red with no verdict. Only a cancelled (or stale) job is passed over, and only for a newer run of the same
# workflow on the same head: a failure is a verdict and stays red whatever a later run says (land-judge's
# _superseded_cancels, router-review F1 at 241b0da0).
SUPERSEDABLE = ("cancelled", "stale")
VERDICT_REDS = ("failure", "timed_out")  # a verdict whatever a later run says (superseding_run)
GREEN = ("success", "skipped", "neutral")
ACTIONS_JOB_URL = r"https://github\.com/{repo}/actions/runs/(\d+)/job/(\d+)"


def linked_checks(repo: str, sha: str, name: str, github, seen: dict) -> list[tuple[int, int, dict]]:
    """(Actions job id, run id, check run) of each GitHub Actions check run of NAME on SHA, every attempt, newest job
    first. Recency is the job id each check run links (its details URL), never the check run's own id: one kind of id
    whatever the check run's own is. SEEN keeps the head's check runs for one judge call."""
    if "checks" not in seen:
        listed = github.json(f"repos/{repo}/commits/{sha}/check-runs?filter=all&per_page=100", paginate=True)
        seen["checks"] = [check for page in listed for check in page.get("check_runs") or []
                          if (check.get("app") or {}).get("slug") == "github-actions"]
    url = re.compile(ACTIONS_JOB_URL.format(repo=re.escape(repo)))
    linked = [(int(match[2]), int(match[1]), check) for check in seen["checks"]
              if check.get("name") == name and (match := url.fullmatch(check.get("details_url") or ""))]
    return sorted(linked, key=lambda found: found[0], reverse=True)


def rest_run(repo: str, run: int, github, seen: dict | None = None) -> dict:
    """RUN's REST record. A lane VM's gh chain can answer `actions/runs/ID` with glaeda's 12-field run summary, which
    has the run's head_sha but no workflow_id or path: base_red_excuse then asked `actions/workflows/None/runs` (a 404
    that refused cmux#37033), and a cancelled run superseded by newer greens of its workflow was read as having none
    (cmux#36971 at b265fe8c, risk-tier's 42191711726). Such a record is completed from `actions/runs?head_sha=SHA`,
    one read per head kept in SEEN, which names every run at it. The workflow is only GitHub's workflow_id, never a
    name two workflows can share; a list that does not name the run leaves the summary, whose workflow_id is None."""
    found = github.json(f"repos/{repo}/actions/runs/{run}")
    sha = found.get("head_sha") if isinstance(found, dict) else None
    if not isinstance(found, dict) or "workflow_id" in found or not re.fullmatch(r"[0-9a-f]{40}", str(sha or "")):
        return found
    full = head_runs(repo, sha, github, {} if seen is None else seen).get(run)
    return full if isinstance(full, dict) and isinstance(full.get("workflow_id"), int) else found


def head_runs(repo: str, sha: str, github, seen: dict) -> dict:
    """Every workflow run at SHA by id: `actions/runs?head_sha=SHA`, one paginated read per head kept in SEEN, shared
    by every run and check one judge call asks about (rest_run, superseding_run)."""
    key = ("runs-at", sha)
    if key not in seen:
        listed = github.json(f"repos/{repo}/actions/runs?head_sha={sha}&per_page=100", paginate=True)
        # A reader may answer one page unwrapped; any other shape lists no run, so nothing is superseded by it.
        pages = listed if isinstance(listed, list) else [listed]
        seen[key] = {listed_run.get("id"): listed_run for page in pages if isinstance(page, dict)
                     for listed_run in page.get("workflow_runs") or [] if isinstance(listed_run, dict)}
    return seen[key]


# A cancelled run with a later green run of its workflow file (dep-fleet-6, 2026-11-11). cmux#40850 at 4dd65e96:
# backend-migrations runs 42921917680 and 42921920329 were cancelled with no job, so they read "no failed job found on
# the head to compare with the base", while run 42921946667 of the same workflow passed at that head. A cancelled run
# counts as superseded, not red, only when all of these hold: a later run of the same workflow file (its path, never
# the display name two workflows can share), at the same head SHA, from the same event (for workflow_dispatch, the same
# inputs: a run record that does not carry them has unknown inputs, never the same), was created after it and concluded
# success (not skipped, neutral or cancelled). Anything less stays red. A failed job in a superseded run is still a
# verdict and is judged as before (head_jobs).
def superseding_run(repo: str, sha: str, run: int, github, seen: dict) -> dict | None:
    """The later green run at SHA that supersedes cancelled RUN by the rule above; None when RUN is not a cancelled run
    the head's run list names, or no later run meets every part of it."""
    runs = head_runs(repo, sha, github, seen)
    mine = runs.get(run)
    if (not isinstance(mine, dict) or mine.get("status") != "completed" or mine.get("conclusion") != "cancelled"
            or mine.get("head_sha") != sha or not isinstance(mine.get("path"), str) or not mine["path"]
            or created(mine) is None):
        return None
    for other in sorted(runs.values(), key=lambda found: int(found.get("id") or 0)):  # the oldest qualifying first
        if (other is mine or other.get("id") == run or other.get("head_sha") != sha
                or other.get("path") != mine["path"] or other.get("event") != mine.get("event")
                or other.get("status") != "completed" or other.get("conclusion") != "success"):
            continue
        if (isinstance(mine.get("workflow_id"), int) and isinstance(other.get("workflow_id"), int)
                and other["workflow_id"] != mine["workflow_id"]):
            continue
        if mine.get("event") == "workflow_dispatch" and (
                not isinstance(mine.get("inputs"), dict) or other.get("inputs") != mine["inputs"]):
            continue
        if (later := created(other)) is None or later <= created(mine):
            continue
        return other
    return None


def superseded_name(seen: dict, sha: str, run: int) -> str:
    """The name of cancelled RUN as the head's run list gives it (its workflow's display name)."""
    return str((seen.get(("runs-at", sha)) or {}).get(run, {}).get("name") or run)


def run_workflow(repo: str, run: int, github, seen: dict):
    """RUN's workflow id, read once per judge call (SEEN); None when GitHub's answer names none (rest_run)."""
    if run not in seen:
        seen[run] = rest_run(repo, run, github, seen).get("workflow_id")
    return seen[run]


def superseding_check(repo: str, sha: str, job: dict, github, seen: dict) -> dict | None:
    """The newest check run of JOB's name on SHA in a newer run of JOB's workflow, when it has completed with a
    verdict; None when there is none, it is still running, it was cancelled too, or a workflow cannot be read."""
    mine = None
    for job_id, run, check in linked_checks(repo, sha, job.get("name", ""), github, seen):
        if job_id <= job["id"] or run == job["run_id"]:
            continue  # older, or a later attempt of the same run (last_real_jobs reads those)
        mine = run_workflow(repo, job["run_id"], github, seen) if mine is None else mine
        if mine is None or run_workflow(repo, run, github, seen) != mine:
            continue
        # The newest run of this workflow and name decides; it must have finished with a verdict of its own.
        if check.get("status") != "completed" or check.get("conclusion") in SUPERSEDABLE:
            return None
        return {**check, "job_id": job_id}
    return None


def superseded_by_green(repo: str, sha: str, job: dict, github, seen: dict) -> list[dict]:
    """The older red check runs of green JOB's name on SHA when every one is a cancelled (or stale) run of JOB's own
    workflow, so JOB, the newest, supersedes them all; [] when there is none, or any is a failure (a verdict that
    stays red whatever a later run says) or another workflow's or a still-running run's."""
    mine = run_workflow(repo, job["run_id"], github, seen)
    older = [(job_id, run, check) for job_id, run, check in linked_checks(repo, sha, job.get("name", ""), github, seen)
             if job_id < job["id"]]
    reds = [(run, check) for _, run, check in older if check.get("conclusion") not in GREEN]
    if mine is None or not reds:
        return []
    for run, check in reds:
        if (check.get("status") != "completed" or check.get("conclusion") not in SUPERSEDABLE
                or run_workflow(repo, run, github, seen) != mine):
            return []
    return [check for _, check in reds]


# A derived status (2026-11-11): a commit status whose red is a function of the head's other checks, never a verdict
# of its own. next-autoland's 'next-autoland / verdict' reads "its own red: WORKFLOW / JOB (and N more red, not
# probed)" when a head has reds it calls its own; on cmux#40984 at a6698ad5 judge() looked for a job or a base
# status of that name and refused it ("a status ... with no job"), whatever its parts were. The reviewer's rule
# (dep-fleet-6): "judge() treats next-autoland / verdict as a derived status. It's excused only when the full list
# of reds it names is read (probe every one, never "and 2 more red, not probed") and every one of them is excused by
# judge itself. An unreadable or incomplete list is not excused." The class: any rollup or derived status whose
# verdict is a function of other checks, judged by its parts. A status is derived by a declared list (DERIVED_STATUSES,
# each with the description that says its red is its parts'): its description may be cut at 140 characters and
# names only one red, so the parts are read from the head itself, every page of its check runs (the newest of each
# name, any app) and its combined status, never from the description. The status is excused only when:
#   - its description is the declared one (another red, a conflict or a missing review, is not its parts' and stays);
#   - both lists are read in full (each page's total_count is what the pages gave), nothing at the head is still
#     running (a part not finished is not probed), and the red the description names is one of the parts read, as
#     is every "N more" it counts;
#   - judge() itself excuses (or ignores, as superseded) every part, each judged as if named on its own.
# Its line is "excused 'STATUS': fixed on base (...)" when every part judge() did not ignore is fixed on base, which
# the update_branch guard reads, else "excused 'STATUS': its parts ...".
DERIVED_STATUSES = {
    "next-autoland / verdict": re.compile(r"^its own red: (?P<key>.+?)(?: \(and (?P<more>\d+) more red, not "
                                          r"probed\))?$"),
}
PENDING_CHECK = ("queued", "in_progress", "waiting", "requested", "pending")


def read_in_full(pages: object, key: str, what: str) -> list[dict]:
    """The items KEY of every page of a paginated read, when every page names one total_count and they gave it all;
    Refused (unknown) otherwise."""
    items: list[dict] = []
    totals = set()
    for page in pages if isinstance(pages, list) else [pages]:
        if not isinstance(page, dict) or not isinstance(page.get(key), list):
            raise Refused(f"{what} could not be read")
        items.extend(item for item in page[key] if isinstance(item, dict))
        totals.add(page.get("total_count"))
    if len(totals) != 1 or not isinstance(next(iter(totals)), int) or next(iter(totals)) != len(items):
        raise Refused(f"{what} came back incomplete ({len(items)} read of {', '.join(map(str, totals))}), so a red "
                      "in it may be unread")
    return items


class Part(NamedTuple):
    """A red a derived status is a function of, by the identity hq#9188's update_branch guard keys reds by: "run RUN /
    JOB" for an Actions job (judged by its check name, which names one Actions job at the head), "status / CONTEXT"
    for a commit status. NAME is what judge() is asked about and its audit lines name; RUN, the Actions run."""
    identity: str
    name: str
    run: int | None = None


def derived_status_parts(repo: str, sha: str, name: str, github) -> list[Part]:
    """The red check runs and statuses on SHA whose verdict derived status NAME is (the rule above), every one read,
    each by its identity (Part); Refused when NAME is not red for its parts, the parts cannot all be read, or a red
    part's identity is not one judge() can rule on: another app's check ("SLUG / NAME"), a name another app's check
    shares with an Actions job, or a name red in two Actions runs. Judged by name, any of those borrowed an Actions
    job's base evidence (#41113's review F1)."""
    statuses = read_in_full(github.json(f"repos/{repo}/commits/{sha}/status?per_page=100", paginate=True),
                            "statuses", f"the combined status of {sha[:12]}")
    status = next((found for found in statuses if found.get("context") == name), None)
    if status is None or status.get("state") not in ("failure", "error"):
        raise Refused(f"'{name}' is {status.get('state') if status else 'not'} on {sha[:12]}: no derived red to judge")
    said = " ".join(str(status.get("description") or "").split())
    form = DERIVED_STATUSES[name].fullmatch(said)
    if form is None:
        raise Refused(f"'{name}': {said[:200]!r} is not a red of the head's other checks, so it is not judged by them")
    parts: list[Part] = []
    running = []
    for found in statuses:
        context = str(found.get("context") or "")
        if context in DERIVED_STATUSES:
            continue
        if found.get("state") == "pending":
            running.append(context)
        elif found.get("state") in ("failure", "error"):
            parts.append(Part(f"status / {context}", context))
    # The newest check run of each (name, app), and of each (name, Actions run).
    by_app: dict[str, dict[str, dict]] = {}
    by_run: dict[str, dict[int, dict]] = {}
    for check in read_in_full(github.json(f"repos/{repo}/commits/{sha}/check-runs?filter=all&per_page=100",
                                          paginate=True), "check_runs", f"the check runs of {sha[:12]}"):
        check_name, slug = str(check.get("name")), str((check.get("app") or {}).get("slug") or "")
        if check_name in DERIVED_STATUSES:
            continue
        if check.get("id", -1) > by_app.setdefault(check_name, {}).get(slug, {}).get("id", -1):
            by_app[check_name][slug] = check
        link = re.search(r"/actions/runs/(\d+)/job/\d+", str(check.get("details_url") or ""))
        if slug == "github-actions" and link:
            run = int(link[1])
            if check.get("id", -1) > by_run.setdefault(check_name, {}).get(run, {}).get("id", -1):
                by_run[check_name][run] = check
    unknown = []
    # A commit status and a check run of one name share every audit line judge() writes for it, so either one red
    # beside the other is unknown (#41117's review F2): judged by name, one would borrow the other's verdict.
    contexts = {str(found.get("context") or ""): found for found in statuses}
    for context in sorted(contexts.keys() & by_app.keys()):
        if (contexts[context].get("state") in ("failure", "error")
                or any(check.get("conclusion") not in GREEN for check in by_app[context].values())):
            unknown.append(f"'status / {context}' and a check run share the name '{context}', so whose red it is "
                           "is unknown")
            parts = [part for part in parts if part.name != context]
            del by_app[context]
    for check_name, apps in sorted(by_app.items()):
        if any(check.get("status") != "completed" for check in apps.values()):
            running.append(check_name)
            continue
        reds = {slug: check for slug, check in apps.items() if check.get("conclusion") not in GREEN}
        if not reds:
            continue
        others = sorted(slug for slug in apps if slug != "github-actions")
        if others:
            unknown.append(f"'{others[0]} / {check_name}' is another app's check"
                           + (f", sharing its name with an Actions job, so whose red it is is unknown"
                              if "github-actions" in apps else ": judge() has no Actions job to rule on it"))
            continue
        actions = apps["github-actions"]
        in_runs = sorted(run for run, check in by_run.get(check_name, {}).items()
                         if check.get("conclusion") in VERDICT_REDS)
        if len(in_runs) > 1:
            unknown.append(f"'{check_name}' is red in {len(in_runs)} Actions runs at {sha[:12]} "
                           f"({', '.join(map(str, in_runs))}), so which job it names is unknown")
            continue
        link = re.search(r"/actions/runs/(\d+)/job/\d+", str(actions.get("details_url") or ""))
        if link is None:
            unknown.append(f"'{check_name}' links no Actions job")
            continue
        parts.append(Part(f"run {link[1]} / {check_name}", check_name, int(link[1])))
    if running:
        raise Refused(f"'{name}': {', '.join(map(repr, sorted(running)))[:300]} not finished at {sha[:12]}, so not every "
                      "red it is a function of can be probed")
    if unknown:
        raise Refused(f"'{name}': " + "; ".join(unknown)[:600] + "; unknown is never excused")
    key = form["key"]
    if not any(key == part.name or key.endswith(f" / {part.name}") for part in parts):
        raise Refused(f"'{name}' names '{key}', which is not red at {sha[:12]} (its reds: "
                      f"{', '.join(part.identity for part in parts)[:300] or 'none'})")
    if form["more"] is not None and len(parts) < 1 + int(form["more"]):
        raise Refused(f"'{name}' counts {1 + int(form['more'])} reds, and {sha[:12]} has {len(parts)}: a red it "
                      "names is not at the head")
    return parts


def derived_status_line(repo: str, name: str, sha: str, parts: list[Part], audit: list[str], jobs: list[dict]) -> str:
    """The audit line for derived status NAME once judge() has judged each of its PARTS (AUDIT, its lines so far; JOBS,
    the head jobs it judged). A red aggregate part (ci-status) has no line of its own, since judge() judges the failed
    jobs under it (head_jobs), so its line is added here from theirs: its own judgement carried into the verdict
    (#41113's review F2). Refused when a part has no verdict."""
    lines = {}
    for part in parts:
        line = next((line for line in audit if line.startswith((f"excused '{part.name}'", f"ignored '{part.name}'"))),
                    None)
        if line is None and part.run is not None and is_aggregate(part.name, repo):
            children = sorted({job.get("name", "") for job in jobs
                               if job.get("run_id") == part.run and job.get("name") != part.name})
            said = {child: next((line for line in audit if line.startswith(f"excused '{child}'")), None)
                    for child in children}
            if children and all(said.values()):
                fixed = all(line.startswith(f"excused '{child}': fixed on base (") for child, line in said.items())
                what = (f"{part.identity}: an aggregate of the failed jobs under it, each judged above: "
                        f"{', '.join(map(repr, children))}")[:600]
                line = f"excused '{part.name}': " + (f"fixed on base ({what})" if fixed else f"its jobs are excused ({what})")
                audit.append(line)
        if line is None:
            raise Refused(f"'{name}': judge() gave its red part {part.identity} no verdict line, so it is not excused")
        lines[part] = line
    red = [part for part, line in lines.items() if line.startswith("excused ")]
    fixed = bool(red) and all(lines[part].startswith(f"excused '{part.name}': fixed on base (") for part in red)
    what = (f"a derived status: its red is a function of the {len(parts)} red checks at {sha[:12]}, every one read "
            f"and judged above: {', '.join(part.identity for part in parts)}")[:900]
    return f"excused '{name}': fixed on base ({what})" if fixed else f"excused '{name}': its parts are excused ({what})"


# One check at one head, named another way (2026-11-12, cmux#38644 at 8e957427, coord-deputy-2: "base_red_excuse says
# 'Web tests (2/4)' 'has not run on exact head', but it did: job 131026209923"). A called workflow's job is the check
# run '<caller job> / <its job>' ('web / Web tests (2/4)'), the checks page shows '<workflow> / <check>', and a caller
# that names either other part was refused as if the check had not run. A name is read as the one Actions check run
# at the head it is a ' / '-part of, either way: the check run's name ends in ' / NAME', or NAME ends in ' / ' and the
# check run's name. A name as written still comes first (a check run, then a status, as before), and a partial part
# ('tests (2/4)') matches nothing. A name more than one check run at the head carries -- as written or as a part --
# is resolved by the workflow its 'WORKFLOW / JOB' prefix names, then by its one failure; with no failure among them
# a name as written keeps the newest attempt (reruns and concurrency-cancelled attempts of one workflow, which the
# superseding logic judges), and a name spelled another way is refused naming every candidate (named_check).
# A head named by a short or upper-case sha is the same commit: GitHub answers its reads, and every job's head_sha is
# the full lower-case one, so each "is this job at the exact head" compare refused (exact_sha).
FULL_SHA = re.compile(r"[0-9a-f]{40}")


def head_check_runs(repo: str, sha: str, github, seen: dict | None = None) -> list[dict]:
    """The newest Actions check run of each (name, run) at SHA, every attempt read (filter=all), sharing one judge
    call's check-run read (SEEN, as linked_checks keeps it). latest_checks keeps one check run per name, so three
    runs whose job is named 'tests' collapse to the newest id there and the other two are never seen; a name is
    resolved from these instead (named_checks)."""
    seen = {} if seen is None else seen
    if "checks" not in seen:
        listed = github.json(f"repos/{repo}/commits/{sha}/check-runs?filter=all&per_page=100", paginate=True)
        seen["checks"] = [check for page in listed for check in page.get("check_runs") or []
                          if (check.get("app") or {}).get("slug") == "github-actions"]
    newest: dict[tuple[str, int | None], dict] = {}
    for check in seen["checks"]:
        key = (str(check.get("name")), check_run_link(check))
        if check.get("id", -1) > newest.get(key, {}).get("id", -1):
            newest[key] = check
    return list(newest.values())


def spelled_candidates(checks: list[dict], name: str) -> list[dict]:
    """The check runs of CHECKS that NAME names another way (above): the name as written is not among them."""
    return [check for check in checks
            if str(check.get("name") or "").endswith(f" / {name}")
            or name.endswith(f" / {check.get('name')}")]


def check_run_link(check: dict) -> int | None:
    """The Actions run CHECK links in its details URL, or None: the one id that tells two check runs of one job name
    apart with no read at all."""
    link = re.search(r"/actions/runs/(\d+)/job/\d+", str(check.get("details_url") or ""))
    return int(link[1]) if link else None


def check_workflow(repo: str, check: dict, github, seen: dict) -> str:
    """The name of the workflow run CHECK belongs to: the 'WORKFLOW / ' prefix the checks page writes before a check
    run's own name, and the part of 'WORKFLOW / JOB' that tells two check runs of one job name apart. '' when the
    check run links no run, or GitHub names none."""
    if (run_id := check_run_link(check)) is None:
        return ""
    run = rest_run(repo, run_id, github, seen)
    return str((run or {}).get("name") or "") if isinstance(run, dict) else ""


def named_check(repo: str, sha: str, name: str, found: list[dict], github, seen: dict, *,
                newest: bool = False) -> tuple[dict, str | None]:
    """The one check run of FOUND that NAME means, and why it was read that way (None when FOUND holds one alone, or
    when the rule that picked it is one the caller's own tools already state, for the caller's audit line). More than
    one check run can carry one job name at one head: three 'tests' at cmuxterm-hq eb73df0c, two of them success and
    the red one the caller was asking about (2026-11-22). The name's own 'WORKFLOW / JOB' prefix is what tells them
    apart, so it is read as the workflow of the run each check run belongs to; with no prefix, or none that names one
    of them, a single failure is what a caller asking why a head is red can mean.

    Attempts of ONE workflow are not that question at all: a rerun, or an attempt concurrency cancelled, is answered
    by recency (the newest attempt of a name is its verdict: a cancelled 'risk evidence' superseded by the newer run
    that passed it, cmux#36965 at 004465b3), and picking an older failure over a rerun that passed would publish a
    red the head no longer has. So the candidates are first collapsed per workflow -- its path, never a display name
    two workflows can share, from the head's one run list -- keeping each workflow's newest, and only what is left
    across workflows is the ambiguity above. A run whose workflow the head's list does not name is its own candidate:
    nothing proves it shares another's workflow.

    With nothing failed among them, NEWEST (what the exact-name caller passes, latest_checks' own rule before this)
    keeps the newest check run and the superseding logic downstream judges it; the spelled-another-way caller has no
    such rule and is refused naming every candidate. A silent pick there answers about a check run nobody asked about
    ('tests' is success: re-run it, of a check run that passed, while the red one was never read).

    The refusal names only what the candidates themselves carry. Reading each one's workflow would be a REST read
    per candidate on a path that is already refusing, so the ones resolved for the prefix above are named and the
    rest are named by their run, which their details URL already gives."""
    if len(found) == 1:
        return found[0], None
    prefixed = []
    workflows: dict[int, str] = {}
    for check in found:
        part = str(check.get("name") or "")
        prefix = name[:-len(f" / {part}")] if part and name.endswith(f" / {part}") else ""
        if prefix:
            workflows[check.get("id")] = check_workflow(repo, check, github, seen)
            if prefix == workflows[check.get("id")]:
                prefixed.append((check, f"the check run of that name in workflow {prefix!r}"))
    if len(prefixed) == 1:
        return prefixed[0][0], prefixed[0][1]
    left = [check for check, _ in prefixed] or found
    attempts = head_runs(repo, sha, github, seen)
    per_workflow: dict[object, dict] = {}
    for check in left:
        link = check_run_link(check)
        run = attempts.get(link) or {}
        # One job's attempts share its name AND its workflow: two check runs named differently (one caller's job
        # prefix and another's, both answering the spelling asked) are two jobs, never attempts of each other, so
        # the name is part of the key. A check run that links no run can only stand alone.
        key = (str(check.get("name")),
               run.get("path") or run.get("workflow_id") or (("run", link) if link else ("check", check.get("id"))))
        if check.get("id", -1) > per_workflow.get(key, {}).get("id", -1):
            per_workflow[key] = check
    left = list(per_workflow.values())
    if len(left) == 1:
        return left[0], None
    red = [check for check in left if check.get("conclusion") in PR_ONLY_RED]
    if len(red) == 1:
        return red[0], (f"the only one of {len(found)} check runs of that name at the head that failed (one per "
                        "workflow, its newest attempt)")
    if newest and not red:
        return max(found, key=lambda check: check.get("id", 0)), None
    listed = ", ".join(f"{check.get('name')!r} ({check.get('conclusion')}, check run {check.get('id')}, "
                       + (f"workflow {workflows[check.get('id')]!r})" if workflows.get(check.get("id"))
                          else f"run {check_run_link(check) or '?'})")
                       for check in sorted(found, key=lambda check: (str(check.get("name")), check.get("id", 0))))
    raise Refused(f"{name}: names {len(found)} check runs at exact head {sha} ({listed[:600]}); which one is meant is "
                  "unknown, so none is judged: name it as 'WORKFLOW / JOB', the checks page's own spelling")


def exact_sha(repo: str, sha: str, github) -> str:
    """SHA as the full lower-case commit id its jobs carry: read from GitHub only when it is shorter."""
    sha = sha.strip().lower()
    if FULL_SHA.fullmatch(sha):
        return sha
    full = str((github.json(f"repos/{repo}/commits/{sha}") or {}).get("sha") or "").lower()
    if not FULL_SHA.fullmatch(full) or not full.startswith(sha):
        raise Refused(f"--sha {sha}: GitHub names no commit {sha} in {repo} (it answered {full[:40] or 'nothing'})")
    return full


def head_jobs(repo: str, sha: str, runs: list[int], checks: list[str], github, *, base: str | None = None,
              excused: list[str] | None = None, suites: SuiteChecks | None = None,
              ignored: list[str] | None = None, seen: dict | None = None,
              evidence: "Evidence | None" = None, rollup_jobs: list[dict] | None = None) -> list[dict]:
    """Failed head jobs; a check that is a jobless status red the base shares adds its line to EXCUSED, and a cancelled
    job a newer run of its workflow passed adds its line to IGNORED (superseding_check). Each red run rollup job
    (ci-status, Skill documentation tests) whose failed children are returned is added to ROLLUP_JOBS
    (run_rollup_line)."""
    sha = exact_sha(repo, sha, github)
    jobs: dict[int, dict] = {}
    contexts: dict[int, list[str]] = {}  # the status contexts each job was judged for (status_job)
    seen = {} if seen is None else seen
    for run in runs:
        guards = []
        run_rollups = []
        children = []
        # The run-level pass: a cancelled run a later green run of its workflow file superseded (superseding_run).
        # Asked of every run with no failed or timed-out job (none at all, or every one passed, skipped, neutral or
        # cancelled: #40963 review F1, a cancelled run whose jobs all passed still read "no failed job found"), and of
        # a run with a cancelled or stale job beside its failures; a run of plain failures reads no run list.
        run_jobs = last_real_jobs(repo, run, github)
        superseded = (superseding_run(repo, sha, run, github, seen)
                      if not any(job.get("conclusion") in VERDICT_REDS for job in run_jobs)
                      or any(job.get("conclusion") in SUPERSEDABLE for job in run_jobs)
                      else None)
        if superseded is not None:
            if ignored is not None:
                why = (f"is superseded by run {superseded['id']} of the same workflow file ({superseded['path']}), "
                       f"{superseded.get('event')}, created later and success on {sha}; the newest completed run is "
                       "the verdict")
                ignored.append(f"ignored '{superseded_name(seen, sha, run)}': its cancelled run {run} {why}")
                ignored.extend(f"ignored '{job.get('name', '')}': its {job.get('conclusion')} job {job.get('id')} in "
                               f"run {run} {why}" for job in run_jobs if job.get("conclusion") in SUPERSEDABLE)
            # Only its cancelled (or stale) jobs are passed over: a failure or a time-out is a verdict whatever a later
            # run says, and is judged below as before.
            run_jobs = [job for job in run_jobs if job.get("conclusion") not in SUPERSEDABLE]
        for job in run_jobs:
            if (job.get("status") == "completed" and job.get("conclusion") in SUPERSEDABLE
                    and (newer := superseding_check(repo, sha, job, github, seen)) is not None):
                name = job.get("name", "")
                if newer.get("conclusion") in GREEN:
                    if ignored is not None:
                        ignored.append(f"ignored '{name}': its {job['conclusion']} job in run {run} is superseded by "
                                       f"job {newer['job_id']} of the same workflow, {newer['conclusion']} on {sha}; "
                                       "the newest completed run is the verdict")
                    continue
                # The newer run's red is the verdict: judge that job, not the cancelled one.
                job = job_for(repo, newer, sha, github)
                if is_aggregate(name, repo):
                    if job.get("conclusion") != "failure":
                        raise Refused(f"'{name}': the newest aggregate job is {job.get('conclusion')}, not failure")
                    found = head_jobs(repo, sha, [job["run_id"]], [], github, ignored=ignored, seen=seen)
                    if not found:
                        raise Refused(f"run {job['run_id']}: its aggregate check failed with no failed job to "
                                      "compare with the base")
                    jobs.update((child["id"], child) for child in found)
                    continue
                jobs[job["id"]] = job
                continue
            if is_aggregate(job.get("name", ""), repo):
                if job.get("conclusion") not in ("success", "skipped", "neutral", None):
                    (run_rollups if job.get("name") in rollups(repo)["run"] else guards).append(job)
                continue
            if job.get("status") == "completed" and job.get("conclusion") not in ("success", "skipped", "neutral"):
                if job.get("head_sha") not in (None, sha):
                    raise Refused(f"{job.get('name')}: job is not for the exact SHA {sha}")
                jobs[job["id"]] = job
                children.append(job)
        for guard in guards:
            if not children:
                raise Refused(f"run {run}: its aggregate check failed with no failed job to compare with the base")
            validate_guard_routes(repo, sha, guard, children, github)
        for rollup in run_rollups:
            # Read here, never in the comparator: only a rollup whose needs name no failed child is judged by its
            # own `no verdict: ` line, so only then is its log read at all.
            said = (None if rollup_has_failed_need(rollup["name"], children, repo)
                    else rollup_no_verdict(repo, rollup, github))
            validate_run_rollup(rollup["name"], children, repo, rollup, said)
            if rollup_jobs is not None:
                rollup_jobs.append(rollup)
    if checks:
        at_head = head_check_runs(repo, sha, github, seen)
        aggregate_jobs = []
        aggregate_runs = []
        for name in checks:
            check = None
            if exact := [found for found in at_head if found.get("name") == name]:
                check, why = named_check(repo, sha, name, exact, github, seen, newest=True)
                if why is not None and excused is not None:
                    excused.append(f"read '{name}' as check run '{check['name']}' (job {check.get('id')}) on {sha}: "
                                   f"{why}")
            if check is None:
                if (job := status_job(repo, sha, name, github, base if excused is not None else None, suites,
                                      evidence)) is not None:
                    if isinstance(job, str):
                        excused.append(job)
                        continue
                    jobs[job["id"]] = job
                    contexts.setdefault(job["id"], []).append(name)
                    continue
                found = spelled_candidates(at_head, name)
                if not found:
                    raise Refused(f"{name}: has not run on exact head {sha}")
                check, why = named_check(repo, sha, name, found, github, seen)
                if excused is not None:
                    excused.append(f"read '{name}' as check run '{check['name']}' (job {check.get('id')}) on {sha}: "
                                   + (why or "the only check run at the head that name is a part of"))
                name = check["name"]
            elif (check.get("conclusion") == "skipped"
                  and (pool := pool_status_refusal(sha, name, head_status(repo, sha, name, github))) is not None):
                # A red named for a pool status whose Actions twin has no verdict (skipped by path routing): the
                # pool's red, never the twin's "is skipped ... re-run it" (cmux#49885).
                raise pool
            job = job_for(repo, check, sha, github)
            if is_aggregate(name, repo):
                # The check-run can remain failed while its Actions job has
                # been retried or replaced.  Never discard this exact job and
                # rescan the run: a green/missing aggregate must not allow its
                # child failures to be excused (a run rollup like ci-status too).
                if job.get("conclusion") != "failure":
                    raise Refused(f"'{name}': exact aggregate job is {job.get('conclusion')}, not failure")
                if name in rollups(repo)["run"]:
                    aggregate_runs.append((name, job))
                    if rollup_jobs is not None:
                        rollup_jobs.append(job)
                    continue
                aggregate_jobs.append(job)
            else:
                if job.get("conclusion") in GREEN and (cancelled := superseded_by_green(repo, sha, job, github, seen)):
                    # The newest run of the name passed; the reds GitHub still lists for it are cancelled runs of
                    # its workflow that it superseded (cmux#36965's 'risk evidence').
                    if ignored is not None:
                        ignored.append(f"ignored '{name}': its newest job {job['id']} on {sha} is "
                                       f"{job['conclusion']}, superseding {len(cancelled)} cancelled run(s) of the "
                                       "same workflow; the newest completed run is the verdict")
                    continue
                if (job.get("conclusion") in SUPERSEDABLE
                        and (newer := superseding_check(repo, sha, job, github, seen)) is not None):
                    # GitHub's latest is by check run id; a newer job of the name decides (linked_checks).
                    if newer.get("conclusion") in GREEN:
                        if ignored is not None:
                            ignored.append(f"ignored '{name}': its {job['conclusion']} job {job['id']} is superseded "
                                           f"by job {newer['job_id']} of the same workflow, {newer['conclusion']} on "
                                           f"{sha}; the newest completed run is the verdict")
                        continue
                    job = job_for(repo, newer, sha, github)
                jobs[job["id"]] = job
        for name, rollup in aggregate_runs:
            if refused_at_setup(rollup):
                raise Refused(f"'{name}' was refused at setup: re-run")
            run = rollup["run_id"]
            found = head_jobs(repo, sha, [run], [], github, ignored=ignored, seen=seen)
            if not found:
                raise Refused(f"run {run}: its aggregate check failed with no failed job to compare with the base")
            said = (None if rollup_has_failed_need(name, found, repo)
                    else rollup_no_verdict(repo, rollup, github))
            validate_run_rollup(name, found, repo, rollup, said)
            jobs.update((job["id"], job) for job in found)
        for guard in aggregate_jobs:
            found = head_jobs(repo, sha, [guard["run_id"]], [], github, ignored=ignored, seen=seen)
            if not found:
                raise Refused(f"run {guard['run_id']}: its aggregate check failed with no failed job to compare with the base")
            validate_guard_routes(repo, sha, guard, found, github)
            jobs.update((job["id"], job) for job in found)
    # Kept apart until here, so a later entry for the same job (another status, or its check run) drops none.
    return [dict(job, status_contexts=contexts[key]) if key in contexts else job for key, job in jobs.items()]


def tip_suite_verdicts(repo: str, workflow, name: str, github, base_jobs: dict[int, list[dict] | None],
                       evidence: "Evidence", suites: SuiteChecks | None = None, job_reads: dict | None = None):
    """(run, job) for each completed suite run of EVIDENCE's base with a verdict for job NAME, newest first, read
    lazily (Evidence.dispatches: none for a stacked parent). Its live job-list reads are the judgement's
    (budgeted_run_jobs, CALL_JOB_READS)."""
    job_reads = {} if job_reads is None else job_reads
    runs = evidence.dispatches(workflow)
    deferred = deferred_first_runs(runs) if name in TREE_JOBS else set()
    suites = suites or SuiteChecks(github, repo)
    candidates = [run for index, run in enumerate(runs)
                  if run.get("status") == "completed" and run.get("conclusion") != "skipped"
                  and not never_carries(run, name) and run["id"] not in deferred
                  and not cancelled_tier_without_verdict(suites, runs, index, name)]
    candidates = candidates[:TIP_SUITE_JOB_READS]
    for index, run in enumerate(candidates):
        if base_jobs.get(run["id"]) is None:
            if not may_hold(suites, candidates, index, name, verdict=True):
                continue
            listed = budgeted_run_jobs(repo, run, github, workflow, name, job_reads)
            if listed is None:
                return  # runs left unread (search_cut)
            base_jobs[run["id"]] = listed
        found = next((found for found in base_jobs[run["id"]] if found.get("name") == name), None)
        if found is not None and found.get("conclusion") in VERDICTS and not refused_at_setup(found):
            yield run, found


# A summary red from a replaced waiting job (2026-11-11): a push's Mac jobs wait in a per-branch concurrency group, and
# a newer push replaces the waiting one ("Canceling since a higher priority waiting request for <group> exists"). Its
# summary gate then wrote "no verdict" and ended red on feat-cmux-next runs 43032789758 and 43037486374 ('cmux-next
# crash ends the app'), before scripts/ci/needs_verdict.py's SUPERSEDED_RULE turned that case into a notice. Such a
# red judged nothing, so it is no base verdict: base_verdicts passes over it to an older run's. It is told by the
# replacement annotation on a source job (SUPERSEDED_SOURCES) of the same run, read only for a red summary whose
# source in that run was cancelled: one annotation read per such source, kept per job id.
REPLACED_READS: dict[int, bool] = {}  # by source job id (an id never changes): whether it was replaced
REPLACED_WAITING = "Canceling since a higher priority waiting request for "
SUPERSEDED_SOURCES = {
    "cmux-next crash ends the app": ("cmux app scheme compile (Debug)",),
    GENERATED_VERDICT_JOB: ("cmux-next swift test", "cmux-next daemon tests"),
    "cmux-next fast tier": ("cmux-next fast tier (build fleet)",),
}


def replaced_while_waiting(repo: str, jobs: list[dict], found: dict, github, cache: dict) -> str | None:
    """The name of the source job whose replacement while waiting explains summary job FOUND's red in a base run
    whose jobs are JOBS, or None. CACHE keeps each source job's answer by id."""
    if found.get("conclusion") != "failure":
        return None
    for source in SUPERSEDED_SOURCES.get(str(found.get("name")), ()):
        job = next((job for job in jobs if job.get("name") == source), None)
        if job is None or job.get("conclusion") != "cancelled" or not isinstance(job.get("id"), int):
            continue
        if job["id"] not in cache:
            try:
                notes = github.json(f"repos/{repo}/check-runs/{job['id']}/annotations")
            except Exception:  # an unread annotation keeps the red a verdict, as before
                notes = []
            cache[job["id"]] = any(isinstance(note, dict) and str(note.get("message") or "").startswith(REPLACED_WAITING)
                                   for note in notes or [])
        if cache[job["id"]]:
            return source
    return None


# A search the cap cut short is not a search read to its end (2026-11-19, cmuxterm-hq#14126): base_verdicts stopped at
# BASE_JOB_READS with runs of the window still unread, and judge() said "no feat-cmux-next run of its workflow has a
# verdict for it to compare with", the words of a window read whole, so the red stopped as the PR's own. Each
# judgement counted every list against the cap, kept ones too, so a retry read the same 40 and said the same. Now a list
# already kept (a completed attempt's: the jobs cache, the settled store) costs no read and is not counted, the cut is
# recorded (SEARCH_CUT), and a cut search says "incomplete" with a retry time: CUT_RETRY_S, glaeda-gh's sweep window,
# by which the lists read now are kept and the next judgement reads past them. The read budget is the workflow's; the
# cut is one search's, its workflow and job name (cmux#47687's review F2: a later job of the workflow whose suite checks
# rule out every run left had no read cut and must not inherit another job's cut).
SEARCH_CUT = "search-cut"
CUT_RETRY_S = 600
# The judgement's own budget, under glaeda-gh's sweep guard (2026-11-20, cmux#47687 and cmuxterm-hq#14535): the guard
# (gh_sweep_refusal) refuses a caller past GH_SWEEP_MAX = 30 distinct run or job lists read in GH_SWEEP_WINDOW = 600 s,
# and the land queue judges every PR as one caller. Two workflows each searched to BASE_JOB_READS (40) read past it
# halfway through, the guard refused the next list, and the judgement ended "unreadable" instead of this search's timed
# "incomplete". Now every live base job-list read of a judgement, whatever its workflow or job, is counted in
# job_reads[CALL_READS] and stops at CALL_JOB_READS, leaving room under the guard for the head's own reads; a list
# already kept costs nothing and is read first (kept_run_jobs), so each retry gets further. A guard refusal that comes
# anyway (another judgement of the same caller spent the window) cuts the search the same way: a read that never
# happened is a timed retry, never a verdict. Cold, a search that needs N live lists finishes within ceil(N / 24) calls.
CALL_JOB_READS = 24
CALL_READS = "call-job-reads"
SWEEP_GUARD_REFUSED = re.compile(r"glaeda-gh: refused: this caller read the jobs of \d+ different runs or jobs")
INCOMPLETE = "incomplete: read"  # cut_refusal's words; land-judge reads them as a timed retry, never a red
JOB_BUDGET = ("job-list-budget",)  # the judgement memo's key for job_budget


def job_budget() -> dict | None:
    """The judgement's one live job-list budget (in JUDGEMENT_READS): the run ids read live ("read", at most
    CALL_JOB_READS), whether it is spent ("spent": past it, or the sweep guard refused), and the red being judged
    ("name", set by judge). Every live base_run_jobs read counts, the per-test paths' (web_base_runs,
    gallery_run_results, pr_only_step_verdict, compile_errors_verdict, ...) as much as base_verdicts'. None outside a
    judgement."""
    memo = JUDGEMENT_READS.get()
    if memo is None:
        return None
    return memo.setdefault(JOB_BUDGET, {"read": set(), "spent": False, "name": None})


def budget_spent(job_reads: dict) -> int:
    """The live job lists this judgement read: the shared budget's (job_budget), else job_reads' own count."""
    budget = job_budget()
    if budget is None:
        return job_reads.get(CALL_READS, 0)
    return CALL_JOB_READS if budget["spent"] else max(len(budget["read"]), job_reads.get(CALL_READS, 0))


def kept_run_jobs(repo: str, run: dict) -> list[dict] | None:
    """RUN's kept job list (base_run_jobs' disk cache, or the settled store) when it has one, else None: no read."""
    where = jobs_cache()
    if (where is not None and run.get("status") == "completed" and isinstance(run.get("run_attempt"), int)
            and re.fullmatch(r"[0-9TZ:.+-]{10,40}", str(run.get("updated_at") or ""))):
        stamp = re.sub(r"[^0-9]", "", run["updated_at"])
        key = where / f"{repo.replace('/', '--')}-{int(run['id'])}-{run['run_attempt']}-{stamp}.json"
        try:
            kept = json.loads(key.read_text())
            if (isinstance(kept, list) and all(isinstance(job, dict) and job.get("run_id") == run["id"] for job in kept)
                    and time.time() - key.stat().st_mtime < JOBS_CACHE_SECONDS):
                return kept
        except (OSError, ValueError):
            pass
    settled = settled_answer(f"repos/{repo}/actions/runs/{run['id']}/jobs?filter=latest&per_page=100")
    if settled is NOT_KEPT:
        return None
    jobs = [found for page in (settled if isinstance(settled, list) else [settled]) if isinstance(page, dict)
            for found in page.get("jobs") or []]
    for job in jobs:
        if job.get("run_id") is None:
            job["run_id"] = run["id"]
    return jobs


def search_reads(name: str) -> int:
    """The live job lists one judgement's search of the base's runs for job NAME may read: CALL_JOB_READS, less
    TIP_SUITE_JOB_READS for a suite job (SUITE_JOBS), whose push runs never build it and whose verdict is a dispatched
    tip suite run's, so tip_suite_verdicts still reads those in the same judgement. Cold, a search that needs N live
    lists finishes within ceil(N / search_reads(NAME)) judgements, since each one's lists are kept."""
    return CALL_JOB_READS - (TIP_SUITE_JOB_READS if name in SUITE_JOBS else 0)


def budgeted_run_jobs(repo: str, run: dict, github, workflow, name: str, job_reads: dict,
                      reserve: int = 0) -> list[dict] | None:
    """RUN's job list for a base search for job NAME in WORKFLOW: a kept one first (kept_run_jobs: no read, not
    counted), else one live read counted toward the workflow's BASE_JOB_READS and the judgement's CALL_JOB_READS
    (job_reads[CALL_READS]), less RESERVE kept back for a later search of the same judgement (a suite job's
    dispatched tip suite runs, tip_suite_verdicts, after its push runs). None when either is spent, or when glaeda-gh's sweep guard refused the read (then no live
    list is read again this judgement), with the search's cut recorded for search_cut: a timed retry, never a verdict."""
    kept = kept_run_jobs(repo, run)
    if kept is not None:
        return kept
    if job_reads.get(workflow, 0) >= BASE_JOB_READS or budget_spent(job_reads) >= CALL_JOB_READS - reserve:
        job_reads[(SEARCH_CUT, workflow, name)] = job_reads.get(workflow, 0)
        return None
    try:
        listed = base_run_jobs(repo, run, github)
    except JobBudgetCut:
        job_reads[CALL_READS] = CALL_JOB_READS
        job_reads[(SEARCH_CUT, workflow, name)] = job_reads.get(workflow, 0)
        return None
    except Refused as why:
        if not SWEEP_GUARD_REFUSED.search(str(why)):
            raise
        job_reads[CALL_READS] = CALL_JOB_READS
        job_reads[(SEARCH_CUT, workflow, name)] = job_reads.get(workflow, 0)
        return None
    job_reads[workflow] = job_reads.get(workflow, 0) + 1
    job_reads[CALL_READS] = job_reads.get(CALL_READS, 0) + 1
    return listed


def search_cut(job_reads: dict, name: str, *workflows) -> int | None:
    """The job lists read before the cap cut a base search for job NAME in any of WORKFLOWS short, or None when none
    was cut."""
    return search_cut_any(job_reads, *((workflow, name) for workflow in workflows))


def search_cut_any(job_reads: dict, *searches: tuple) -> int | None:
    """search_cut over SEARCHES, each (workflow, the check name searched for there: a batch suite's differs)."""
    cut = [job_reads[(SEARCH_CUT, workflow, name)] for workflow, name in searches
           if workflow is not None and (SEARCH_CUT, workflow, name) in job_reads]
    return max(cut) if cut else None


def cut_refusal(name: str, base: str, read: int) -> str:
    at = (datetime.now(timezone.utc) + timedelta(seconds=CUT_RETRY_S)).strftime("%H:%MZ")
    return (f"'{name}': {INCOMPLETE} {read} job lists of {base} runs of its workflow (at most {CALL_JOB_READS} a "
            f"judgement, {BASE_JOB_READS} a workflow, besides the kept ones) and none had a verdict for it, with older "
            f"runs still unread; not a verdict: retry after {at}")


def base_verdicts(repo: str, workflow, name: str, github, evidence: "Evidence", base_jobs: dict,
                  job_reads: dict, suites: SuiteChecks | None = None):
    """(run, job) for each completed BASE run with a verdict for job NAME, newest first, read lazily: the window of
    BASE_RUNS_PAGE runs (at most BASE_JOB_READS job lists per workflow), then, for a SUITE_JOBS job, the base's
    dispatches (tip_suite_verdicts). A base push run's Mac job is often cancelled by the next push, or refused by a
    mini, so a run with no verdict for the job is passed over, and one its check suite shows has none costs no job
    read and is not counted toward BASE_JOB_READS (cmux#42047). Every run is EVIDENCE's (Evidence: the base's, or a stacked parent's at its head)."""
    seen: set[int] = set()
    # Every read below is of a base run, so it reads the repo whose runs are the base's verdict of record, which is
    # REPO for every repo that runs its own base pushes (Evidence.verdict_repo, BASE_VERDICT_REPO).
    repo = evidence.verdict_repo
    if suites is None or getattr(suites, "repo", repo) != repo:
        # A caller's SuiteChecks reads the PR's repo; a base in another repo needs that repo's, once per judge, so
        # both verdict searches of one judge (the PR run's workflow and its base caller's) share the one reader.
        suites = evidence.cache.setdefault(("suites", repo), SuiteChecks(github, repo))
    runs = evidence.runs(workflow)
    for index, candidate_run in enumerate(runs):
        if never_carries(candidate_run, name) or cancelled_tier_without_verdict(suites, runs, index, name):
            continue
        if base_jobs.get(candidate_run["id"]) is None:
            if not may_hold(suites, runs, index, name, verdict=True):
                continue  # its suite has no verdict for NAME: no job read, so none counted (the sweep limit's note)
            listed = budgeted_run_jobs(repo, candidate_run, github, workflow, name, job_reads,
                                       reserve=CALL_JOB_READS - search_reads(name))
            if listed is None:
                break  # runs left unread (search_cut)
            base_jobs[candidate_run["id"]] = listed
        found = next((found for found in base_jobs[candidate_run["id"]] if found.get("name") == name), None)
        if found is not None and replaced_while_waiting(repo, base_jobs[candidate_run["id"]], found, github,
                                                        REPLACED_READS):
            continue
        if found is not None and found.get("conclusion") in VERDICTS and not refused_at_setup(found):
            seen.add(candidate_run["id"])
            yield candidate_run, found
    if name in SUITE_JOBS:
        for run, found in tip_suite_verdicts(repo, workflow, name, github, base_jobs, evidence, suites, job_reads):
            if run["id"] not in seen:
                seen.add(run["id"])
                yield run, found


# A stale base pass (2026-11-02): base_red_excuse.py read only completed base runs, and a base run completes when its
# slowest job does. Between 09:13Z and 09:23Z every feat-cmux-next run from #31930 on was still running, so the newest
# completed run was 41418052327 at c47a99fcb9, before #31930 and before cmux#31338's merge-base e3c495d3 (#31931). Its
# 'cmux-next guards / defaults-snapshot' passed, and the real base red #31930 caused there was refused as the PR's own.
# So the base window lists runs of every status, and a finished job in a running run is a verdict. And a pass that
# tested a commit before the PR's merge-base says nothing about the base the PR was built on: a red then waits for a
# newer verdict (before_merge_base) instead of being called the PR's own.


def before_merge_base(repo: str, base: str, sha: str, base_run: dict, github, evidence: "Evidence") -> str | None:
    """Why BASE_RUN tested a commit older than the merge-base of SHA with BASE, or None when it did not (or that
    cannot be told). The merge-base is EVIDENCE's (Evidence.merge_base), read once per judge."""
    merge_base, tested = evidence.merge_base(sha), tested_sha(base_run)
    if not re.fullmatch(r"[0-9a-f]{40}", merge_base) or not re.fullmatch(r"[0-9a-f]{40}", tested):
        return None
    if tested == merge_base:
        return None
    status = github.json(f"repos/{repo}/compare/{merge_base}...{tested}?per_page=1").get("status")
    if status in ("ahead", "identical"):
        return None
    return f"tested {tested[:12]}, which is {status or 'not after'} the merge-base {merge_base[:12]}"


def created(run: dict) -> datetime | None:
    try:
        return datetime.fromisoformat(str(run.get("created_at")).replace("Z", "+00:00"))
    except ValueError:
        return None


# Fixed on the base (2026-10-31): a pull request whose merge-base is older than a base fix keeps the red the fix
# removed. The release-notary and workflow guard tests (tests/*.py, run by unittest or pytest) read the workflows,
# the scripts and the release manifests, not the pull request's product code, so a red one that passes on the newest
# base was the base's at the merge-base: cmux#27584, #27918, #27905 and #27775 were stranded as their own reds by
# test_every_part_of_bun_run_check_runs_in_the_warn_branch and test_cmux_next_follows_the_committed_target_graph.
# A failing test is excused as fixed on the base only when all of these hold:
#   (a) the newest base verdict for its job is a pass, at a commit strictly after the pull request's merge-base;
#   (b) it is a tests/*.py guard test whose file the log names (a pytest id, or the unittest traceback's own frame),
#       every failed step of the job is such a test's (or the job's own `red check:` rollup of them), and the pull
#       request's diff from its merge-base touches neither that file nor any path the test reads. Only a test whose
#       file is declared in GUARD_READS qualifies (GUARD_READS_DEFAULT plus its own product paths): an undeclared
#       test may read anything (tests/test_docs_deploy_auth_guard.py reads web/), so it is refused, never guessed;
#   (c) the run is whole: a crash or a cut-short run never counts (refused before this is asked).
# Only a declared guard job (GUARD_JOBS) qualifies, and each failing test must be one its failed step's own script
# runs (the step's echo names the test file) with a whole test-run summary printed: a Swift, cargo or webview job, or
# product code printing a `FAILED tests/x.py::...` line, is never fixed on the base, unless it is a package job whose
# inputs are declared (PACKAGE_JOBS, below).
TOP_LEVEL = "top-level files"  # every path with no directory: package.json, .gitmodules, the entitlements, ...
RELEASE_MANIFESTS = (TOP_LEVEL, "release-notes/", "homebrew-cmux/", "cmux.xcodeproj/", "Resources/", "ghostty-next",
                     "vendor/")
GUARD_READS_DEFAULT = (".github/", "scripts/", "tests/") + RELEASE_MANIFESTS
# The guard tests that can be fixed on the base, by file, with the product paths each reads beyond the default. A
# test is declared here only after its reads are checked; any other test's red is refused.
GUARD_READS = {
    # cmux_next_route and the warn-branch check read the CmuxNext target graph, webviews/package.json and the
    # cmux-tui and Native Cargo manifests.
    "tests/test_cmux_next_checks_workflow.py": ("Packages/", "webviews/", "cmux-tui/", "Native/"),
    # focused_tests.plan reads the tree: Swift imports, the CmuxNext target graph, the webviews import graph, Cargo.
    "tests/test_car_guards.py": ("Packages/", "webviews/", "cmux-tui/", "Native/"),
}
# The check scripts whose red is fixed on the base by its output's identity (2026-11-11). A check step names no test:
# check-spawn-owner.py prints `check-spawn-owner: PATH has N spawn line(s) with no owner (...)` per file over its
# baseline (test_reds.CHECK_RULE), and its rules test runs it over the whole tree. The red is about PATH alone: which
# lines of PATH spawn with no owner, the baseline's row for it, and whether its crate declares PATH test code
# (`#[cfg(test)] mod name;` in its parent module). So a check rule's red reads the check's own files and the crate of
# each file it names, never the tree, and is excused only when the PR's diff touches none of them: a spawn the PR
# adds in another file is its own line naming that file. Every line of the failed step must be the check's (its
# rule lines, their site lines, its closing `next:` line, its notes, the exit), with the closing line after the last
# rule line; anything else (`... raises PATH` from a baseline raised above the base's, a crash) is refused. A test
# that only runs the check over the tree (WRAPPERS) reads the same, and its file, when its failure quotes the rule
# lines and every line naming the check is one of them. Evidence from passing steps never counts: only failed
# steps' lines are read (failed_view).
CHECK_RULE_JOBS = {
    "check-spawn-owner": {
        "script": "scripts/cmux-next/check-spawn-owner.py",
        "reads": ("scripts/cmux-next/check-spawn-owner.py", "scripts/cmux-next/spawn-owner-baseline.tsv",
                  "scripts/cmux-next/baseline_renames.py"),
        "site": re.compile(r"^  (cmux-tui/crates/\S+\.rs):\d+: \S"),
        "done": re.compile(r"^next: spawn the task with its owner's "),
        "note": re.compile(r"^check-spawn-owner: (cmux-tui/crates/\S+\.rs) now has \d+ spawn line\(s\) with no owner, "
                           r"baseline \d+\. "),
        "wrappers": {"tests/test_spawn_owner_ratchet.py": ("test_the_committed_baseline_holds_on_this_tree",)},
        "wrapper_reads": ("tests/git_fixture_env.py",),
    },
}
RULE_CRATE = re.compile(r"(cmux-tui/crates/[\w.+-]+/)\S+$")


def check_rule_step(output: list[str]) -> dict[str, tuple[str, str]]:
    """{failure key: (rule, the file it names)} of a failed step (OUTPUT: its printed lines, no echo) whose every line is
    one check rule's own (CHECK_RULE_JOBS); raises Refused naming the first line that is not."""
    found: dict[str, tuple[str, str]] = {}
    rules, last_rule, done = set(), -1, -1
    for n, text in enumerate(output):
        if not text.strip() or test_reds.PROCESS_EXIT.match(text):
            continue
        if match := test_reds.CHECK_RULE.match(text):
            found[test_reds.check_rule_key(match)] = (match.group(1), match.group(2))
            rules.add(match.group(1))
            last_rule = n
            continue
        if len(rules) == 1:
            spec = CHECK_RULE_JOBS[next(iter(rules))]
            if (site := spec["site"].match(text)) and any(path == site.group(1) for _, path in found.values()):
                continue
            if spec["done"].match(text):
                done = n
                continue
            if spec["note"].match(text):
                continue
        raise Refused(f"its failed step prints a line that is not its check rule's: {text[:200]}")
    if len(rules) != 1:
        raise Refused("its failed step names no one check rule")
    if done < last_rule:
        raise Refused(f"its {next(iter(rules))} step did not print its closing line after its last finding (cut short)")
    for _, path in found.values():
        if not RULE_CRATE.match(path):
            raise Refused(f"{path} is not under one crate of cmux-tui/crates/")
    return found


def check_rule_reads(rule: str, paths) -> tuple[str, ...]:
    """What a check rule's red reads: the check's own files and the crate of each file it names."""
    crates = sorted({RULE_CRATE.match(path).group(1) for path in paths})
    return tuple(CHECK_RULE_JOBS[rule]["reads"]) + tuple(crates)


def wrapped_rule_reads(path: str, name: str, output: list[str]) -> tuple[str, ...] | None:
    """The reads of failing test NAME of tests/*.py file PATH when it is a declared wrapper of a check rule
    (CHECK_RULE_JOBS' wrappers) and its step's OUTPUT quotes that rule's lines, and no other line naming the check;
    None when it is no wrapper (it is judged as any guard test); Refused when it is one whose output does not hold."""
    method = name.split(" ", 1)[0]
    for rule, spec in CHECK_RULE_JOBS.items():
        if method not in spec["wrappers"].get(path, ()):
            continue
        named = set()
        for text in output:
            if match := test_reds.CHECK_RULE_QUOTED.search(text):
                if match.group(1) == rule:
                    named.add(match.group(2))
                    continue
            if f"{rule}:" in text and not spec["note"].match(text):
                raise Refused(f"{name}: a line naming {rule} is not one of its findings: {text[:200]}")
        if not named:
            raise Refused(f"{name}: wraps {rule}, and its failure quotes none of its findings")
        if not all(RULE_CRATE.match(found) for found in named):
            raise Refused(f"{name}: a {rule} finding is not under one crate of cmux-tui/crates/")
        return (path,) + tuple(spec["wrapper_reads"]) + check_rule_reads(rule, named)
    return None


# The jobs that run the declared guard tests and checks, by (workflow file, job id), never by a name typed here
# (2026-11-11): GUARD_JOBS named only cmux-next.yml's checks job, so cmux#41205 at ba8ff399 and cmux#41220 at c7b757f0,
# red in cmux-next-guards.yml's 'cmux-next size cap, crash ratchet, ...' and 'tooling-tests' for a spawn-owner red
# #41227 had fixed on base, were refused as "not a declared guard job (GUARD_JOBS)". Each job's check name (its
# `name:`, else its id, cut as GitHub cuts a name past 100 characters) is derived into GUARD_JOBS_FILE by
# `base_red_excuse.py --write-rollups`, read with no YAML parser like ROLLUPS_FILE. tests/test_base_red_excuse.py
# fails when the file differs from the workflows, and when a job of a GUARD_WORKFLOWS file, or a workflow that runs
# on pull requests, is neither declared here nor excluded with its reason. A declared job only qualifies the red for
# the rules below: every failed step must still be a declared guard test's or check's (guard_tests).
GUARD_JOB_IDS = (("cmux-next.yml", "checks"), ("cmux-next-guards.yml", "own-change-checks"),
                 ("cmux-next-guards.yml", "static-checks"), ("cmux-next-guards.yml", "tooling-tests"))
_PRODUCT = "builds, tests or generates from product code (Swift, Rust, web), so its red is never a guard's"
_PLACE = "places, routes or waits for runners and runs: no verdict of its own on the tree"
_PUBLISH = "requests, publishes, attributes or comments: no test verdict of its own"
_FAIL_FAST = ("head fail-fast (head-fail-fast.yml, #54837): cancels the head's other heavy runs once the job it "
              "needs is red; it reads no tree and gives no verdict of its own")
# Every job of these workflows is declared (GUARD_JOB_IDS) or excluded here with its reason.
GUARD_WORKFLOWS = {
    "cmux-next-guards.yml": {
        "coalesce": "the window gate (base-coalesce.yml): decides whether a push runs the guards, reads no tree",
        "pinned-asset-store": "reads the pinned asset store over the network, not the tree",
        "nightly-guards": "calls ci-guards.yml, whose jobs are classified there (GUARD_JOB_SUFFIXES)",
        "ci-guard-group": "judged step by step against the base by its own rule (GUARD_GROUP_JOB)",
        "release-notary": "skipped on a pull request (its `if:`): it judges a push to the branch on its own "
                          "(guards_new_reds.py --tip), so no pull request's red is its",
        "rust-notices-tree": _PRODUCT,
        "pr-red-checks": _PUBLISH,
        "fast-check-route": "decides from the changed paths which guard jobs run; it checks nothing itself",
        "security-holes": "judges the workflow holes and secrets the change's own diff adds against the base's "
                          "(scripts/static-analysis/ratchet.py), not a declared tree read",
        "static-checks-traced-audit": "push-only shadow audit of static-checks' traced inputs (its `if:`): no pull "
                                      "request's red is its",
        "tooling-tests-base-red": "decides whether tooling-tests skips while the base is red (base_red_skip.py); "
                                  "it checks nothing itself",
        "tooling-tests-fail-fast": _FAIL_FAST,
    },
    "ci-guards.yml": {
        "workflow-guard-submodule-forward-only": "reads the submodules' remote history, not only the tree",
        "workflow-guard-tests": "its release-notary group is GUARD_JOB_SUFFIXES; the other groups' tests are "
                                "undeclared and may read any path",
        "workflow-guard-history": "reads the pull request's commit history, not only the tree",
        "workflow-guard-cli-scripts": "runs the CLI scripts over product code",
        "workflow-guard-source-lints": "lints product source",
        "guard-status": "a routed rollup (ROUTED_ROLLUPS), judged by the jobs under it",
    },
    "cmux-next.yml": {
        **dict.fromkeys(("push-head-preflight", "path_route", "dev-daily-tree-wait",
                         "macos-placement", "app-compile-placement",
                         "fast-tier-rerun-placement", "fast-tier-handback-placement", "dev-daily-place",
                         "dev-landing-place", "release-compile-fast-admission", "compile-status-handoff"), _PLACE),
        **dict.fromkeys(("web-bundles", "same-tree-cmux-tui", "swift-canary-fleet", "app-compile-fleet",
                         "cmux-scheme-compile-fleet", "swift-canary", "fast-tier-fleet", "fast-tier", "fast-tier-cargo",
                         "swift-test", "fast-tier-fleet-mac",
                         "daemon-test", "generated-files", "generated-verdict", "release-compile-fast",
                         "release-compile", "swift-exports-cache", "cmux-scheme-compile", "crash-ends-app",
                         "dev-landing-compile", "release-compile-revert", "compile-status",
                         "generated-files-linux"), _PRODUCT),
        **dict.fromkeys(("app-compile-fleet-fail-fast", "fast-tier-fail-fast", "fast-tier-cargo-fail-fast",
                         "web-bundles-fail-fast", "generated-files-fail-fast"), _FAIL_FAST),
        **dict.fromkeys(("request-nightly-next", "request-cmux-next-dev-publish", "pr-red-checks",
                         "push-attribution", "same-tree-status-daemon", "same-tree-status-scheme"), _PUBLISH),
        "pure-checks-coalesce": "the window gate (base-coalesce.yml): decides whether a push runs the pure checks, "
                                "reads no tree",
        "generated-files-base-red": "decides whether generated-files skips while the base is red (base_red_skip.py); "
                                    "it checks nothing itself",
    },
}
GUARD_JOBS_FILE = Path(__file__).with_name("base_red_guard_jobs.json")
GITHUB_NAME_MAX = 100  # GitHub cuts a longer job or check name to its first 97 characters and "..."


def github_job_name(name: str) -> str:
    """NAME as the jobs and check-runs APIs report it: past GITHUB_NAME_MAX characters, cut to 97 and '...'
    ('cmux-next static checks (..., page strings)' is '... page stri...' there)."""
    return name if len(name) <= GITHUB_NAME_MAX else name[:GITHUB_NAME_MAX - 3] + "..."


def derive_guard_jobs(workflows: Path = WORKFLOWS) -> dict:
    """GUARD_JOBS_FILE's contract from the workflow files: {"jobs": {check name: {"workflow", "job"}}}; refused when a
    declared job is missing or has no one fixed name."""
    yaml = yaml_module()
    out: dict = {}
    for file, job_id in GUARD_JOB_IDS:
        where = f".github/workflows/{file}"
        jobs = _workflow(yaml, lambda f: (workflows / f).read_text(), file)[1]
        if not isinstance(jobs.get(job_id), dict):
            raise Refused(f"{where}: no job {job_id}")
        check = _check_matcher(job_id, jobs[job_id], where)
        if check["prefixes"] or len(check["exact"]) != 1:
            raise Refused(f"{where}: guard job {job_id} has no one fixed name")
        out[github_job_name(check["exact"][0])] = {"workflow": file, "job": job_id}
    return {"jobs": dict(sorted(out.items()))}


def load_guard_jobs() -> frozenset[str]:
    """The declared guard jobs' check names from GUARD_JOBS_FILE; none (so no red qualifies as a guard job's) when it
    is missing or malformed."""
    try:
        jobs = json.loads(GUARD_JOBS_FILE.read_text()).get("jobs")
    except (OSError, ValueError, AttributeError):
        return frozenset()
    if not isinstance(jobs, dict) or not all(isinstance(name, str) and name for name in jobs):
        return frozenset()
    return frozenset(jobs)


GUARD_JOBS = load_guard_jobs()
GUARD_JOB_SUFFIXES = ("workflow-guard-tests / release-notary",)
GUARD_TEST_FILE = re.compile(r"tests/[\w.-]+\.py")
# A finished test run: unittest's `Ran N tests in`, or pytest's closing `==== ... in Ns ====` line.
TEST_RUN_SUMMARY = re.compile(r"^Ran \d+ tests? in [\d.]+s$|^=+ .*\bin [\d.]+s\b.*=+$")
# A traceback frame in a tests/*.py file: `File "/…/tests/test_x.py", line 12, in test_y`.
TRACEBACK_FRAME = re.compile(r'^\s*File "(?:[^"]*/)?(tests/[\w.-]+\.py)", line \d+, in (\w+)$')
# The cmux-next checks job's last step (`Fail on any red check`) names each red step it rolls up.
ROLLUP_RED = re.compile(r"^##\[error\]red check: \S")
# A compare lists at most 300 files: a longer diff cannot be shown to stay out of a test's paths.
COMPARE_FILES_CAP = 300


# Fixed on the base for a package's own test job (2026-11-07). cmux#36988 (policy.json, pane methods and the web
# Context screen, d286aa2f) failed CmuxMobileKit's silentDropDetectionBenchmark, a wall-clock bound a loaded runner
# missed with no CmuxMobileKit change in the PR; once the base fixed the test (#37535), a PR branched before the fix
# kept that red as its own. A package job is the test run of one Swift package and the Rust it links, so a PR that
# changes none of its inputs cannot have caused a red that passes on the newest base after its merge-base: (a) and
# (c) above hold as for a guard test, and instead of (b) every failed step is one of the job's test steps, naming at
# least one failing test, and the PR's diff touches none of the job's declared reads nor GUARD_READS_DEFAULT. The
# reads are declared, never guessed: the package directories, the Rust crates its FFI builds and the files their
# sources include_str! (cmux-rd-ffi's tests read schemas/remote-tab/) and the repository files its Swift names by path
# (its tests read cmux-tui/spec/ and schemas/deeplinks/ at run time), checked against the tree by
# tests/test_base_red_excuse.py. At the head they are checked again: every Swift package Package.swift reaches by
# path and every Rust crate the Cargo manifests reach by path (cargo_crates, which must cover every path crate in the
# Cargo.lock) must lie in them, and every failed step must name its own failing test, else the red is refused (a new dependency the
# declaration has not caught up with reads paths this rule cannot see).
PACKAGE_JOBS = {
    "CmuxMobileKit tests (macOS swift test, iOS simulator)": {
        "steps": ("swift test (macOS)", "xcodebuild test (iOS simulator)"),
        "swift": ("cmux-next-ios/CmuxMobileKit",),
        "cargo_lock": "cmux-next-ios/rust/Cargo.lock",
        "reads": ("cmux-next-ios/CmuxMobileKit/", "cmux-next-ios/rust/", "cmux-next-ios/.cargo/", ".cargo/",
                  "Packages/Shared/", "Packages/iOS/", "cmux-tui/Cargo.toml", "cmux-tui/Cargo.lock",
                  "cmux-tui/rust-toolchain.toml", "cmux-tui/rust-toolchain", "cmux-tui/.cargo/",
                  "cmux-tui/crates/cmux-rd-core/", "cmux-tui/crates/cmux-rd-engine/", "cmux-tui/crates/cmux-rd-ffi/",
                  # cmux-wg's remote_stream_bench example dev-depends on cmux-rd-link
                  "cmux-tui/crates/cmux-rd-link/",
                  "cmux-tui/crates/cmux-rd-proto/", "cmux-tui/crates/cmux-remote-browser/",
                  "cmux-tui/crates/cmux-terminal-prediction/",
                  # cmux-mobile-link-ffi depends on cmux-terminal-projection (#42219)
                  "cmux-tui/crates/cmux-terminal-projection/",
                  "cmux-tui/crates/cmux-transport/", "cmux-tui/crates/cmux-wg/",
                  # cmux-mobile-link-ffi depends on cmux-window-rules (#43111)
                  "cmux-tui/crates/cmux-window-rules/", "schemas/remote-tab/",
                  # cmux-window-rules' tab group tests include_str! the shared vectors (#57843)
                  "schemas/tab-group-rules/",
                  # a crate the kit's manifests reach since #58214 (cmux-vnc's vnc_* JSON ops)
                  "cmux-tui/crates/cmux-vnc/",
                  # cmux-mobile-link and cmux-mobile-host send the dev build's space (cmux-build-space, #43648),
                  # which reads the bundle rule from cmux-agent-pane-policy; its `testing` feature adds cmux-scope
                  "cmux-tui/crates/cmux-build-space/", "cmux-tui/crates/cmux-agent-pane-policy/",
                  "cmux-tui/crates/cmux-scope/", "cmux-tui/crates/cmux-unix-socket/",
                  # cmux-next-ios/rust names the phone's message preview words (cmux-message-preview, d1024754)
                  "cmux-tui/crates/cmux-message-preview/",
                  # cmux-agent-pane-policy's bundle rule tests read the shared build-identity vectors
                  "schemas/build-identity/",
                  # cmux-wg's smoltcp is the vendored copy ([patch.crates-io] in cmux-next-ios/rust)
                  "cmux-tui/vendor/smoltcp/",
                  # cmux-mobile-host's tests read the Mac's lane policy to keep the two in step
                  "Packages/macOS/CmuxNext/Sources/CmuxNextMobile/DaemonLane/DaemonLanePolicy.swift",
                  # the kit's Swift tests read the shared specs from the repository root at run time
                  "cmux-tui/spec/full-access-modes.json", "schemas/deeplinks/agent-link.json",
                  # the crates cmux-next-ios/rust reaches since (cargo_crates at feat-cmux-next, 2026-11-26)
                  "cmux-tui/crates/cmux-auto-session/", "cmux-tui/crates/cmux-braid-carrier/",
                  "cmux-tui/crates/cmux-braid-class/", "cmux-tui/crates/cmux-braid-path/",
                  "cmux-tui/crates/cmux-bundle/", "cmux-tui/crates/cmux-cloud-disk/",
                  "cmux-tui/crates/cmux-cloud-handlers/", "cmux-tui/crates/cmux-cloud-start-core/",
                  "cmux-tui/crates/cmux-cloud-wire/", "cmux-tui/crates/cmux-composer-send/",
                  "cmux-tui/crates/cmux-deadline/", "cmux-tui/crates/cmux-egress/", "cmux-tui/crates/cmux-fault/",
                  "cmux-tui/crates/cmux-felt/", "cmux-tui/crates/cmux-follow-cam/",
                  "cmux-tui/crates/cmux-mobile-core/", "cmux-tui/crates/cmux-mobile-last-place/",
                  "cmux-tui/crates/cmux-output-paint/", "cmux-tui/crates/cmux-process/",
                  "cmux-tui/crates/cmux-rd-screen/",  # cmux-mobile-link-ffi's screen stream rules
                  "cmux-tui/crates/cmux-relay-snapshot/", "cmux-tui/crates/cmux-remote-protocol/",
                  "cmux-tui/crates/cmux-share-approval/", "cmux-tui/crates/cmux-tab-snapshots/",
                  "cmux-tui/crates/cmux-tailnet-join/", "cmux-tui/crates/cmux-tailnet/",
                  "cmux-tui/crates/cmux-terminal-sizing/", "cmux-tui/crates/ghostty-vt-sys/",
                  "cmux-tui/crates/ghostty-vt/",
                  # files those crates include_str! and paths the kit's Swift names as literals (same date)
                  "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Resources/BackdropArt/van-gogh-starry-night.avif",
                  "cmux-tui/crates/acpmux/src/share_approval_vectors.json", "design/icons/source/agent-composer.json",
                  "schemas/notice-timing/notice-timing.json", "schemas/settings/source/browser.json",
                  "schemas/terminal-sizing/fixtures.json")
    },
}
SWIFT_PATH_PACKAGE = re.compile(r'\.package\s*\(\s*(?:name:\s*"[^"]*"\s*,\s*)?path:\s*"([^"]+)"')
SWIFT_URL_PACKAGE = re.compile(r'\.package\s*\(\s*(?:name:\s*"[^"]*"\s*,\s*)?(?:url|id):\s*"')
SWIFT_PACKAGE_TOKEN = re.compile(r"\.package\b")


def swift_without_comments(text: str) -> str | None:
    """TEXT with its Swift comments (`//` to the line end, `/* */` nested as Swift nests them) blanked, plain string
    literals kept whole (a url's `//` is not a comment); None when it has a raw (`#"`), multiline or interpolated
    (`\\(`) literal, which this reader does not parse: an interpolation's own quotes would end the literal early."""
    out, i, n = [], 0, len(text)
    while i < n:
        if text.startswith('"""', i) or text.startswith('#"', i):
            return None
        if text[i] == '"':
            j = i + 1
            while j < n and text[j] not in '"\n':
                if text.startswith("\\(", j):
                    return None
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            i = j + 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            out.append(" ")
        elif text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            out.append(" ")
            i = j
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


CARGO_DEPENDENCY_TABLES = ("dependencies", "dev-dependencies", "build-dependencies")
CARGO_MANIFESTS = 200  # a bound on the manifests one resolution reads


def cargo_crates(repo: str, sha: str, lock: str, github) -> dict[str, str]:
    """{directory: its crate's name} of every path crate the Cargo workspace beside LOCK builds at SHA: its members,
    then each path dependency (a `path`, or `workspace = true` resolved in the crate's own workspace root, the nearest
    ancestor manifest with a [workspace]), read from the manifests at SHA, never from a declaration. Raises Refused
    when a manifest cannot be read or parsed, a member is a glob, or a path crate in LOCK resolves to no directory."""
    import posixpath
    import tomllib
    manifests: dict[str, dict | None] = {}

    def manifest(where: str, required: bool) -> dict | None:
        if where not in manifests:
            if len(manifests) >= CARGO_MANIFESTS:
                raise Refused(f"resolving {lock}'s crates read more than {CARGO_MANIFESTS} manifests")
            path = f"{where}/Cargo.toml" if where else "Cargo.toml"
            try:
                text = source_text(repo, sha, path, github)
            except Refused as why:
                if required:
                    raise Refused(f"{path} could not be read at {sha[:12]}: {why}") from None
                text = None
            try:
                manifests[where] = None if text is None else tomllib.loads(text)
            except tomllib.TOMLDecodeError as why:
                raise Refused(f"{path} could not be parsed at {sha[:12]}: {why}") from None
        return manifests[where]

    def workspace_of(where: str) -> tuple[str, dict]:
        at = where
        while True:
            found = manifest(at, at == where)
            if found is not None and isinstance(found.get("workspace"), dict):
                return at, found["workspace"]
            if not at:
                return where, {}
            at = posixpath.dirname(at)

    root = posixpath.dirname(lock)
    top = (manifest(root, True) or {}).get("workspace")
    if not isinstance(top, dict):
        raise Refused(f"{root}/Cargo.toml has no [workspace]")
    members = top.get("members") or []
    if any(not isinstance(member, str) or any(c in member for c in "*?[") for member in members):
        raise Refused(f"{root}/Cargo.toml names its members by a glob")
    queue = [posixpath.normpath(posixpath.join(root, member)) for member in members] + [root]
    crates: dict[str, str] = {}  # by directory: two path crates may share a name (an aliased dependency)
    seen: set[str] = set()
    while queue:
        where = queue.pop()
        if where in seen:
            continue
        seen.add(where)
        if where.startswith("..") or where.startswith("/"):
            raise Refused(f"a path crate of {lock} is outside the repository ({where})")
        found = manifest(where, True) or {}
        package = found.get("package")
        if isinstance(package, dict) and isinstance(package.get("name"), str):
            crates[where] = package["name"]
        home, workspace = workspace_of(where)
        shared = workspace.get("dependencies") if isinstance(workspace.get("dependencies"), dict) else {}
        tables = [found.get(name) for name in CARGO_DEPENDENCY_TABLES]
        targets = found.get("target") if isinstance(found.get("target"), dict) else {}
        tables += [target.get(name) for target in targets.values() if isinstance(target, dict)
                   for name in CARGO_DEPENDENCY_TABLES]
        tables += [patch for patch in (found.get("patch") or {}).values() if isinstance(patch, dict)]
        tables += [shared] if where == home else []
        for table in tables:
            for name, spec in (table or {}).items() if isinstance(table, dict) else ():
                if not isinstance(spec, dict):
                    continue
                if isinstance(spec.get("path"), str):
                    base = home if table is shared else where
                    queue.append(posixpath.normpath(posixpath.join(base, spec["path"])))
                elif spec.get("workspace") and isinstance(shared.get(name), dict) \
                        and isinstance(shared[name].get("path"), str):
                    queue.append(posixpath.normpath(posixpath.join(home, shared[name]["path"])))
    try:
        locked = tomllib.loads(source_text(repo, sha, lock, github)).get("package", [])
    except (Refused, tomllib.TOMLDecodeError) as why:
        raise Refused(f"{lock} could not be read at {sha[:12]}: {why}") from None
    if missing := sorted({str(crate.get("name")) for crate in locked if isinstance(crate, dict)
                          and "source" not in crate} - set(crates.values())):
        raise Refused(f"{lock} has path crates its manifests do not reach: {', '.join(missing)}")
    return crates


def package_reads(repo: str, sha: str, package: dict, github) -> tuple[str, ...]:
    """PACKAGE's declared reads, once its Swift path packages and Cargo.lock path crates at SHA are shown to lie in
    them; raises Refused naming the first that does not."""
    import posixpath
    reads = package["reads"]
    seen: set[str] = set()
    queue = list(package["swift"])
    while queue:
        where = queue.pop()
        if where in seen:
            continue
        seen.add(where)
        if not any(touches(where + "/Package.swift", read) for read in reads + GUARD_READS_DEFAULT):
            raise Refused(f"its Swift package {where} is outside its declared reads (PACKAGE_JOBS)")
        try:
            manifest = source_text(repo, sha, f"{where}/Package.swift", github)
        except Refused as why:
            raise Refused(f"{where}/Package.swift could not be read at {sha[:12]}: {why}") from None
        # Read with its comments blanked. Every `.package` token is then a path dependency read below or a url (or
        # registry id) one: any other spelling (a variable path, a raw or multiline literal) could reach a package
        # this rule cannot see, so it refuses.
        code = swift_without_comments(manifest)
        if code is None:
            raise Refused(f"{where}/Package.swift has a raw, multiline or interpolated string literal, which this rule "
                          "does not read")
        known = {found.start() for pattern in (SWIFT_PATH_PACKAGE, SWIFT_URL_PACKAGE) for found in pattern.finditer(code)}
        if unread := [found.start() for found in SWIFT_PACKAGE_TOKEN.finditer(code) if found.start() not in known]:
            line = code.count("\n", 0, unread[0]) + 1
            raise Refused(f"{where}/Package.swift:{line} declares a package dependency in a form this rule does not "
                          "read; it could reach a package outside the declared reads")
        for found in SWIFT_PATH_PACKAGE.finditer(code):
            path = posixpath.normpath(posixpath.join(where, found.group(1)))
            if path.startswith("..") or path.startswith("/"):
                raise Refused(f"{where}/Package.swift reaches {found.group(1)}, outside the repository")
            queue.append(path)
    crates = cargo_crates(repo, sha, package["cargo_lock"], github)
    for where, crate in sorted(crates.items()):
        if not any(touches(where + "/Cargo.toml", read) for read in reads + GUARD_READS_DEFAULT):
            raise Refused(f"its Rust crate {crate} at {where} is outside its declared reads (PACKAGE_JOBS)")
    return reads


def package_tests(package: dict, view: "FailedView | Unplaced") -> list[str]:
    """The failing tests of a PACKAGE_JOBS job (VIEW: its failed_view), whose every failed step is one of its test
    steps and names a failing test of its own (one step's test failure never covers another's compile error); raises
    Refused."""
    found = signature(view)
    if found is UNPLACED:
        raise Refused(UNPLACED_WHY)
    steps, _, _ = found
    if other := sorted(steps - set(package["steps"])):
        raise Refused(f"its failed step {other[0]!r} is not one of the job's test steps")
    if not steps:
        raise Refused("no failing test in its test steps")
    tests: set[str] = set()
    for step, lines in section_lines(view):
        found = test_reds.read("\n".join(lines)).failed
        if not found:
            said = step.get("name")  # step-name: display
            raise Refused(f"its failed step {said!r} names no failing test of its own")
        tests |= found
    return sorted(tests)


def guard_job(name: str) -> bool:
    return name in GUARD_JOBS or any(name == end or name.endswith(" / " + end) for end in GUARD_JOB_SUFFIXES)


def guard_test_file(name: str, output: list[str]) -> str | None:
    """The tests/*.py file failing test NAME is in, from its pytest id or its own unittest traceback frame in OUTPUT
    (the failed step's printed lines); None when it is no such test or the log does not name one file for it."""
    if "::" in name:
        path = name.split("::", 1)[0]
        return path if GUARD_TEST_FILE.fullmatch(path) else None
    method = name.split(" ", 1)[0]
    frames = {m.group(1) for text in output for m in [TRACEBACK_FRAME.match(text)] if m and m.group(2) == method}
    return frames.pop() if len(frames) == 1 else None


def cited_red(view: FailedView, unnamed: "list[tuple[str, list[str]]]") -> str:
    """What a refusal quotes as the red of VIEW's job, given UNNAMED, the (status, error lines) of each part that
    names no failing test: the job's own `red check: NAME` lines (its rollup, ROLLUP_RED) when it has any; else the
    first error line of a FAILED part (a step the jobs API says failed) that is not the runner's exit line, then its
    exit line; else the failed steps by name. Never an ERRORED part's line: a continue-on-error or warn-only step
    that printed `##[error]` is not why the job is red (cmux#40455 at a199e5e0)."""
    rollup = [line.removeprefix("##[error]") for line in test_reds.lines_of(view_text(view)) if ROLLUP_RED.match(line)]
    if rollup:
        return "the job's " + "; ".join(dict.fromkeys(rollup))
    failed = [error for status, errors in unnamed if status == FAILED for error in errors]
    said = ([error for error in failed if not test_reds.PROCESS_EXIT.match(error)] or failed)[:1]
    if said:
        return said[0]
    steps = sorted(str(step.get("name") or "") for step in view.job.get("steps") or []  # step-name: display
                   if step_failed(step))
    return "failed steps: " + ("; ".join(steps) or "none named; only continue-on-error steps printed errors")


def guard_tests(view: "FailedView | Unplaced", reads: dict | None = None) -> dict[str, str]:
    """{failing test: its tests/*.py file} for a job (VIEW: its failed_view) whose every failed step is a guard
    test's or a check rule's (CHECK_RULE_JOBS: keyed by its finding, its file the check's script); raises Refused
    naming the first step or test that is not. READS gets {failure: the paths it reads} for each check rule finding
    and each test that wraps a check rule, which read those paths and not GUARD_READS."""
    reads = {} if reads is None else reads
    if view is UNPLACED:
        raise Refused(UNPLACED_WHY)
    view_text(view)
    found: dict[str, str] = {}
    tested_steps = rolled_up = 0
    # Each part of each section, with whether the jobs API says its step failed: a part split off at a script echo
    # (a composite's inner step) is its section's step's.
    parts = []
    for _, status, section in view.sections:
        lines = test_reds.log_lines("\n".join(section))
        skip = test_reds.echoed(lines)
        starts = [n for n in sorted(skip) if test_reds.ECHO_START.match(lines[n])]
        for start, end in zip([0] + starts, starts + [len(lines)]):
            parts.append((status, [lines[n] for n in range(start, end) if n not in skip],
                          [lines[n] for n in range(start, end) if n in skip]))
    # A part with an error line and no failing test refuses, but only after every part is read, so the refusal cites
    # the job's red, never a warn-only or continue-on-error step's `##[error]` line (2026-11-11, cmux#40455 at
    # a199e5e0: the first error of the checks job, './scripts/lint-ios-package-conventions.sh' from the warn-only
    # Package conventions lint, was cited, where the job was red for 'red check: Check the app FFI pin'; cited_red).
    unnamed: list[tuple[str, list[str]]] = []
    for status, output, script in parts:
        errors = [text for text in output if test_reds.STEP_ERROR.match(text)]
        if not errors:
            continue
        rollup = [text for text in errors if ROLLUP_RED.match(text)]
        if rollup and all(ROLLUP_RED.match(text) or test_reds.PROCESS_EXIT.match(text) for text in errors):
            rolled_up += len(rollup)
            continue
        names = test_reds.failed_names(output)
        if not names:
            unnamed.append((status, errors))
            continue
        if rules := {name for name in names if name.split(" ", 1)[0] in CHECK_RULE_JOBS}:
            if rules != names:
                raise Refused(f"a failed step names a check rule's finding and tests together: {sorted(names)[0]}")
            for key, (rule, path) in check_rule_step(output).items():
                spec = CHECK_RULE_JOBS[rule]
                if not any(spec["script"] in text for text in script):
                    raise Refused(f"{key}: its failed step's script does not run {spec['script']}")
                found[key] = spec["script"]
                reads[key] = check_rule_reads(rule, [path])
            tested_steps += 1
            continue
        if not any(TEST_RUN_SUMMARY.match(text) for text in output):
            raise Refused(f"the failed step naming {sorted(names)[0]} printed no test-run summary")
        for name in sorted(names):
            path = guard_test_file(name, output)
            if path is None:
                raise Refused(f"{name} is not a tests/*.py guard test whose file its log names")
            if not any(path in text for text in script):
                raise Refused(f"{name}: its failed step's script does not run {path}")
            found[name] = path
            if (wrapped := wrapped_rule_reads(path, name, output)) is not None:
                reads[name] = wrapped
        tested_steps += 1
    if unnamed:
        raise Refused(f"a failed step names no failing test ({cited_red(view, unnamed)[:300]})")
    if not found:
        raise Refused("no failing guard test")
    if rolled_up > tested_steps:
        raise Refused(f"its rollup names {rolled_up} red checks and only {tested_steps} failed with a guard test")
    return found


def touches(path: str, read: str) -> bool:
    if read == TOP_LEVEL:
        return "/" not in path
    return path.startswith(read) if read.endswith("/") else path == read or path.startswith(read + "/")


# The pull request a fixed-on-base red may be excused for (2026-11-08, cmuxterm-hq#7948): next-autoland lands a head
# with a base red since fixed, with no base merge, only when (1) an independent SHIP names that exact head, (2) it is
# not risk:high, (3) GitHub does not call it conflicting, (4) the job was red at the PR's merge-base and (5) passes on
# the newest base after it, and (6) none of the PR's files feeds the check. (5) and (6) are the rule above; this adds
# (1)-(4), so a lane's own land and autoland's agree. Any one missing keeps the red: the head takes a base merge and a
# run on the combined tree. The receipt grammar is risk_tier.py's (its one copy). A merged
# pull request (merge_audit) has no conflict to read.
SCRIPT_DIR = Path(__file__).resolve().parent
FIXED_ON_BASE_RISK = "risk:high"


def receipt_grammar():
    if str(SCRIPT_DIR) not in sys.path:
        sys.path.insert(0, str(SCRIPT_DIR))
    import risk_tier
    return risk_tier


def actions_check_runs(runs, name: str) -> list[dict]:
    """The GitHub Actions check runs called NAME in a check-runs answer: a check of the same name from another app
    (a status bot, a third-party CI) is not the job's verdict, so its red excuses nothing."""
    return [run for run in (runs or {}).get("check_runs") or []
            if isinstance(run, dict) and run.get("name") == name
            and (run.get("app") or {}).get("slug") == "github-actions"]


def fixed_on_base_pull(repo: str, base: str, sha: str, name: str, merge_base: str, github) -> str:
    """The pull request whose head is SHA, when (1)-(4) above hold for the red job NAME; raises Refused otherwise."""
    pulls = [p for p in github.json(f"repos/{repo}/commits/{sha}/pulls?per_page=100") or []
             if isinstance(p, dict) and (p.get("head") or {}).get("sha") == sha
             and (p.get("base") or {}).get("ref") == base]
    if len(pulls) != 1:
        raise Refused(f"no single pull request into {base} has {sha[:12]} as its head ({len(pulls)} found)")
    number = pulls[0].get("number")
    pull = github.json(f"repos/{repo}/pulls/{number}")
    labels = {str((label or {}).get("name") or "").lower() for label in pull.get("labels") or []}
    if FIXED_ON_BASE_RISK in labels:
        raise Refused(f"#{number} is {FIXED_ON_BASE_RISK}: it keeps its base merge and a run on the combined tree")
    if pull.get("state") == "open" and (pull.get("mergeable") is False
                                         or str(pull.get("mergeable_state") or "").lower() == "dirty"):
        raise Refused(f"GitHub calls #{number} conflicting")
    # A paginated read is its list of pages ([[comment, ...], ...]); signed_off reads the items.
    comments = [item for page in github.json(f"repos/{repo}/issues/{number}/comments", paginate=True) or []
                for item in _evidence.gh_pages.page_items(page)]
    reviews = [item for page in github.json(f"repos/{repo}/pulls/{number}/reviews", paginate=True) or []
               for item in _evidence.gh_pages.page_items(page)]
    author = (pull.get("user") or {}).get("login") or ""
    if not receipt_grammar().signed_off(comments, reviews, sha, author, pull):
        raise Refused(f"#{number} has no independent SHIP at its exact head {sha[:12]}")
    runs = github.json(f"repos/{repo}/commits/{merge_base}/check-runs?check_name={urllib.parse.quote(name, safe='')}&filter=latest&per_page=100")
    seen = actions_check_runs(runs, name)
    if not any(run.get("status") == "completed" and run.get("conclusion") in ("failure", "timed_out") for run in seen):
        raise Refused(f"'{name}' has no red verdict at the merge-base {merge_base[:12]} "
                      f"({', '.join(sorted({str(r.get('conclusion') or r.get('status')) for r in seen})) or 'none'}): "
                      "the base red that would excuse it is not shown there")
    return f"#{number}, SHIP at {sha[:12]}, red at the merge-base {merge_base[:12]}"


def fixed_on_base(repo: str, base: str, sha: str, name: str, head: "FailedView | Unplaced", base_run: dict,
                  github, evidence: "Evidence", verdict_repo: str | None = None) -> str:
    """The audit line for a red job whose every failing test is fixed on the base (the rule above); raises Refused
    with the reason it is not. BASE_RUN is the newest base run with a verdict for the job, and that verdict passed."""
    package = PACKAGE_JOBS.get(name)
    if not guard_job(name) and package is None:
        raise Refused(f"'{name}' is not a declared guard job (GUARD_JOBS) or package job (PACKAGE_JOBS); its tests "
                      "may read product code")
    rule_reads: dict[str, tuple[str, ...]] = {}
    tests = guard_tests(head, rule_reads) if package is None else dict.fromkeys(package_tests(package, head))
    tested = tested_sha(base_run)
    if not re.fullmatch(r"[0-9a-f]{40}", tested):
        raise Refused(f"{base} run {base_run['id']} names no commit it tested")
    diff = github.json(f"repos/{repo}/compare/{base}...{sha}")
    merge_base = evidence.merge_base(sha, diff)
    files = diff.get("files")
    if not re.fullmatch(r"[0-9a-f]{40}", merge_base) or not isinstance(files, list):
        raise Refused(f"no merge-base and diff for {sha} against {base}")
    if len(files) >= COMPARE_FILES_CAP:
        raise Refused(f"the diff from its merge-base lists {len(files)} files, too many to show it stays out of "
                      "the tests' paths")
    after = ({"status": "identical"} if tested == merge_base
             else github.json(f"repos/{repo}/compare/{merge_base}...{tested}?per_page=1"))
    if after.get("status") != "ahead":
        raise Refused(f"the passing {base} run {base_run['id']} tested {tested[:12]}, which is not after the merge-base "
                      f"{merge_base[:12]} ({after.get('status')})")
    changed = sorted({path for found in files for path in (found.get("filename"), found.get("previous_filename"))
                      if isinstance(path, str) and path})
    if package is not None:
        tests = dict.fromkeys(tests, package_reads(repo, sha, package, github))
    elif undeclared := sorted({path for test, path in tests.items()
                               if path not in GUARD_READS and test not in rule_reads}):
        raise Refused(f"{', '.join(undeclared)} declares no read paths (GUARD_READS), so a pass on the base proves "
                      "nothing about this PR")
    reads: list[str] = []
    for test, path in sorted(tests.items()):
        test_reads = (path + GUARD_READS_DEFAULT if package is not None else rule_reads[test] if test in rule_reads
                      else (path,) + GUARD_READS_DEFAULT + GUARD_READS.get(path, ()))
        if hit := [changed_path for changed_path in changed if any(touches(changed_path, r) for r in test_reads)]:
            raise Refused(f"{test} reads paths the PR changes: {'; '.join(hit[:5])}")
        reads.extend(r for r in test_reads if r not in reads)
    pull = fixed_on_base_pull(repo, base, sha, name, merge_base, github)
    # The base run is the verdict repo's when the base is verified there (BASE_VERDICT_REPO); every other read in
    # this function is the PR's own repo.
    url = base_run.get("html_url") or f"https://github.com/{verdict_repo or repo}/actions/runs/{base_run['id']}"
    return (f"excused '{name}': fixed on base (passes at {tested[:12]} in {base} run {base_run['id']}, after the "
            f"merge-base {merge_base[:12]}; PR does not touch {', '.join(reads)}; {pull}) ({url}): "
            f"{'; '.join(sorted(tests))[:400]}")


# Fixed on base, per step (2026-11-11). cmux#40984 at a6698ad5 failed 'cmux-next checks (god files, concurrency, crash
# safety, l10n)' in its step "Motion and colour tokens" ("raw colour outside the tokens"); #40959 fixed that step on
# feat-cmux-next, but the job stayed red there for another step, so judge() compared the head with the base's newest
# red runs and refused it ("errors not on feat-cmux-next any of runs ..."). The reviewer's rule (dep-fleet-6):
# "Match a step by its job name and step name. If a name is missing or matches more than one step on either side,
# the answer is unknown, and unknown is never excused. A step counts as green on base only if its own conclusion is
# success in base's newest completed run of that job. Skipped, cancelled or missing are not green: when base's job
# dies early, its later steps are skipped, and that must not read as fixed. That base run must be at or after the
# merge base, not an older run. Only the failing step is judged. Any other red step in the head job keeps it not
# excused." A red is keyed by (workflow, job, step), never its check name alone: a job name red in two workflows at
# the head is unknown. Only judge(purpose=PER_STEP_PURPOSE) reads it: update_branch's base merge, which only reruns
# CI; a land (land-judge, no purpose or "land") never does (#41117's review F1). When the job-level reads above do
# not excuse a red, it is excused as fixed on base only when:
#   (a) every failing step of the head job is a step it names exactly once, on the head and on the base: a step whose
#       jobs-API conclusion is not success or skipped, or a continue-on-error check (the jobs API calls it a success)
#       that the job's failed rollup step (ROLLUP_STEPS) names in its `red check: STEP` annotations. A failed rollup
#       with no such annotation, or a job with as many error annotations as a step can keep (ANNOTATION_STEP_CAP),
#       is unknown;
#   (b) each of them is green in the base's newest verdict for the job (base_verdicts), a run that tested a commit at or
#       after the merge-base: its conclusion is success and, for a continue-on-error check, the base job's rollup step
#       ran (success, or failure naming its reds) and does not name it. A rollup that was skipped or cancelled shows
#       nothing, so no continue-on-error check is green under it;
#   (c) each of them was red in the base's verdict for the job at the merge-base (its own run first, else the newest
#       before it): the red is the base's, which the PR inherited, never the PR's own (a step the base passed there).
#       Or the step is absent from that job, which read its steps, every one named (hq#9137:
#       a guard step the base added after the merge-base runs on the PR's merge ref against code that predates it):
#       the PR never had the code it judges, and (b) already says the base passes it;
#   (d) its failures are that run's: each step's failing test ids and `file:line` compiler errors are among that
#       step's there, and for a continue-on-error check, the job's file error annotations among that job's. A new
#       failure in a step already red at the merge-base is the PR's own. A step absent at the merge-base has no lines
#       there to match: for it, (b) and absence are the whole rule, and only update-branch reads it, whose merge of the
#       base reruns the step on the code it was written for.
# The rollup's reds are read from the job's check-run annotations, one read per job, not its log: a log step_owners
# cannot place (cmux#40984's head job) still has them. A head job's check run with no red-check annotation at all has
# them read from its log's own rollup list (rollup_log_reds) instead: a job a re-run attempt carries over without
# running it again gets a new check run with none of its annotations (cmux#40552's job 130212680188, run attempt 2:
# its annotations stayed on attempt 1's check run 130107053043), and its log, that same run's, still prints them. The line keeps fixed_on_base's prefix, "excused 'JOB': fixed on
# base (", which land-judge's actions_verdict and the lane broker's update_branch guard read, once per red job, and
# names inside it the red's identity (`run RUN / JOB`: its head Actions run and job), its job id and workflow file,
# each step and both base runs.
ROLLUP_STEPS = frozenset({FFI_PIN_ROLLUP_STEP})  # a job's last step that fails for its continue-on-error checks
ROLLUP_ANNOTATION = re.compile(r"^red check: (.+)$")
# GitHub keeps at most 10 error annotations per step, and an annotation names no step: a job showing this many error
# annotations in all may have lost one of its rollup's markers, and is unknown (#41117's review F4: six errors before
# four markers hid the fifth). Every page of them is read (#41104's review F1: a first page of 100 can hide markers).
ANNOTATION_STEP_CAP = 10
EXIT_ANNOTATION = re.compile(r"^Process completed with exit code \d+\.?$")
# A compiler's error line: `path/File.swift:12:5: error: message` (the column optional). The path starts where a run
# of path characters does (the lookbehind), and ends in one name character before its `.ext`: the same matches as
# `[^\s:'"]*[\w.+-]+\.`, whose two overlapping repeats, tried from every character of the run, took more than 5 s on
# one 12,000-character line of `x.x` (PrLogPatternsScale).
COMPILE_ERROR = re.compile(r"(?<![^\s:'\"])([^\s:'\"]*[\w.+-]\.[A-Za-z]\w*):(\d+)(?::\d+)?: (?:fatal )?error: (.+)$")
# The per-step reading is for one caller only: update_branch's choice to merge the base in, which only makes CI run
# again. A land (land-judge's classifier_refusal, actions_verdict) never gets it (#41117's review F1).
PER_STEP_PURPOSE = "update-branch"
PURPOSES = ("land", PER_STEP_PURPOSE)
STEP_PRIOR_RUNS = 30  # base runs listed at or before the merge-base's commit time
STEP_PRIOR_JOB_READS = 4  # of them, the job lists read for a verdict for the job


def job_annotations(repo: str, job: dict, github, cache: dict) -> list[dict] | None:
    """Every annotation of JOB's check run, every page read once per job into CACHE; None when they cannot be read in
    full (a full page that is not continued), or when the job has ANNOTATION_STEP_CAP or more error annotations
    (GitHub keeps 10 a step, so one may have been cut)."""
    if ("all", job["id"]) not in cache:
        found = None
        pages = github.json(f"repos/{repo}/check-runs/{job['id']}/annotations?per_page=100", paginate=True)
        if isinstance(pages, list):
            paged = bool(pages) and all(isinstance(page, list) for page in pages)
            items = [item for page in pages for item in page] if paged else pages
            # One unpaged answer of a full page may go on past it (#41104's review F1): unknown, as a cut list is.
            if (paged or len(items) < 100) and all(isinstance(item, dict) for item in items):
                errors = [item for item in items if (item.get("annotation_level") or "failure") == "failure"]
                found = items if len(errors) < ANNOTATION_STEP_CAP else None
        cache[("all", job["id"])] = found
    return cache[("all", job["id"])]


def rolled_up_reds(repo: str, job: dict, github, cache: dict, logged: dict | None = None) -> set[str] | None:
    """The checks JOB's rollup step names red (its `red check: NAME` failure annotations); None when the annotations
    are unknown (job_annotations) or name none. When they were read in full and name none, LOGGED (read_head's
    rollup_log_reds of the head's log, by job id) answers for a job it holds: the same `##[error]red check: NAME`
    lines the annotations are made from, with the rollup's own count."""
    notes = job_annotations(repo, job, github, cache)
    if notes is None:
        return None
    reds = {match.group(1).strip() for note in notes if (note.get("annotation_level") or "failure") == "failure"
            and (match := ROLLUP_ANNOTATION.match(str(note.get("message") or "").strip()))}
    if not reds and logged is not None:
        return logged.get(job["id"])
    return reds or None


def repo_path(path: str) -> str:
    """PATH as an excuse compares it: in full, repository-relative when it is under the runner's checkout root
    (test_reds.volatile's <workspace>), never its file name alone: Other/A.swift is not Sources/A.swift (#41158's
    review F2). A path under another root stays as printed, so it matches only itself."""
    said = test_reds.volatile(path.strip())
    said = said.removeprefix("<workspace>/")
    while said.startswith("./"):
        said = said[2:]
    return said


def path_errors(notes: list[dict]) -> set[tuple[str, int, str]]:
    """(repository path, line, error with numbers masked) of each error annotation in NOTES that names a file: a check's
    or a compiler's own error, never a rollup marker or the runner's exit line."""
    return {(repo_path(str(note.get("path"))), int(note.get("start_line") or 0),
             normalise_error(str(note.get("message") or "").strip()))
            for note in notes if (note.get("annotation_level") or "failure") == "failure" and note.get("path")
            and not ROLLUP_ANNOTATION.match(str(note.get("message") or "").strip())
            and not EXIT_ANNOTATION.match(str(note.get("message") or "").strip())}


def step_evidence(view: "FailedView | Unplaced", step_name: str) -> tuple[set[str], set[str]] | None:
    """(failing test ids, `file:line: error` compiler errors) printed in the section of VIEW's step STEP_NAME; None when
    the view is not placed or has no section of it."""
    if view is UNPLACED:
        return None
    lines = [line for k, _, section in view.sections
             if str(view.steps[k].get("name") or "") == step_name  # step-name: classify
             for line in section]
    if not lines:
        return None
    texts = test_reds.lines_of("\n".join(lines))
    errors = {f"{repo_path(match[1])}:{match[2]}: {normalise_error(match[3])}"
              for text in texts if (match := COMPILE_ERROR.search(text))}
    tests = set(test_reds.failed_tests(texts))
    if rules := {test for test in tests if test.split(" ", 1)[0] in CHECK_RULE_JOBS}:
        # A check rule's finding is the step's identity only when every line of the step is that check's
        # (check_rule_step): one more line, unnamed, would go unmatched.
        try:
            check_rule_step(texts)
        except Refused:
            tests -= rules
    return tests, errors


# The rollup's own list in its log (cmux-next.yml's "Fail on any red check"): one `::error title=cmux-next check::red
# check: NAME` command per red check, which the runner prints as `##[error]red check: NAME` and GitHub turns into the
# annotations rolled_up_reds reads, then `### N cmux-next check(s) failed` and one `- NAME (outcome)` line for each.
ROLLUP_SUMMARY = re.compile(r"^### (\d+) cmux-next check\(s\) failed$")
ROLLUP_ITEM = re.compile(r"^- (.+) \((?:failure|cancelled|skipped|timed_out|not run)\)$")
ROLLUP_LOG_RED = re.compile(r"^##\[error\]red check: (.+)$")


def rollup_log_reds(log: str) -> set[str] | None:
    """The checks a rollup's log names red: its live `##[error]red check: NAME` lines (the runner's echo of the step's
    script is never one: test_reds.lines_of), when they are the lines right before its one `### N cmux-next check(s)
    failed` summary, N of them, each named once, and the N `- NAME (outcome)` lines under it name the same checks.
    None otherwise: no summary, two, a count or list that differs, or a red line anywhere else in the log. The lines
    are the ones GitHub makes the job's annotations from, so they say no more than the annotations do; the rollup's
    count says the list is whole."""
    lines = test_reds.lines_of(log)
    reds = [n for n, text in enumerate(lines) if ROLLUP_LOG_RED.match(text)]
    summaries = [n for n, text in enumerate(lines) if ROLLUP_SUMMARY.match(text)]
    if len(summaries) != 1 or not reds:
        return None
    at = summaries[0]
    count = int(ROLLUP_SUMMARY.match(lines[at]).group(1))
    names = [ROLLUP_LOG_RED.match(lines[n]).group(1).strip() for n in reds]
    if count != len(reds) or reds != list(range(at - count, at)) or len(set(names)) != count:
        return None
    items = [text for text in lines[at + 1:at + 2 + count] if text]
    listed = [match.group(1).strip() for text in items if (match := ROLLUP_ITEM.match(text))]
    return set(names) if len(listed) == count and set(listed) == set(names) else None


def one_step(job: dict, step_name: str, side: str) -> dict:
    """JOB's one step named STEP_NAME; Refused (unknown) when it names none or more than one."""
    found = [step for step in job.get("steps") or []
             if str(step.get("name") or "") == step_name]  # step-name: classify
    if len(found) != 1:
        raise Refused(f"step '{step_name}' is {'missing' if not found else f'named {len(found)} times'} in {side} "
                      f"job {job.get('id')}, so whether it passed is unknown")
    return found[0]


def head_failing_steps(repo: str, job: dict, github, cache: dict,
                       logged: dict | None = None) -> tuple[dict[str, bool], list[str]]:
    """({failing step of head JOB: whether only its rollup shows it (a continue-on-error check)}, the failed rollup
    steps naming them), (a) above; Refused when that is unknown. LOGGED: rolled_up_reds'."""
    steps = job.get("steps") or []
    if any(not str(step.get("name") or "") for step in steps):  # step-name: classify
        raise Refused(f"head job {job.get('id')} has a step with no name, so its steps cannot be matched")
    failing: dict[str, bool] = {}
    rollups: list[str] = []
    for step in steps:
        conclusion = step.get("conclusion")
        if conclusion in ("success", "skipped"):
            continue
        step_name = str(step.get("name"))  # step-name: classify
        if conclusion is None:
            raise Refused(f"step '{step_name}' has no conclusion in head job {job.get('id')}")
        if step_name not in ROLLUP_STEPS:
            failing[step_name] = False
            continue
        rolled = rolled_up_reds(repo, job, github, cache, logged)
        if rolled is None:
            raise Refused(f"rollup '{step_name}' of head job {job.get('id')} failed, and its annotations do not name "
                          f"its reds (none, or the job has {ANNOTATION_STEP_CAP} or more error annotations, as many as "
                          "GitHub keeps for a step, so one may be cut), nor does its log (rollup_log_reds)")
        rollups.append(step_name)
        for red in rolled:
            failing.setdefault(red, True)
    if not failing:
        raise Refused(f"head job {job.get('id')} names no failing step")
    for step_name in sorted({*failing, *rollups}):
        one_step(job, step_name, "head")
    return failing, rollups


def step_conclusion(repo: str, job: dict, step_name: str, quiet: bool, rollups: list[str], side: str, github,
                    cache: dict) -> str:
    """STEP_NAME's conclusion in JOB (a base job): its own; for a continue-on-error check (QUIET) "failure" when its
    job's failed rollup names it red, and the rollup's own conclusion when it did not finish with a verdict. Refused
    (unknown) for a missing or repeated name, or a failed rollup whose annotations do not name its reds."""
    conclusion = str(one_step(job, step_name, side).get("conclusion"))
    if not quiet or conclusion != "success":
        return conclusion
    for rollup_name in rollups:
        rollup = one_step(job, rollup_name, side)
        if rollup.get("conclusion") == "success":
            continue
        if rollup.get("conclusion") != "failure":
            return f"{rollup.get('conclusion')} (its rollup '{rollup_name}')"
        named = rolled_up_reds(repo, job, github, cache)
        if named is None:
            raise Refused(f"rollup '{rollup_name}' of {side} job {job.get('id')} failed, and its annotations do not "
                          f"name its reds (none, or {ANNOTATION_STEP_CAP} or more error annotations, so one may be cut)")
        if step_name in named:
            return "failure"
    return "success"


def merge_base_of(sha: str, evidence: "Evidence") -> tuple[str, str]:
    """(merge-base of SHA with the base, its commit time): EVIDENCE's (Evidence.merge_base, merge_base_time)."""
    return evidence.merge_base(sha), evidence.merge_base_time(sha)


def first_base_verdict(repo: str, runs: list[dict], name: str, github, base_jobs: dict, suites: SuiteChecks,
                       reads: list[int]) -> tuple[dict, dict] | None:
    """(run, job NAME) of the first of RUNS (newest first) with a verdict for NAME, reading a job list only for a run
    whose check suite can hold one (may_hold), at most STEP_PRIOR_JOB_READS in all (READS, shared)."""
    for index, run in enumerate(runs):
        if base_jobs.get(run["id"]) is None:
            if not may_hold(suites, runs, index, name, verdict=True):
                continue
            if reads[0] >= STEP_PRIOR_JOB_READS:
                return None
            reads[0] += 1
            base_jobs[run["id"]] = base_run_jobs(repo, run, github)
        found = next((found for found in base_jobs[run["id"]] if found.get("name") == name), None)
        if found is not None and found.get("conclusion") in VERDICTS and not refused_at_setup(found):
            return run, found
    return None


def prior_base_verdict(repo: str, workflow, name: str, merge_base: str, when: str, github,
                       base_jobs: dict, evidence: "Evidence", suites: SuiteChecks | None = None,
                       verdict_repo: str | None = None) -> tuple[dict, dict] | None:
    """(run, job NAME) of BASE's verdict for NAME on WORKFLOW at the merge-base: the newest completed run that tested
    the merge-base itself (whenever it was created: a push run starts after its commit, #41117's review F3), and only
    when it has none, the newest that tested a commit before it, of the STEP_PRIOR_RUNS runs created at or before the
    merge-base's commit time WHEN. A run whose check suite shows no verdict for NAME costs no job read (may_hold, as
    base_verdicts reads them): a base's runs mix pushes, the base tier and DEV daily dispatches, and only some carry a
    job (cmux#40984's 'cmux-next generated files'). At most STEP_PRIOR_JOB_READS job lists in all; None when none is
    found. Every run is EVIDENCE's (Evidence.queried). VERDICT_REPO: the repo whose
    runs are the base's verdict of record (Evidence.verdict_repo), REPO when None; the compare below stays REPO's, so
    a verdict at a commit the PR's repo does not have is never read as being at or before the merge-base."""
    vrepo = verdict_repo or repo
    suites = suites or SuiteChecks(github, vrepo)
    reads = [0]

    def listed(query: str) -> list[dict]:
        return sorted((run for run in evidence.queried(workflow, query, STEP_PRIOR_RUNS)
                       if run.get("status") == "completed" and run.get("conclusion") != "skipped"
                       and not never_carries(run, name)),
                      key=lambda run: run.get("created_at") or "", reverse=True)

    own = [run for run in listed(f"head_sha={merge_base}") if tested_sha(run) == merge_base]
    if (found := first_base_verdict(vrepo, own, name, github, base_jobs, suites, reads)) is not None:
        return found
    older = [run for run in listed(f"created=%3C%3D{urllib.parse.quote(when, safe='')}")
             if str(run.get("created_at") or "") <= when and tested_sha(run) != merge_base]
    found = first_base_verdict(vrepo, older, name, github, base_jobs, suites, reads)
    if found is None:
        return None
    tested = tested_sha(found[0])
    if not re.fullmatch(r"[0-9a-f]{40}", tested):
        return None
    status = github.json(f"repos/{repo}/compare/{tested}...{merge_base}?per_page=1").get("status")
    return found if status in ("ahead", "identical") else None


def fixed_on_base_by_step(repo: str, base: str, sha: str, name: str, job: dict, view: "FailedView | Unplaced",
                          workflow_info: dict, base_run: dict, base_job: dict, github, *,
                          base_jobs: dict, run_reads: dict, others: list[dict], evidence: "Evidence",
                          suites: SuiteChecks | None = None, base_workflow=None, base_name=None,
                          verdict_repo: str | None = None) -> str:
    """The audit line for red head JOB (VIEW: its failed_view; WORKFLOW_INFO: its run) when each of its failing steps
    is fixed on base by the rule above, BASE_RUN and BASE_JOB being the base's newest verdict for it, from
    BASE_WORKFLOW (the head's own workflow when None; a base caller's otherwise, whose runs then give the merge-base's
    verdict too, #41104's review F2, under BASE_NAME: a batch suite's check name). OTHERS: the head's red jobs; one of
    NAME in another workflow makes the job's identity unknown. Its failures must also be the merge-base verdict's:
    each failing step's test ids and `file:line` compiler errors (a continue-on-error check's: the job's file error annotations) among that run's, so a
    new failure in a step red at the merge-base is never excused (#41117's review F1). VERDICT_REPO: the repo whose
    runs are the base's verdict of record (Evidence.verdict_repo), REPO when None; the head's own reads stay REPO's.
    Raises Refused with why not."""
    vrepo = verdict_repo or repo
    workflow = workflow_info.get("workflow_id")
    base_workflow = workflow if base_workflow is None else base_workflow
    # The workflow by its file (a run's name may carry a tested sha: "cmux-next · <sha>"), else GitHub's id.
    where = f"workflow {workflow_info.get('path') or workflow}" + (
        f", base workflow {base_workflow}" if base_workflow != workflow else "")
    notes = run_reads.setdefault("rollup-annotations", {})
    failing, rollups = head_failing_steps(repo, job, github, notes, run_reads.get("rollup-log-reds"))
    for other in others:
        if other is job or other.get("name") != name or other.get("run_id") == job.get("run_id"):
            continue
        record = run_reads.get(("run-record", other.get("run_id")))
        if not isinstance(record, dict):
            record = rest_run(repo, other["run_id"], github, run_reads)
        if record.get("workflow_id") != workflow:
            raise Refused(f"'{name}' is red in two workflows at {sha[:12]} (runs {job.get('run_id')} and "
                          f"{other.get('run_id')}), so which job a step belongs to is unknown")
    not_green = []
    for step_name, quiet in sorted(failing.items()):
        said = step_conclusion(vrepo, base_job, step_name, quiet, rollups, "base", github, notes)
        if said != "success":
            not_green.append(f"'{step_name}' is {said}")
    if not_green:
        raise Refused(f"not green in {base} run {base_run['id']}: " + "; ".join(not_green)[:600])
    merge_base, when = merge_base_of(sha, evidence)
    tested = tested_sha(base_run)
    if not re.fullmatch(r"[0-9a-f]{40}", merge_base) or not re.fullmatch(r"[0-9a-f]{40}", tested):
        raise Refused(f"no merge-base of {sha[:12]} or no commit {base} run {base_run['id']} tested")
    if (stale := before_merge_base(repo, base, sha, base_run, github, evidence)) is not None:
        raise Refused(f"{base}'s newest verdict for it, run {base_run['id']}, {stale}, not at or after the merge-base")
    if not re.fullmatch(r"\d{4}-\d\d-\d\dT[\d:]+Z", when):
        raise Refused(f"the merge-base {merge_base[:12]} came back without its commit time")
    prior = prior_base_verdict(repo, base_workflow, name if base_name is None else base_name, merge_base, when,
                               github, base_jobs, evidence, suites, verdict_repo=vrepo)
    if prior is None:
        raise Refused(f"no {base} verdict for it at or before the merge-base {merge_base[:12]} shows the red was the "
                      f"base's (of the {STEP_PRIOR_RUNS} newest runs created before it, read the job lists of up to "
                      f"{STEP_PRIOR_JOB_READS} whose suites can hold one)")
    prior_run, prior_job = prior
    own, absent = [], []
    prior_steps = prior_job.get("steps") or []
    for step_name, quiet in sorted(failing.items()):
        # Absent at the merge-base (hq#9137): the step came to the base after it, so the PR's
        # code never ran it there, and it passes on the base's newest run (checked above). A merge of the base brings
        # the change that makes it pass. Only when the merge-base job read its steps, every one named, and none is
        # this one; a step that is there must be red, as before.
        if prior_steps and all(str(step.get("name") or "") for step in prior_steps) and not any(  # step-name: classify
                str(step.get("name")) == step_name for step in prior_steps):  # step-name: classify
            absent.append(step_name)
            continue
        said = step_conclusion(vrepo, prior_job, step_name, quiet, rollups, "merge-base", github, notes)
        if said != "failure":
            own.append(f"'{step_name}' is {said}")
    if own:
        raise Refused(f"the PR's own red: at or before the merge-base {merge_base[:12]}, {base} run "
                      f"{prior_run['id']} was not red in it: " + "; ".join(own)[:600])
    new = []
    prior_view: list = []
    for step_name, quiet in sorted(failing.items()):
        if step_name in absent:
            continue  # no merge-base lines to match: absent there, green on the base's newest run is the whole rule
        if quiet:
            # One is the head's job and the other the merge-base verdict's: each is read from its own repo.
            head_notes = job_annotations(repo, job, github, notes)
            prior_notes = job_annotations(vrepo, prior_job, github, notes)
            if head_notes is None or prior_notes is None:
                new.append(f"'{step_name}': the error annotations cannot all be read")
                continue
            mine, theirs = path_errors(head_notes), path_errors(prior_notes)
            if not mine:
                new.append(f"'{step_name}': no file error annotation to match")
            elif missing := sorted(mine - theirs):
                new.append(f"'{step_name}': " + "; ".join(f"{file}:{line}: {said}" for file, line, said in missing))
            continue
        mine = step_evidence(view, step_name)
        if mine is None or not (mine[0] or mine[1]):
            new.append(f"'{step_name}': no failing test id or file:line error of its own to match")
            continue
        if not prior_view:
            prior_view.append(base_evidence(vrepo, base, name, prior_run, prior_job, github, run_reads)[1])
        theirs = step_evidence(prior_view[0], step_name) or (set(), set())
        if missing := sorted((mine[0] - theirs[0]) | (mine[1] - theirs[1])):
            new.append(f"'{step_name}': " + "; ".join(missing))
    if new:
        raise Refused(f"failures not in {base} run {prior_run['id']} at the merge-base, so not the base's: "
                      + " | ".join(new)[:600])
    url = base_run.get("html_url") or f"https://github.com/{vrepo}/actions/runs/{base_run['id']}"
    steps = ", ".join(f"'{step_name}'" for step_name in sorted(failing))
    red = ", ".join(f"'{step_name}'" for step_name in sorted(failing) if step_name not in absent)
    gone = ", ".join(f"'{step_name}'" for step_name in absent)
    at = f"{base} run {prior_run['id']} at {tested_sha(prior_run)[:12]}, at or before it"
    # One line per red job, keyed inside the parenthesis by its head run (the update_branch guard's "run ID / JOB").
    return (f"excused '{name}': fixed on base (run {job.get('run_id')} / {name}, job {job.get('id')}, {where}; step "
            f"{steps}: passes in {base} run {base_run['id']} at {tested[:12]}, at or after the merge-base "
            f"{merge_base[:12]}" + (f"; red in {at}" if not gone else f"; {red} red in {at}" if red else "")
            + (f"; {gone} absent from {at} (added to {base} since)" if gone else "") + f") ({url})")

# Green on base since the red, for a base merge alone (2026-11-11, dep-fleet-6): the update_branch guard refused the
# one action that would clear cmux#41205's and #41220's reds, because judge() could not tie them to a declared guard
# job ("not a declared guard job (GUARD_JOBS)"), while the base had fixed them (#41227) and the base merge is what
# shows it. The reviewer's rule: "when the same check name is green at the base tip, and the PR's failing run is older
# than that green run, count it as fixed on base for the base merge." It reads no job list, so a job no declaration
# has caught up with still gets its base merge. Only judge(purpose=PER_STEP_PURPOSE) reads it: a base merge reruns
# CI, so a red of the PR's own comes back on the merged head. A land (land-judge, no purpose or "land") never gets it:
# a green base says nothing about whether this head's red is its own. The base verdict is the newest one for the job
# in the head run's workflow (base_verdicts), a success (not skipped or neutral), at or after the merge-base, from a
# run created after the head's red run.
def green_since(repo: str, base: str, sha: str, name: str, job: dict, workflow_info: dict, base_run: dict,
                base_job: dict, github, evidence: "Evidence", verdict_repo: str | None = None) -> str:
    """The audit line for red head JOB when the base's newest verdict for it passed in a run made after the head's
    (the rule above); raises Refused with why not."""
    if base_job.get("conclusion") != "success":
        raise Refused(f"{base}'s newest verdict for it, run {base_run['id']}, is {base_job.get('conclusion')}, "
                      "not a success")
    if (stale := before_merge_base(repo, base, sha, base_run, github, evidence)) is not None:
        raise Refused(f"{base} run {base_run['id']} {stale}, not at or after the merge-base")
    if not (re.fullmatch(r"[0-9a-f]{40}", evidence.merge_base(sha))
            and re.fullmatch(r"[0-9a-f]{40}", tested_sha(base_run))):
        raise Refused(f"no merge-base of {sha[:12]} or no commit {base} run {base_run['id']} tested")
    head_made, base_made = created(workflow_info), created(base_run)
    if head_made is None or base_made is None:
        raise Refused(f"run {job.get('run_id')} or {base} run {base_run['id']} came back without its creation time")
    if base_made <= head_made:
        raise Refused(f"{base} run {base_run['id']} ({base_run.get('created_at')}) is not newer than the red run "
                      f"{job.get('run_id')} ({workflow_info.get('created_at')})")
    tested = tested_sha(base_run)
    # The base run is the verdict repo's when the base is verified there (BASE_VERDICT_REPO); every other read in
    # this function is the PR's own repo.
    url = base_run.get("html_url") or f"https://github.com/{verdict_repo or repo}/actions/runs/{base_run['id']}"
    where = f"workflow {workflow_info.get('path') or workflow_info.get('workflow_id')}"
    # The fixed_on_base prefix the update_branch guard reads, keyed by the head run ("run ID / JOB").
    return (f"excused '{name}': fixed on base (run {job.get('run_id')} / {name}, job {job.get('id')}, {where}; green "
            f"in {base} run {base_run['id']} at {tested[:12]}, created {base_run.get('created_at')}, after this red "
            f"run's {workflow_info.get('created_at')}; for a base merge alone, which reruns it) ({url})")


# cmux-next-guards.yml's "cmux-next CI guard group" runs every routed guard step of ci-guards.yml (the workflow guard
# profile) on the change and again on its base, and fails only on a step red on the change and not on that base
# (scripts/ci/guards_new_reds.py). Its log names each red step on one plain line, `guard red step (KIND): STEP`: `new`
# (red on this change), `base` (red on the base too), `flaky`, `unknown` (the replay had no result), or `tip` (a push judged at its tip). A pull request's
# red in it is judged per step, the way the job itself reports "N red on the base too": every step the head calls
# `new` must be red at the newest base run of the job, whatever that run's conclusion (a push judged against the
# previous tip lists a red that persists as `base` and stays green). A whole verdict is one with the closing summary
# line; anything else is refused. Before this the job was not a declared guard job (GUARD_JOBS), so a red in it was
# never excused, and the base's own reds in it stayed green on every push (18 steps, until #31366).
GUARD_GROUP_JOB = "cmux-next CI guard group"
GUARD_GROUP_STEP = "Run the ci guard group and the routed groups"
GUARD_RED_STEP = re.compile(r"^guard red step \((new|base|flaky|unknown|tip)\): (.+)$")
GUARD_SUMMARY = re.compile(r"^\d+ guard steps red (?:on this change|at the tip)\b")
# run_ci_guards.py's closing line. The red step lines are read only after the last one: a failing step's own output
# (printed above it) may quote them.
GUARD_RUN_DONE = re.compile(r"^cmux guards: \d+ steps passed, \d+ failed\b")


def guard_red_steps(log: str) -> dict[str, set[str]] | None:
    """{kind: red steps} from the text of a guard group job's GUARD_GROUP_STEP (guard_group_report), or None when it
    printed no closing summary (cut short)."""
    lines = test_reds.log_lines(log)
    skip = test_reds.echoed(lines)
    found: dict[str, set[str]] = {"new": set(), "base": set(), "flaky": set(), "unknown": set(), "tip": set()}
    done = whole = False
    for n, text in enumerate(lines):
        if n in skip:
            continue
        if GUARD_RUN_DONE.match(text):
            found, done, whole = {kind: set() for kind in found}, True, False
        elif not done:
            continue  # a cut-short run's step output may quote verdict lines; none count before the run finished
        elif match := GUARD_RED_STEP.match(text):
            found[match.group(1)].add(match.group(2).strip())
        elif GUARD_SUMMARY.match(text):
            whole = True
    return found if whole else None


def guard_group_truncated(truncated: list[str], head: "FailedView | Unplaced") -> list[str]:
    """TRUNCATED (test_reds.read's cut-short reasons for a guard group job's log) less each that is only the job's
    `##[error]STEP` annotation of a step its own closing verdict (guard_red_steps of HEAD, its failed_view) names red:
    test_reds.TRUNCATED reads any `##[error]` line with "timeout" in it as a cut-short run, and "Validate short timeout
    ratchet" is a guard step's name (feat-cmux-next job 133860622386, 2026-11-17: every PR with the base's red guard
    group was refused "a failure no parser names is never a base red" before guard_group compared its steps;
    cmux#45075, cmux#44814). Any other reason stays, and an unplaced head or one with no closing verdict keeps every
    one: guard_group refuses those itself."""
    steps = None if head is UNPLACED else guard_red_steps(view_text(head))
    if steps is None:
        return truncated
    named = {step[:200] for kind in steps.values() for step in kind}
    return [why for why in truncated if why not in named]


# A guard step finding that names a file: "STEP :: path:rule: ...", "STEP :: path: rule" or "STEP :: path::test".
GUARD_FINDING_FILE = re.compile(r" :: ([^\s:]+\.[A-Za-z0-9]+)(?=:|$)")


def guard_finding_files(steps: set[str]) -> dict[str, str]:
    """{path: the first finding naming it} over STEPS (guard_red_steps' lines)."""
    found: dict[str, str] = {}
    for step in sorted(steps):
        if match := GUARD_FINDING_FILE.search(step):
            found.setdefault(match.group(1), step)
    return found


def guard_group_report(repo: str, base_job: dict, github) -> dict[str, set[str]] | None:
    """guard_red_steps of a base guard group job's whole log. The one base read that is not a failed_view, on
    purpose: the job reports each red step of its base on its own, `guard red step (base): STEP`, whatever its
    conclusion (a push judged against the previous tip lists a red that persists as `base` and stays green, so its one
    step PASSED), and those lines count only after run_ci_guards.py's closing line, which a passing step that merely
    quotes them never prints after. The head's side is its failed_view (guard_group)."""
    return guard_red_steps(github.log(repo, base_job))


def guard_group(repo: str, base: str, name: str, job: dict, head: "FailedView | Unplaced", base_run: dict,
                base_job: dict, github, sha: str = "", seen: dict | None = None) -> str:
    """The audit line for a red guard group job whose every red step is red at the newest base verdict for the job
    (the rule above); raises Refused naming the first step that is not."""
    failed = {step["name"] for step in job.get("steps") or []  # step-name: classify
              if step.get("conclusion") not in (None, "success", "skipped")}
    if failed != {GUARD_GROUP_STEP}:
        raise Refused(f"'{name}': failed steps {sorted(failed)}, not only '{GUARD_GROUP_STEP}'; nothing to compare "
                      "step by step")
    if head is UNPLACED:
        raise Refused(f"'{name}': {UNPLACED_WHY}; its guard steps are not compared")
    head = guard_red_steps(view_text(head))
    if head is None:
        raise Refused(f"'{name}': its guard comparison printed no summary (a cut-short run is never a base red)")
    # An unknown replay result is resolved against the base branch's own run below; it is never silently charged
    # to the pull request merely because the constrained replay was cut short.
    charged = head["new"] | head["unknown"] | head["tip"]
    if not charged:
        raise Refused(f"'{name}': red, but names no red step of its own; nothing to compare with the base")
    found = guard_group_report(repo, base_job, github)
    url = base_run.get("html_url") or f"https://github.com/{repo}/actions/runs/{base_run['id']}"
    if found is None:
        raise Refused(f"'{name}': {base} run {base_run['id']} names no red steps with a closing summary ({url})")
    # The base run itself must have a concrete red verdict; an unknown line from another constrained replay is not
    # evidence that the base branch fails this step.
    red_on_base = found["new"] | found["base"] | found["flaky"] | found["tip"]
    if missing := sorted(charged - red_on_base):
        raise Refused(f"'{name}': guard steps red on this change and not on {base} run {base_run['id']} ({url}): "
                      f"{'; '.join(missing)[:600]}")
    # A finding in a file the pull request changes is its own, even when the base prints the same line: the
    # determinism gate's "path: rule" carries no count, so a second sleep-then-assert there reads the same.
    if sha and (files := guard_finding_files(charged)):
        number, paths = pr_paths_once(repo, base, sha, github, seen)
        if mine := sorted(set(files) & set(paths)):
            raise Refused(f"'{name}': #{number} changes {', '.join(mine)[:300]}, which its red guard steps name "
                          f"({files[mine[0]][:300]}); a finding in a changed file is never a base red")
    at = f" at {tested_sha(base_run)[:10]}" if tested_sha(base_run) else ""
    return (f"excused '{name}': every red guard step is red on {base} run {base_run['id']}{at} "
            f"(the newest {base} verdict for it, {base_job.get('conclusion')}) ({url}): {'; '.join(sorted(charged))[:400]}")


# The Cloud journey (cloud-journey-pr.yml's "journey" job: scripts/cmux-next/cloud-journey.ts through
# cloud-journey-ci.sh, on staging, with the pull request's own cmux-tui). Each journey step prints one
# `PASS|FAIL|SKIP <step> <ms> ms :: <detail>` line, each run closes with `PASS|FAIL <backend>: N passed, M failed, K
# skipped, T s`, and a failed run is run once more after a `##[warning]... failed once; running it again` line: the
# second run is the one judged (cloud-journey-ci.sh). 2026-11-17: no parser read a `FAIL <step>` line as a failing
# test, so while feat-cmux-next's own journey was red ("stub: forwarded login and a tool round trip", base job
# 134037946137 at de3b0eab) every PR whose journey ran was refused "its failed steps' own lines name no failing test
# or error line ... nothing to compare with the base" (cmux#44814 at ed4e2af2, job 133995408217).
JOURNEY_WORKFLOWS = {".github/workflows/cloud-journey-pr.yml": "journey"}
JOURNEY_STEP = "Cloud journey (staging, this pull request's CLI)"
JOURNEY_STEP_LINE = re.compile(r"^(PASS|FAIL|SKIP) (\S.*?) \d+ ms ::(?: (.*))?$")
JOURNEY_SUMMARY = re.compile(r"^(PASS|FAIL) [\w.-]+: (\d+) passed, (\d+) failed, (\d+) skipped\b")
JOURNEY_RETRIED = re.compile(r"^##\[warning\].* failed once; running it again\b")
# The only lines the step prints outside a journey run (before its first step line, between a summary and the next
# run's first step line, after its last summary): the runner's own header block, cloud-journey-ci.sh's retry warning,
# its closing verdict notice and the runner's exit line. Anything else there is a run that died before its first step
# line (a second team's, PRODUCT_TEAM, cloud-journey-ci.sh's second `run`), whose red no summary counts
# (cmux#45546's review F1).
JOURNEY_OUTSIDE_OK = re.compile(r"^(?:##\[(?:group|endgroup)\].*|##\[notice\]target=\S+ result=\S+"
                                r"|##\[error\]Process completed with exit code \d+\.)$")
# The journey's own files: they decide its steps, their checks and the detail each prints, so a PR that changes one
# owns every step's line, whatever the base prints.
JOURNEY_OWN_FILES = ("scripts/cmux-next/cloud-journey", ".github/workflows/cloud-journey-pr.yml")
# Run-to-run ids in a step's detail (vm_..., inst_..., host_..., a stub nonce): masked like numbers.
JOURNEY_ID = re.compile(r"\b(?:[a-z]+_)?(?=[0-9a-f]*[0-9])(?=[0-9a-f]*[a-f])[0-9a-f]{8,}\b")


def journey_job(name: str, workflow_info: dict) -> bool:
    """NAME is the Cloud journey job of a run of a JOURNEY_WORKFLOWS workflow (WORKFLOW_INFO, its run record)."""
    return JOURNEY_WORKFLOWS.get(str(workflow_info.get("path") or "")) == name


def journey_reds(text: str) -> tuple[Counter, str | None]:
    """(Counter of (step, its detail with ids and numbers masked) for each FAIL line of the judged runs in TEXT, a
    journey job's failed_view text; None, or why TEXT is no finished journey). A judged run is one closed by its
    summary line and not followed by the retry warning; its FAIL lines must be as many as its summary counts. Step
    lines after the last summary are a run cut short, and any line outside a run but JOURNEY_OUTSIDE_OK's is a run
    that died before its first step line. A retry line names the failed first attempt just closed; one after a
    retry's own run (cloud-journey-ci.sh retries each run once) is a later run that died printing nothing."""
    lines = test_reds.log_lines(text)
    skip = test_reds.echoed(lines)
    runs: list[list] = []  # [FAIL keys, summary match, retried, a retry's own run]
    current: list[tuple[str, str]] = []
    pending = grouped = False
    for n, line in enumerate(lines):
        if n in skip:
            continue
        if match := JOURNEY_STEP_LINE.match(line):
            # The runner's header block ends before the step's own output, closed or not.
            pending, grouped = True, False
            if match[1] == "FAIL":
                current.append((match[2], normalise_error(JOURNEY_ID.sub("<id>", match[3] or ""))))
        elif match := JOURNEY_SUMMARY.match(line):
            runs.append([current, match, False, bool(runs) and runs[-1][2]])
            current, pending = [], False
        elif JOURNEY_RETRIED.match(line):
            # It names the run just closed: a failed first attempt, not already retried. After a run cut short (step
            # lines with no summary), a retry's own run or anything else, which run it retries is unknown, and so is
            # which run is judged.
            if pending or not runs or runs[-1][1][1] != "FAIL" or runs[-1][2] or runs[-1][3]:
                return Counter(), (f"a retry line that follows no closed failed run that was a first attempt "
                                   f"({line[:200]})")
            runs[-1][2] = True
        elif pending or not line.strip():
            continue  # a run's own output, or a blank line
        elif line.startswith("##[group]"):
            grouped = True
        elif line.startswith("##[endgroup]"):
            grouped = False
        elif not grouped and not JOURNEY_OUTSIDE_OK.match(line):
            return Counter(), (f"a line outside any journey run ({line[:200]}): a run that died before its first "
                               "step line, which no summary counts")
    if pending:
        return Counter(), "journey step lines after its last closing summary (a run cut short)"
    if not runs:
        return Counter(), "no journey run with a closing summary"
    found: Counter = Counter()
    for fails, summary, retried, _ in runs:
        if len(fails) != int(summary[3]):
            return Counter(), (f"a journey summary counts {summary[3]} failed and its run printed {len(fails)} FAIL "
                               f"step lines ({summary[0][:200]})")
        if not retried:
            found.update(fails)
    return found, None


def journey(repo: str, base: str, name: str, job: dict, head: "FailedView | Unplaced", base_run: dict, base_job: dict,
            github, sha: str, seen: dict) -> str:
    """The audit line for a red Cloud journey job (journey_job) whose every failed journey step of its judged runs
    fails, by step and masked detail, as often or less, on the newest red base verdict for it, BASE_JOB of BASE_RUN;
    raises Refused naming what is not. Never excused: a failed job step besides JOURNEY_STEP (the build, setup), an
    unplaced log, a run cut short or a count that disagrees, a run with no FAIL step line (it never ran, or failed
    outside its steps), and any PR that changes a JOURNEY_OWN_FILES file (its steps and checks are the PR's own)."""
    url = base_run.get("html_url") or f"https://github.com/{repo}/actions/runs/{base_run['id']}"
    failed = {step["name"] for step in job.get("steps") or []  # step-name: classify
              if step.get("conclusion") not in (None, "success", "skipped")}
    if failed != {JOURNEY_STEP}:
        raise Refused(f"'{name}': failed steps {sorted(failed)}, not only '{JOURNEY_STEP}'; nothing to compare "
                      "step by step")
    if head is UNPLACED:
        raise Refused(f"'{name}': {UNPLACED_WHY}; its journey steps are not compared")
    mine, why = journey_reds(view_text(head))
    if why is not None:
        raise Refused(f"'{name}': {why}; a journey that did not finish is never a base red")
    if not mine:
        raise Refused(f"'{name}': red, but its judged journey runs print no FAIL step line; nothing to compare with "
                      "the base")
    number, paths = pr_paths_once(repo, base, sha, github, seen)
    if own := sorted(path for path in paths if path.startswith(JOURNEY_OWN_FILES)):
        raise Refused(f"'{name}': #{number} changes {', '.join(own)[:300]}, which defines the journey's steps and "
                      f"checks; its red step ({'; '.join(step for step, _ in sorted(mine))[:300]}) is never a base "
                      "red, whatever the base prints")
    _, view, _, _ = base_evidence(repo, base, name, base_run, base_job, github, seen)
    theirs, why = journey_reds(view_text(view))
    if why is not None:
        raise Refused(f"'{name}': {base} run {base_run['id']} is no journey verdict ({why}) ({url})")
    if more := sorted((mine - theirs).elements()):
        raise Refused(f"'{name}': journey steps red on this change and not, that way, on {base} run "
                      f"{base_run['id']} ({url}): {'; '.join(f'{step} :: {detail}' for step, detail in more)[:600]}")
    at = f" at {tested_sha(base_run)[:10]}" if tested_sha(base_run) else ""
    return (f"excused '{name}': every failed journey step fails the same way on {base} run {base_run['id']}{at} (the "
            f"newest {base} verdict for it) ({url}), and #{number} changes no journey file: "
            f"{'; '.join(f'{step} :: {detail}' for step, detail in sorted(mine))[:400]}")


class Final(Refused):
    """A refusal no older base verdict can lift: it is judged against the newest verdict alone."""


def compare_window(repo: str, base: str, name: str, head: tuple, head_view: FailedView, window: list,
                   chromium_without_diagnostics: bool, *, flake_state: dict | None = None,
                   workflow: str = "", head_pairs: set | None = None) -> str:
    """The audit line for red job NAME (HEAD: the signature of HEAD_VIEW, its failed_view) when each of its failures is
    on some red base verdict of WINDOW (newest first: (run, its failed_view, signature[, step_errors])); raises Refused
    naming the first that is on none, Final when the newest verdict alone (the Chromium check, a process signal, the
    panic ratchet) refuses it. With HEAD_PAIRS (step_errors), each compared head error must be printed on a base by a
    failed step of the same name. Every line it reads, head and base alike, is a failed_view's. REPO is the base
    run's own repo, which is the PR's unless the base is verified in another (BASE_VERDICT_REPO): nothing but a base
    run's URL is read from it."""
    base_run, base_view, *_ = window[0]
    runs = f"run {base_run['id']}" if len(window) == 1 else "any of runs " + ", ".join(str(w[0]["id"]) for w in window)
    head_steps, head_tests, head_errors = head
    head_crash = crash_signals(head_view)
    # A failure no parser names (#41166's review F2) is refused by the reading every consumer shares: read_head's
    # test_reds.read of the raw log, and classify_any's of HEAD_VIEW below (its per-test results are not whole).
    base_steps, base_tests, base_errors, on = set(), set(), set(), {}
    for run, _, (steps, tests, errors), *_ in window:
        base_steps, base_tests, base_errors = base_steps | steps, base_tests | tests, base_errors | errors
        for test in tests:
            on.setdefault(test, run["id"])
    if chromium_without_diagnostics and (window[0][2][1] or window[0][2][2] or crash_signals(base_view)):
        raise Final(f"'{name}': no failing test or error line to match; nothing to compare with the base")
    head_text = view_text(head_view)
    known = test_reds.flaky_failures(head_text, name, workflow, flake_state) if base == "feat-cmux-next" else {}
    base_tests |= known.keys()
    verdict = test_reds.classify_any(head_text, [(f"{base} run {run['id']}", view_text(view))
                                                 for run, view, *_ in window], name,
                                   flake_state=flake_state if base == "feat-cmux-next" else None, workflow=workflow)
    if verdict is not None and verdict.own:
        raise Refused(f"'{name}': " + "; ".join(verdict.reasons)[:800])
    # Not a test job (a compile or tool that died on a signal): the base must have died the same way.
    if missing := sorted(head_crash - crash_signals(base_view)):
        raise Final(f"'{name}': the process died on signal {', '.join(missing)}, "
                    f"and {base} run {base_run['id']} did not")
    # The ratchet's error line names the run's packages, not its red: its rows are compared instead (RATCHET_SCOPE).
    ratchet = {error for error in head_errors if RATCHET_SCOPE.match(error)}
    if ratchet:
        try:
            unmatched = ratchet_unmatched(head_view, base_view)
        except Refused as error:
            raise Final(f"'{name}': {error}") from None
        if unmatched:
            raise Final(f"'{name}': panic ratchet failures not on {base} run {base_run['id']}: "
                        f"{'; '.join(unmatched)[:600]}")
        head_errors = head_errors - ratchet
    compared = [("failed steps", head_steps, base_steps), ("failing tests", head_tests, base_tests)]
    # A crash-class or check rule line is a named failure, but its job also has steps that print only error lines
    # (the concurrency rule): those stay compared unless a real test failed.
    if not any(not test_reds.is_rule_failure(test) for test in head_tests):
        compared.append(("errors", head_errors, base_errors))
    for kind, head, seen in compared:
        if missing := sorted(head - seen):
            raise Refused(f"'{name}': {kind} not on {base} {runs}: {'; '.join(missing)[:600]}")
    # The failed steps by name compared above; here by identity: each head failed step's (name, conclusion), as often
    # as the head has it (#41158's review F1: a cancelled step is not a failed one, and a step that failed twice is not
    # the base's one failure), all on ONE base verdict of the window, each verdict compared alone. #41166's review F1:
    # the window's keys were merged (Counter |, the most of each key over the verdicts), so a head whose step failed
    # and another of that name was cancelled matched a base verdict with the failure and an older one with the cancel,
    # an identity no base run had.
    mine = failed_step_keys(head_view.job)
    gaps = [mine - failed_step_keys(view.job) for _, view, *_ in window]
    if all(gaps):
        missing = min(gaps, key=lambda gap: sum(gap.values()))
        each = ", each verdict alone" if len(window) > 1 else ""
        raise Refused(f"'{name}': failed steps not on {base} {runs} with the same conclusion, as often{each}: "
                      f"{step_keys_text(missing)[:400]} (the head's: {step_keys_text(mine)[:200]})")
    # Each failing test whole on ONE verdict of the window: its name, its diagnostic (classify's shared: the same error
    # and the same files) and as often as the head fails it (#41222's review F1 at 6719ba22: a name failing twice is
    # two failures). #41329's review F1: the name and diagnostic were taken from any verdict and the count from the
    # most any verdict had, so a head failing A twice with no error matched a base that failed it once that way and
    # an older one that failed it twice with a TypeError, a failure no base run had. Each test may still be on its own
    # verdict (the per-test window), one that also holds the head's failed steps (above): the property test's window
    # detector found a test on one verdict and the steps on another; a quarantined flake is the base's however often
    # it fails.
    # Counted like for like (merging #41220's step mapping): the head's FAILED sections, what a base view keeps. A
    # head's ERRORED (continue-on-error) section is never in a base's view, so counting it refused the very red the base
    # has (cmux#41001's head served as its own base: everyMenuKeepsAShortTopLevel() x6, at most x2, for the catalog
    # check's ERRORED section); its tests are still compared by name above and classified whole below.
    times = test_reds.failed_in(head_view.failed_text())
    alone = []
    for (run, view, *_), gap in zip(window, gaps):
        if gap:
            continue
        text = view_text(view)
        judged = test_reds.classify(head_text, text, name, f"{base} run {run['id']}")
        alone.append((set(judged.shared) if judged is not None else set(),
                      test_reds.failed_in(text)))
    if lone := sorted(f"{test} x{n} (at most x{max([counts[test] for same, counts in alone if test in same] or [0])})"
                      for test, n in times.items() if test not in known
                      and not any(test in same and counts[test] >= n for same, counts in alone)):
        raise Refused(f"'{name}': failing tests more often than on any of {base} {runs} that fails them the same way with the head's failed steps, "
                      f"each verdict alone: {'; '.join(lone)[:600]}")
    if head_pairs is not None and compared[-1][0] == "errors":
        printed = set().union(*(entry[3] for entry in window if len(entry) > 3))
        if missing := sorted(f"{error} (step '{step}')" for step, error in head_pairs
                             if error in head_errors and (step, error) not in printed):
            raise Refused(f"'{name}': errors not printed by the same failed step on {base} {runs}: "
                          f"{'; '.join(missing)[:600]}")
    rows = [f"{crate}: clippy::{lint} {count} > {where}"
            for (crate, lint, where), count in sorted(ratchet_red(head_view)[0].items())] if ratchet else []
    what = ("; ".join(test if on.get(test) == base_run["id"] else
                      f"{test} ({known[test]})" if test in known else f"{test} (red on run {on[test]})"
                      for test in sorted(head_tests))
            or "; ".join(rows + sorted(head_errors)))
    url = base_run.get("html_url") or f"https://github.com/{repo}/actions/runs/{base_run['id']}"
    # The base verdict is the newest one, not necessarily the base tip's: the base tier runs at most
    # once every 15 minutes, so name the commit and time it is from.
    at = f" at {tested_sha(base_run)[:10]}" if tested_sha(base_run) else ""
    when = f", {base_run['created_at']}" if base_run.get("created_at") else ""
    older = (f" or one of the {len(window) - 1} red {base} verdict(s) before it (runs "
             f"{', '.join(str(w[0]['id']) for w in window[1:])})") if len(window) > 1 else ""
    return (f"excused '{name}': {base} run {base_run['id']}{at} (the newest {base} verdict for it{when}){older} "
            f"fails the same way ({url}): {what[:400]}")


class Infra(Refused):
    """A red that is the infrastructure's (test_reds.lost_runner: the runner was lost), not a verdict: never the
    pull request's own red, never excused, and it needs a re-run, like a cancelled job."""


def infra(name: str, job: dict, why: str) -> Infra:
    return Infra(f"'{name}' is infra, not a verdict (job {job.get('id')}: {why}); it is never this PR's own red "
                 "and needs a re-run, like a cancelled job")


# A check that runs on pull requests only (language-boundaries.yml, classic-api-guard.yml: pull_request_target) never
# has a base verdict, so each of its reds was refused as "no feat-cmux-next run of its workflow has a verdict for it to
# compare with", the one an agent reads as "the red cannot be judged". When its failed steps printed nothing but the
# check's own "could not read its input; re-run this check" line, it decided nothing about the PR: cmux#41500 at
# d059d7bd (job 130862862041, 2026-11-11), whose PR-files listing hit the installation's rate limit and whose merge-ref
# fallback did not match the moved base; its re-run passed. Such a red is Infra: still refused (never excused, the PR
# is not judged by it), named as the re-run it needs. Any other error line, a failing test, or a log not placed on its
# steps keeps the refusal below.
RERUN_ASK = re.compile(r"\bre-run this check(?:[.;]|$)", re.I)

# A job whose failed steps printed nothing but GitHub's API rate-limit refusal decided nothing about the PR either:
# cmux#44387 at cf31af39 (2026-11-16, job 133700254405), whose push-only `re-run the runs that deferred to the
# published tree` could not list the tree's deferred markers ("gh: API rate limit exceeded for installation ID ...",
# HTTP 403) on either token. Its base runs were green, so it was refused "not red on feat-cmux-next ...; fix it on this
# head", and land-judge named an update-branch that reruns every check for a quota red. Such a red is Infra too, with
# or without a base verdict: refused (never excused: the job did not run), named as the re-run it needs. Any other
# error line beside it, or a failing test, keeps the comparison.
GITHUB_QUOTA = re.compile(r"\bAPI rate limit exceeded\b|\bsecondary rate limit\b", re.I)

# The published-tree hand-off re-runs other commits' runs. Its own quota-only failure is a retryable gate state,
# not a red in the pull request. The hand-off emits this live annotation without installation or request IDs.
TREE_HANDOFF_JOB = "re-run the runs that deferred to the published tree"
TREE_HANDOFF_STEP = "Re-run the runs that deferred to this tree"
TREE_HANDOFF_QUOTA = re.compile(
    r"^##\[error\]\[quota-only\] deferred runs not re-run for the published tree; run (?P<run>\d+); "
    r"no attempt before (?P<retry>\d{2}:\d{2}Z); the repo installation's API limit refused its API call\."
    r"(?: Deferred markers remain for the next run\.)?$")


class JobRateLimited(Refused):
    """A failed CI job reported only its own GitHub API quota refusal."""


def github_quota_only(view: "FailedView | Unplaced") -> str | None:
    """The error line VIEW's failed steps printed when each of them is GitHub's API rate-limit refusal (GITHUB_QUOTA)
    and no test failed, else None."""
    sig = signature(view)
    if sig is UNPLACED:
        return None
    steps, tests, errors = sig
    if not steps or tests or not errors or not all(GITHUB_QUOTA.search(error) for error in errors):
        return None
    return sorted(errors)[0].strip()


def tree_handoff_quota_only(job: dict, log: str) -> str | None:
    """The published-tree hand-off's sole quota refusal, with its job id and retry boundary."""
    failed = [str(step.get("name") or "") for step in job.get("steps") or []  # step-name: classify
              if step.get("conclusion") == "failure"]
    if failed != [TREE_HANDOFF_STEP]:
        return None
    errors = [text for text in test_reds.lines_of(log) if text.startswith("##[error]")
              and not text.startswith("##[error]Process completed with exit code")]
    if len(errors) != 1 or not (match := TREE_HANDOFF_QUOTA.fullmatch(errors[0].rstrip())):
        return None
    return (f"run {match.group('run')}; job {job.get('id')}; no attempt before {match.group('retry')}")


def asks_only_rerun(view: "FailedView | Unplaced") -> str | None:
    """The error line VIEW's failed steps printed when each of them only asks for a re-run (RERUN_ASK), else None."""
    sig = signature(view)
    if sig is UNPLACED:
        return None
    steps, tests, errors = sig
    if not steps or tests or not errors or not all(RERUN_ASK.search(error) for error in errors):
        return None
    return sorted(errors)[0].strip()


def lost_runner_notes(repo: str, job: dict, github) -> list:
    """JOB's check-run annotations for lost_runner_log, or [] when they cannot be read."""
    try:
        notes = github.json(f"repos/{repo}/check-runs/{job['id']}/annotations")
    except (Refused, KeyError, ValueError):
        return []
    return notes if isinstance(notes, list) else []


def worker_crash(repo: str, name: str, job: dict, github, notes: list | None = None) -> None:
    """Refuses JOB, a red with no step failed, as one its runner refused when its annotations (NOTES, else read now)
    say its runner's worker crashed under it (test_reds.runner_worker_crashed: cmux#50809's and cmux#50827's
    react-apps-base-check, the runner's disk full). In merge_hold's words for a job its runner refused at setup, the
    red glaeda-gh reruns once per (head, run): Infra's words stopped the land own_red."""
    if any(step.get("conclusion") == "failure" for step in job.get("steps") or [] if isinstance(step, dict)):
        return  # a failed step keeps its verdict, and costs no annotations read
    if notes is None:
        notes = lost_runner_notes(repo, job, github)
    if why := test_reds.runner_worker_crashed(job, notes):
        raise Refused(f"'{name}' was refused at setup by its runner (job {job.get('id')}: {why}); it gets re-run, "
                      "never excused")


def lost_runner_log(repo: str, name: str, job: dict, github) -> str:
    """JOB's log, after refusing a job that lost its runner (test_reds.lost_runner) as Infra. Its steps decide first, at
    no cost; a log GitHub cannot serve (a lost runner leaves none: BlobNotFound) has its check run's annotations read
    to tell a lost runner from an unreadable verdict, which stays the refusal it was. A log that reads keeps the same
    question: a runner shut down under a job prints its notice there and leaves a failed step behind
    (test_reds.runner_shut_down), so the log a caller is about to compare is read for it first."""
    if why := test_reds.lost_runner(job):
        worker_crash(repo, name, job, github)
        raise infra(name, job, why)
    try:
        text = github.log(repo, job)
    except Refused as error:
        notes = lost_runner_notes(repo, job, github)
        worker_crash(repo, name, job, github, notes)
        if why := test_reds.lost_runner(job, notes, str(error)):
            raise infra(name, job, why) from None
        raise
    if why := test_reds.lost_runner(job, (), text):
        raise infra(name, job, why)
    return text


def section_lines(view: FailedView) -> list[tuple[dict, list[str]]]:
    """[(step, the lines of VIEW's section of it)] for each section of VIEW (failed_view), in log order: each step
    that failed (ERRORED included on a head's), never a passing one, never "Complete job" (which prints none of its
    own). Each line is its stamp and text (`gh run view --log`'s job and step columns dropped)."""
    view_text(view)
    found = []
    for k, _, lines in view.sections:
        own = []
        for line in lines:
            parts = line.split("\t", 2)
            own.append(parts[2] if len(parts) == 3 and STAMP.match(parts[2]) else line)
        found.append((view.steps[k], own))
    return found


def step_failed(step: dict) -> bool:
    return step.get("conclusion") not in (None, "success", "skipped")


def quarantined_only(view: "FailedView | Unplaced", known: dict) -> bool:
    """A whole test-step red (VIEW: its failed_view) explained entirely by matching quarantines, with no additional
    failing step/error."""
    sig = signature(view)
    if sig is UNPLACED:
        return False  # no failed step's lines are proven, so no quarantine explains them
    text = view_text(view)
    found = test_reds.read(text)
    steps, _, errors = sig
    if (not found.failed or found.crashes or found.truncated or found.failed - known.keys()
            or not steps or any(not re.search(r"\btests?\b", step, re.I) for step in steps)):
        # found.truncated holds a failure no parser names (test_reds.read): no quarantine's (#41166's review F2).
        return False
    # A generic failed test-named step must not borrow a quarantined test from another step: each failed section's own
    # lines name its quarantined tests.
    for _, lines in section_lines(view):
        result = test_reds.read("\n".join(lines))
        if not result.failed or result.crashes or result.truncated or result.failed - known.keys():
            return False
    normalized = normalise_error
    diagnostics = set()
    for observed in test_reds.observations(text):
        if observed["outcome"] != "fail":
            continue
        for line in observed["signature"].splitlines():
            # Bun stores its `error:` headline without that prefix, then its assertion block separated by ` / `.
            headline = line.split(" / ", 1)[0]
            diagnostics.update((normalized(line), normalized(headline), normalized("error: " + headline)))
    return errors <= diagnostics


# teamleaderleo/leo-workspace's `ws-check` (2026-11-05). That repo's Actions are off, so its checks run in
# manaflow-ai/cmuxterm-hq Actions (fast-checks.yml through cmux-ci, or fleet-reconciler-ws-check.yml's per-head check
# job) and come back as one commit status, `ws-check`, whose target_url is that run. The head has no Actions job or
# check run of its own, so every red read "no failed job found on the head to compare with the base" and none could
# be excused. Its verdict is judged here per test, from the run's log: tools/ws_check_run.py prints each step between
# `##[group]STEP` and `ws-check step FAILED: STEP (exit ...)`, then one WS_CHECK_RESULT=<json> line whose `failed`
# lists the red steps. A red step's tests are unittest's `FAIL: ...`/`ERROR: ...` lines (their count must equal its
# FAILED (...) summary, else the step's list is unreadable); a red step with none (a lint) is compared by every line
# it printed, numbers and the runner's checkout root masked, so a new violation is a new line.
# A head red is excused only when each of its failing tests (and its step's own `ws-check: ...` lines) fails on the
# base too, judged the way Actions jobs are: the newest base commit with a ws-check verdict decides (a pass there means
# the base is green: the head's red is its own, or fixed on the base when that pass is after the merge-base); a red one
# is compared first, then older red verdicts, at most BASE_WINDOW within BASE_WINDOW_HOURS, never past a pass. A
# pending, error (ws-check's "no verdict") or missing status is no result: never excused on the head, skipped on the
# base. A failure whose description, run, job or log cannot be read as above is refused, never guessed.
# The PR's merge-base (2026-11-05, LW#3538 at 5e80abcb): main at 187b3ca3 failed `host_budget and lane_place`; #3524
# (209e7eb6) fixed it, and main then went red on another step. The head, branched at 187b3ca3, failed that same step,
# but the window (the newest red verdict, then older ones) never reached 187b3ca3, so a red the PR started from read as
# its own and only merging main could clear it. When the newest base verdict is red, a failure the window does not
# show is also looked up at the merge-base commit's own ws-check verdict (that commit's, never an older commit's):
# red there too is not this PR's red. A green newest verdict still refuses as above: there merging main makes the
# head green. A red one means merging main cannot, which is why only then is the merge-base read. When a base pass
# between the merge-base and the tip ended the window (LW#3538: #3524's pass at 209e7eb6), the failure was fixed on
# the base after the PR branched. It is excused only when the PR changes none of the paths that changed between
# the merge-base and that pass, so the PR cannot have undone the fix; else, or when either diff can't be listed
# whole, it is refused (cmux#36638 F1). A merge-base with no verdict, a pending one or a pass excuses nothing; one
# whose failure cannot be read is refused.
WS_CHECK = "ws-check"
WS_CHECK_REPOS = {"teamleaderleo/leo-workspace": "manaflow-ai/cmuxterm-hq"}  # repo: the repo its runs are in
WS_CHECK_COMMITS = 30  # base commits read for a verdict, newest first (most main commits get none)
WS_CHECK_TESTED_TIPS = 20  # base commits whose squash tree a run may have tested (one local merge-tree each)
# leo-workspace tools/ws-check describes a failure "N of M steps failed: STEP", cut to 139 characters. It may lead with
# "base red (main SHA8 fails it too) " (main's own run fails those steps) and end the step with a hint ("STEP; lints
# before the next push: ..."); ws_check_names_step reads the step text.
# Since leo-workspace#9404 (2026-11-23) a run reruns its failed units on main and tools/ws-check discounts those that
# fail there too (discount_base_reds): the status counts only the run's own failed steps, "N of M steps failed: UNIT
# (+K base red discounted, main SHA8)", or since lw#9754 "N of M steps failed (+K base red discounted, main SHA8): UNIT",
# while WS_CHECK_RESULT's `failed` still lists every failed step. ws_check_discount reads that count back from the log.
WS_CHECK_DESCRIPTION = re.compile(r"(?:base red \(main [0-9a-f]{8} fails it too\) )?(\d+) of (\d+) steps failed"
                                  r"(?: \(\+(\d+) base red discounted, main ([0-9a-f]{8})\))?: (.*)", re.S)
# Since lw#11671 (2026-11-26) a discounted status too long for 139 characters keeps its counts, base and first unit:
# "N failed after discounting K on main SHA8: UNIT", N the run's own failed units (not steps), UNIT the first one's
# file (a step's " [UNIT]" part, or the step when it has none). Unread, every such red was refused "names no failed
# steps" and no per-test comparison ran: lw#12133 at fb44c444 ("4 failed after discounting 24 on main 33ce8b65:
# test_review_pool_routing.py") and lw#12080 stopped red_not_excused on 2026-11-26. Read, its units are judged per
# test against main like any other ws-check red: a unit that passes on main stays the head's red.
WS_CHECK_LONG_DESCRIPTION = re.compile(r"(\d+) failed after discounting (\d+) on main ([0-9a-f]{8}): (.*)", re.S)
# ws_check_run.py's own base pass lines (leo-workspace tools/ws-check own_base_pass reads the same ones): one "whole" or
# "cut" line naming the main the failed units ran again on, and a "FAILED on main too" line per unit that failed there.
WS_CHECK_BASE_PASS = re.compile(r"^ws-check base pass (?:whole: main ([0-9a-f]{40}),|cut: main ([0-9a-f]{40}): "
                                r"[1-9]\d* of \d+ reruns ended)")
WS_CHECK_BASE_FAILED = re.compile(r"^ws-check step FAILED on main too: (.+?) \(exit -?\d+")
WS_CHECK_FAILED_LABEL = re.compile(r"^ws-check step FAILED: (.+?) \(exit -?\d+")
# ws_check_run.py's pseudo-step for a run that wrote the global git config (cmux#28148): no step line of its own, only
# "ws-check: a step changed the global git config PATH (...)". Before this it was refused "has no 'ws-check step
# FAILED: global git config changed by a step' line" (leo-workspace#9703 at 85551f8b, run 45341796653, 2026-11-24).
WS_CHECK_GIT_CONFIG_STEP = "global git config changed by a step"
WS_CHECK_GIT_CONFIG_LINE = "ws-check: a step changed the global git config"


def ws_check_own_base(lines: list[str], at: int, failed: list[str]) -> dict | None:
    """The run's own base pass, read from LINES before AT the way tools/ws-check discount_base_reds reads it:
    {"main": the main commit its failed units ran again in the tree of, "on_main": the FAILED labels that failed there
    too, "head_only": the labels that did not}. None when the log holds no such pass (none, several, or one that reran
    nothing), or a failed step has no FAILED line (ws-check discounts nothing then)."""
    ours = {m[1] for line in lines[:at] if (m := WS_CHECK_FAILED_LABEL.match(line))}
    passes = [m[1] or m[2] for line in lines[:at] if (m := WS_CHECK_BASE_PASS.match(line))]
    if not ours or len(passes) != 1 or set(failed) - {label.split(" [", 1)[0] for label in ours}:
        return None
    theirs = {m[1] for line in lines[:at] if (m := WS_CHECK_BASE_FAILED.match(line))}
    if not ours & theirs:
        return None
    return {"main": passes[0], "on_main": frozenset(ours & theirs), "head_only": frozenset(ours - theirs)}


def ws_check_discount(lines: list[str], at: int, failed: list[str]) -> tuple[list[str], int, str] | None:
    """(the run's own failed labels, sorted, how many it discounted, the main it reran them on) as tools/ws-check
    discount_base_reds counts them: ws_check_own_base's reading of the same lines, None for the same reasons."""
    found = ws_check_own_base(lines, at, failed)
    if found is None:
        return None
    return sorted(found["head_only"]), len(found["on_main"]), found["main"]


def ws_check_described(named: re.Match, failed: list[str], steps, lines: list[str], at: int) -> bool:
    """Whether a ws-check status's description (NAMED, a WS_CHECK_DESCRIPTION or WS_CHECK_LONG_DESCRIPTION match) is
    its run's WS_CHECK_RESULT: the count and first step of FAILED, or the count and first unit tools/ws-check left after
    discounting main's reds (the long form: the unit count, discount, main and first unit's file, cut at 139)."""
    if named.re is WS_CHECK_LONG_DESCRIPTION:
        found = ws_check_discount(lines, at, failed)
        if found is None or not found[0]:
            return False
        own, discounted, main = found
        step, bracket, unit = own[0].partition(" [")
        first = unit.removesuffix("]") if bracket else step
        return ((int(named[1]), int(named[2]), named[3]) == (len(own), discounted, main[:8])
                and bool(named[4]) and first.startswith(named[4]))
    count, total, described = int(named[1]), int(named[2]), named[5]
    if total != steps:
        return False
    if not named[3] and count == len(failed) and ws_check_names_step(described, failed[0]):
        return True
    found = ws_check_discount(lines, at, failed)
    if found is None or not found[0]:
        return False
    own, discounted, main = found
    if count != len({label.split(" [", 1)[0] for label in own}):
        return False
    marker = f" (+{discounted} base red discounted, main {main[:8]})"
    if named[3]:  # lw#9754's shape: the marker before the unit
        return (int(named[3]), named[4]) == (discounted, main[:8]) and ws_check_names_step(described, own[0])
    # The marker after the unit, both cut together at 139 characters.
    return (own[0] + marker).startswith(described)


def ws_check_names_step(described: str, step: str) -> bool:
    """Whether the step DESCRIBED in a ws-check status (at most 139 characters, never a log) names STEP: STEP cut
    short, STEP itself, or STEP followed by a "; " hint. Nothing looser, so a description naming another step never
    matches."""
    return step.startswith(described) or described == step or described.startswith(step + "; ")


UNITTEST_RED = re.compile(r"^(?:FAIL|ERROR): (\S.*)$")
UNITTEST_SUMMARY = re.compile(r"^FAILED \(([^)]*)\)$")
# A unittest failure block's parts, on lines lines_of has stripped: the separator lines that end it, a frame's
# `File "...", line N` line, and the caret line under a frame's source (Python 3.11+). What is left after the frames is
# the failure's own text: its exception line and, for an assertEqual, the diff.
UNITTEST_RULE = re.compile(r"^(?:={70,}|-{70,})$")
UNITTEST_FRAME = re.compile(r'^File ".*", line \d+')
UNITTEST_CARETS = re.compile(r"^[\^~ ]+$")
# The line a traceback ends with (`AssertionError: ...`, `subprocess.CalledProcessError: ...`, `KeyError: 'x'`): never
# skipped as a frame's source line when Python printed none.
UNITTEST_RAISED = re.compile(r"^[A-Za-z_][\w.]*(?:Error|Exception|Exit|Interrupt|Warning|Iteration|Failure)\b")
# A step that crashed (a signal, a fatal interpreter error) is never compared by its test names: a crash after a
# complete unittest summary would otherwise hide behind a failure the base shares (cmux#36219 F1).
WS_CHECK_CRASH = re.compile(r"Segmentation fault|core dumped|Fatal Python error|\bKilled\b|\bAborted\b|"
                            r"MemoryError|died on signal|unexpected signal")
# tools/ws_check_run.py's step line; since leo-workspace#3746 it also ends with the step's time (", 62.1 s"), and since
# its units it carries the step's CPU first (", cpu 1.0 s, 30.0 s").
WS_CHECK_STEP_EXIT = re.compile(r" \(exit (-?\d+), ran \d+, skipped \d+, gh calls \d+(?:, cpu [\d.]+ s)?(?:, [\d.]+ s)?\)$")
# Since ws_check_run.py splits a step into its units (a suite each, a big suite in shards), each unit prints its own
# group and result line labelled "STEP [UNIT]" ("... [test_ws_deploy_swap.py]", "... [test_lane_place.py 2/4]"), while
# WS_CHECK_RESULT's `failed` names the STEP alone. Read as only "ws-check step FAILED: STEP (exit", every red split into
# units was refused "has no 'ws-check step FAILED: STEP' line" though the log held it (leo-workspace#4322 at aa928f1c,
# run 43011639090: `every other tools/test_*.py ... [test_ws_deploy_swap.py]`; #4297 at 7c9ae719, run 42997255537).
WS_CHECK_UNIT = r"(?: \[[^\]\n]+\])?"
WS_CHECK_SHARD = re.compile(r" \d+/\d+$")  # "[test_lane_place.py 2/4]": a big suite's shard
# The checkout root a ws-check run's paths start with: fast-checks.yml's workspace, or ws-check-heads.yml's clone.
WS_CHECK_ROOT = re.compile(r"(?:/[\w.-]+)*/_work/(?:cmuxterm-hq/cmuxterm-hq|_temp/lw)/")
# A cmux-ci run's run-name (cmuxterm-hq fast-checks.yml): `Fast checks SNAPSHOT`, then ` tests REPO@SHA` (the tested
# repo and commit) or ` job ID` (the lane-gh broker's cmux-ci job, 32 hex digits). LW#4369 at 4f84acf0 (2026-11-11):
# the broker's merge-tested run 43048550008 was named `Fast checks 48b2f601... job 49c43a9c...`, which the run-name
# match before this read as "the WS_CHECK_RESULT ... is from another checkout", though its receipt named that snapshot.
WS_CHECK_RUN_NAME = r"Fast checks {}(?: tests \S+| job [0-9a-f]{{32}})?"
# The broker cuts a hosted repo's snapshot to these paths of the tested tree (its fast_checks_hosts entry).
WS_CHECK_HOSTS_FILE = "machines/lane-gh-broker.json"
HEX40 = re.compile(r"[0-9a-f]{40}")
# A ws-check run the build fleet's Linux pool (or an owned Mac) ran for a cancelled Actions run (hq#12237: the lane-gh
# broker's ci_fleet_*, parts/43-calls-ci-fleet.py). No runner ever took the Actions job; it was cancelled so the
# snapshot could run as a controller job, which prints fast-checks.yml's FAST_CHECKS_RECEIPT naming that cancelled run
# (ran_on "build-fleet"). The status links the cancelled run, and on 2026-11-18 every such status read "job 'checks' in
# run 44400654026 is completed/cancelled: no result to read" (leo-workspace#5962 at 60199fb5, fleet job
# 78ae6c6073141385ddcecd04), so no pool-run red, its own or a base's, was ever judged. The broker's failure status now
# names the controller job in its link (`.../actions/runs/RUN?fleet_job=ID`), and the log is read from the controller
# (`cmux-ci log ID`) and held to everything an Actions log is, and more: the Actions job never started (no runner, no
# step), the controller job is a fast-checks job that failed, of the broker job the run-name names, whose command
# carries the run id; the receipt says build-fleet on the controller's worker. A link that names no fleet job keeps
# "no result"; one whose job or log cannot be read here is refused, never guessed.
WS_CHECK_FLEET_JOB = r"(?:\?fleet_job=([0-9a-f]{24}))?"
WS_CHECK_FLEET_READ_S = 180


def fleet_read(op: str, job_id: str) -> str:
    """`cmux-ci OP JOB_ID`'s output (op: status or log): the build fleet's controller, through this host's client
    ($CMUX_CI_CLIENT, else cmux-ci on PATH). Refused when there is none, or it fails or times out."""
    client = os.environ.get("CMUX_CI_CLIENT") or shutil.which("cmux-ci")
    if not client:
        raise Refused(f"this host has no cmux-ci client to read fleet job {job_id}")
    try:
        done = subprocess.run([client, op, job_id], capture_output=True, text=True, errors="replace",
                              timeout=WS_CHECK_FLEET_READ_S, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError) as error:
        raise Refused(f"cmux-ci {op} {job_id} did not answer ({type(error).__name__}: {str(error)[:120]})") from None
    if done.returncode != 0 or not done.stdout.strip():
        raise Refused(f"cmux-ci {op} {job_id} exited {done.returncode}: "
                      f"{(done.stderr or done.stdout).strip()[-200:] or 'no output'}")
    return done.stdout


FLEET_READS: dict[tuple[str, str], str] = {}


def fleet_read_once(op: str, job_id: str) -> str:
    """fleet_read, once per process for each (op, job): a finished controller job never changes."""
    if (op, job_id) not in FLEET_READS:
        FLEET_READS[(op, job_id)] = fleet_read(op, job_id)
    return FLEET_READS[(op, job_id)]


def ws_check_fleet_lines(where: str, run_id: str, run: dict, job: dict, fleet_id: str) -> tuple[list[str], dict]:
    """(the log lines, the controller job) of FLEET_ID, the controller job that ran Actions run RUN_ID's cancelled
    ws-check JOB; Refused unless it is that run's: see WS_CHECK_FLEET_JOB."""
    if job.get("status") != "completed" or job.get("conclusion") != "cancelled" or job.get("runner_id") \
            or job.get("steps"):
        raise Refused(f"{where}: its status names fleet job {fleet_id}, but job '{job.get('name')}' in run {run_id} "
                      f"is {job.get('status')}/{job.get('conclusion')} and ran on a runner: only a run cancelled "
                      "before any runner took it moves to the fleet")
    try:
        found = json.loads(fleet_read_once("status", fleet_id))
    except ValueError:
        found = None
    if not isinstance(found, dict) or found.get("id") != fleet_id:
        raise Refused(f"{where}: the controller's answer for fleet job {fleet_id} is not that job")
    command, workspace = str(found.get("command") or ""), str(found.get("workspace") or "")
    named = re.search(r" job ([0-9a-f]{32})$", run.get("display_title") or "")
    if found.get("kind") != "fast-checks" or found.get("state") != "failed" \
            or not re.search(rf"\s{re.escape(run_id)}\s", command) \
            or workspace != (f"fast-checks-{named[1]}" if named else workspace) \
            or not workspace.startswith("fast-checks-"):
        raise Refused(f"{where}: fleet job {fleet_id} ({found.get('kind')}, {found.get('state')}, workspace "
                      f"{workspace or 'none'}) is no failed fast-checks job of run {run_id}")
    return lines_of(test_reds.plain(fleet_read_once("log", fleet_id))), found


def ws_check_mirror(repo: str) -> Path | None:
    """This host's mirror of REPO (GH_MIRROR_ROOT, else ~/Projects/.wt-mirrors: wt's and gh_mirror_reads'), or None."""
    owner, _, name = repo.partition("/")
    root = Path(os.environ.get("GH_MIRROR_ROOT") or Path.home() / "Projects" / ".wt-mirrors")
    mirror = root / owner / f"{name}.git"
    return mirror if (mirror / "HEAD").is_file() and (mirror / "objects").is_dir() else None


# A commit neither this host's mirror nor the cache has is fetched into the mirror before it is refused unread. A host
# with lane-gh and no GitHub token has no credentials for git's own fetch, and its broker fetches branches by name only
# (no pull ref, no commit id). Before this, a judgement on such a host refused "git cannot read ... commit (not in this
# host's mirror or cache, and its fetch failed)" until someone ran that fetch by hand, and the read then passed.
MIRROR_REFRESH_SECONDS = 300


def mirror_refresh_command(repo: str, where: Path, branches: list[str]) -> list[str]:
    """The one command that refreshes WHERE (this host's mirror of REPO, else the cache) with REPO's BRANCHES: `lane-gh
    fetch` when lane-gh is on PATH and there is no GitHub token, else git's fetch from origin."""
    if shutil.which("lane-gh") and not github_token():
        return ["lane-gh", "fetch", repo, "--dir", str(where),
                *(arg for branch in branches for arg in ("--branch", branch))]
    return ["git", "--git-dir", str(where), "fetch", "-q", "--no-tags", "origin",
            *(f"+refs/heads/{branch}:refs/remotes/origin/{branch}" for branch in branches)]


def mirror_refresh(repo: str, where: Path, branches: list[str]) -> tuple[str, str]:
    """Run mirror_refresh_command once: (the command as one shell line, "" when it ran clean, else why it failed)."""
    argv = mirror_refresh_command(repo, where, branches)
    shown = shlex.join(argv)
    env = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
    try:
        done = subprocess.run(argv, capture_output=True, text=True, env=env, timeout=MIRROR_REFRESH_SECONDS,
                              stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError) as error:
        return shown, f"{type(error).__name__}: {error}"[:200]
    if done.returncode:
        return shown, f"exit {done.returncode}: {(done.stderr or done.stdout).strip()[-200:] or 'no output'}"
    return shown, ""


def ws_check_branches(repo: str, base: str, sha: str, github) -> list[str]:
    """The branches a mirror refresh fetches SHA and BASE's tip by: the head branch of SHA's pull request in REPO, when
    GitHub names one, then BASE."""
    try:
        pulls = github.json(f"repos/{repo}/commits/{sha}/pulls?per_page=100") if github is not None else []
    except Refused:
        pulls = []
    heads = [str(pull["head"]["ref"]) for pull in pulls or [] if isinstance(pull, dict)
             and isinstance(pull.get("head"), dict) and pull["head"].get("sha") == sha and pull["head"].get("ref")
             and ((pull["head"].get("repo") or {}).get("full_name") or "").lower() == repo.lower()]
    return list(dict.fromkeys([*heads[:1], base]))


# (repo, head) -> the branches a mirror refresh fetches HEAD by (ws_check_branches), named by ws_check_tested_tree.
WS_CHECK_BRANCHES: dict[tuple[str, str], Callable[[], list[str]]] = {}


@once_per_judgement("git squash tree", key=lambda repo, head, tip, branches=None, whole=False: (repo, head, tip, whole))
def ws_check_squash_tree(repo: str, head: str, tip: str, branches: Callable[[], list[str]] | None = None,
                         whole: bool = False) -> str:
    """The tree a merge-tested ws-check run of HEAD must have tested for HEAD to land on base tip TIP: HEAD merged with
    TIP (the tree a pinned squash makes), cut to the paths its fast_checks_hosts entry names, as the lane-gh broker cuts
    its snapshot (cmuxterm-hq tools/lane-gh-broker ci_snapshot and ci_merged_tree: HEAD's own tree when TIP has HEAD,
    else `git merge-tree --write-tree TIP HEAD`). Read from git only: git_cache(REPO) over this host's mirror's objects
    (ws_check_mirror), fetching a commit neither has. Refused when git cannot answer, the merge conflicts or the merged
    tree names no paths: never guessed."""
    git = git_cache(repo)
    if git is None or not (HEX40.fullmatch(head) and HEX40.fullmatch(tip)):
        raise Refused(f"no git repository for {repo} to merge {head[:12]} with {tip[:12]} in")
    where = source_cache() / (repo.replace("/", "__") + ".git")
    env = {**os.environ, "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "", "SSH_ASKPASS": ""}
    mirror = ws_check_mirror(repo)
    if mirror is not None:  # read through, never written: every object made here goes to the cache
        env["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = str(mirror / "objects")

    def run(*args: str, text: str | None = None) -> subprocess.CompletedProcess:
        return subprocess.run(["git", "--git-dir", str(where), *args], capture_output=True, text=True, env=env,
                              timeout=GIT_SECONDS, input=text, stdin=None if text is not None else subprocess.DEVNULL)

    def shallow() -> bool:
        said = run("rev-parse", "--is-shallow-repository")
        return said.returncode != 0 or said.stdout.strip() != "false"  # an unanswered check counts as shallow

    def unshallow() -> None:
        if shallow() and (run("fetch", "-q", "--no-tags", "--filter=blob:none", "--unshallow", "origin", head,
                              tip).returncode or shallow()):
            raise Refused(f"git's {repo} cache is shallow (git_commit's one-commit fetches) and its whole history "
                          f"could not be fetched, so {head[:12]} cannot be merged with {tip[:12]} by their history")

    try:
        for commit in (head, tip):
            if run("cat-file", "-e", f"{commit}^{{commit}}").returncode:
                # The whole history (no --depth): merge-tree needs the merge-base. No blobs until a merge reads them.
                if run("fetch", "-q", "--no-tags", "--filter=blob:none", "origin", commit).returncode or \
                        run("cat-file", "-e", f"{commit}^{{commit}}").returncode:
                    # The mirror is refreshed first (MIRROR_REFRESH_SECONDS), and refused only if that fails too.
                    named = branches or WS_CHECK_BRANCHES.get((repo, head))
                    fetch, why = mirror_refresh(repo, mirror or where, named() if named else [])
                    if run("cat-file", "-e", f"{commit}^{{commit}}").returncode:
                        raise Refused(f"git cannot read {repo} commit {commit[:12]}: it is not in this host's mirror "
                                      f"or cache, and `{fetch}` did not bring it ({why or 'it ran clean'}); run "
                                      "that fetch, then judge again")
        # Present is not complete: git_commit fills this cache one commit deep (`--depth=1`), so both commits can be
        # here with their parents cut off, and merge-base or merge-tree then reads two unrelated histories (cmux#41386
        # F1). Any shallow boundary may cut this merge's history, so the cache is made whole first, or nothing is said.
        unshallow()
        if run("merge-base", "--is-ancestor", head, tip).returncode == 0:
            done = run("rev-parse", f"{head}^{{tree}}")
            merged = done.stdout.strip() if not done.returncode else ""
        else:
            done = run("merge-tree", "--write-tree", "--no-messages", "--name-only", tip, head)
            lines = done.stdout.splitlines()
            if done.returncode == 1 and lines and HEX40.fullmatch(lines[0]):
                files = [line for line in lines[1:] if line]
                raise Refused(f"{head[:12]} does not merge cleanly with the base tip {tip[:12]} (conflicts in: "
                              f"{', '.join(files[:5]) or 'unknown'}): no run tested the tree a squash would make")
            merged = lines[0] if not done.returncode and lines else ""
        if shallow():  # another reader's one-commit fetch cut the history while this merge read it
            raise Refused(f"git's {repo} cache went shallow while {head[:12]} was merged with {tip[:12]}; judge again")
        if not HEX40.fullmatch(merged):
            raise Refused(f"git cannot merge {head[:12]} with {tip[:12]}: {done.stderr.strip()[-200:] or 'no tree'}")
        if whole:  # a broker local run tests the merged tree uncut (local_kept_run)
            return merged
        shown = run("show", f"{merged}:{WS_CHECK_HOSTS_FILE}")
        try:
            entry = (json.loads(shown.stdout).get("fast_checks_hosts") or {}).get(repo) if not shown.returncode else None
        except (ValueError, AttributeError):
            entry = None
        paths = entry.get("paths") if isinstance(entry, dict) else None
        if not (isinstance(paths, list) and paths and all(isinstance(path, str) and path for path in paths)):
            raise Refused(f"{head[:12]} merged with {tip[:12]} names no {repo} paths in {WS_CHECK_HOSTS_FILE}")
        keep = [listed for path in paths if (listed := run("ls-tree", merged, "--", path).stdout.strip())]
        made = run("mktree", text="\n".join(keep) + "\n") if keep else None
        cut = made.stdout.strip() if made is not None and not made.returncode else ""
    except (OSError, subprocess.SubprocessError) as error:
        raise Refused(f"git cannot merge {head[:12]} with {tip[:12]}: {type(error).__name__}: {error}"[:300]) from None
    if not HEX40.fullmatch(cut):
        raise Refused(f"{head[:12]} merged with {tip[:12]} has none of {', '.join(paths)}")
    return cut


def ws_check_tested_tree(repo: str, base: str, sha: str, snapshot: dict, tips, github=None) -> str:
    """The BASE commit the head SHA's snapshot run (SNAPSHOT: {"run", "tree"}, ws_check_verdict) tested SHA against: the
    newest of TIPS (BASE's commits newest first, or one sha) whose pinned squash with SHA (ws_check_squash_tree) makes
    the tree the run tested, compared by tree id only. The tip is tried first, and a run that tested an older tip is
    still a verdict on the tree that tip made: ws_check_red holds its red against that same commit and the ones before
    it, never a newer one. Refused when the run names no tree, or no commit in TIPS makes its tree: that run tested
    another head, or a base older than the window, and is no verdict on SHA.

    A single tip is not enough: a base that moves faster than one run of its own checks can never be matched by its tip
    (2026-11-24, leo-workspace main: 16.8 merges/hour, median gap 104 s, 99.7% of gaps under one 2000 s ws-check run),
    so every head was refused "it tested another base or head" and the remedy that refusal names (merge the base in and
    run again) could never finish either."""
    where = f"'{WS_CHECK}' on {sha}: run {snapshot.get('run')}"
    tested = snapshot.get("tree")
    if not (isinstance(tested, str) and HEX40.fullmatch(tested)):
        raise Refused(f"{where} names no tested tree in its receipt, so it cannot be held to {sha[:12]} merged with "
                      f"{base}")
    if isinstance(tips, str):
        tips = [tips]
    window = [tip for tip in tips[:WS_CHECK_TESTED_TIPS] if isinstance(tip, str) and HEX40.fullmatch(tip)]
    if not window:
        raise Refused(f"{where}: {base} has no tip to merge {sha[:12]} with")
    WS_CHECK_BRANCHES[(repo, sha)] = lambda: ws_check_branches(repo, base, sha, github)
    made, unread = [], []
    for tip in window:
        try:
            want = (ws_check_squash_tree(repo, sha, tip, whole=True) if snapshot.get("whole")
                    else ws_check_squash_tree(repo, sha, tip))
        except Refused as error:  # one commit git cannot merge is no verdict on the others
            unread.append(f"{tip[:12]}: {error}")
            continue
        if tested == want:
            return tip
        made.append(f"{tip[:12]} ({want[:12]})")
    if not made:
        raise Refused(f"{where}: {sha[:12]} merges with none of {base}'s {len(window)} newest commits, so its tested "
                      f"tree {tested[:12]} cannot be placed: {unread[0]}"[:400])
    raise Refused(f"{where} tested tree {tested[:12]}, not {sha[:12]} merged with any of {base}'s {len(window)} newest "
                  f"commits (tip {made[0]}, oldest tried {made[-1]}): it tested another base or head. Run ws-check "
                  f"again at this head")


def ws_check_status(repo: str, sha: str, github) -> dict | None:
    statuses = github.json(f"repos/{repo}/commits/{sha}/status?per_page=100").get("statuses") or []
    # The combined status lists the newest per context.
    return next((found for found in statuses if found.get("context") == WS_CHECK), None)


def ws_check_step(lines: list[str], end: int, step: str) -> dict:
    """{"tests", "lines", "failures" ({test: its failure text, unittest_failures'})} for red STEP, whose closing line
    is LINES[END]; Refused when its output cannot be read."""
    start = next((n for n in range(end - 1, -1, -1) if lines[n] in (f"##[group]{step}", f"::group::{step}")), None)
    if start is None:
        raise Refused(f"no '##[group]{step}' line before its result")
    section = [text for text in lines[start + 1:end] if text and text not in ("##[endgroup]", "::endgroup::")]
    code = WS_CHECK_STEP_EXIT.search(lines[end])
    if code is None:
        raise Refused(f"'{step}': its result line names no exit code")
    if int(code[1]) < 0 or int(code[1]) > 128:
        raise Refused(f"'{step}' exited {code[1]} (a signal): a crash is never a base red")
    if crashed := next((text for text in section if WS_CHECK_CRASH.search(text)), None):
        raise Refused(f"'{step}' crashed ({crashed[:200]}): a crash is never a base red")
    reds = [match[1] for text in section if (match := UNITTEST_RED.match(text))]
    counted = 0
    for text in section:
        if match := UNITTEST_SUMMARY.match(text):
            for part in match[1].split(","):
                key, _, value = part.strip().partition("=")
                if key in ("failures", "errors", "unexpected successes"):
                    counted += int(value) if value.isdigit() else 0
    if len(reds) != counted:
        raise Refused(f"'{step}' prints {len(reds)} FAIL/ERROR line(s) but its unittest summaries count {counted}; "
                      "its failing tests cannot be listed")

    def norm(text: str) -> str:
        return normalise_error(WS_CHECK_ROOT.sub("", text))

    own = {norm(text) for text in section if text.startswith("ws-check: ")}
    if not reds and not section:
        raise Refused(f"'{step}' failed with no failing test and no output to compare")
    failures: dict[str, set[str]] = {}
    for test, body in unittest_failures(section):
        failures.setdefault(test, set()).update(norm(text) for text in body)
    return {"tests": frozenset(reds), "lines": frozenset(own if reds else {norm(text) for text in section}),
            "failures": {test: frozenset(body) for test, body in failures.items()}}


def unittest_failures(section: list[str]) -> list[tuple[str, list[str]]]:
    """(test, its failure text) for each FAIL/ERROR block of a unittest run's SECTION (lines_of's lines, blanks
    dropped): the block's lines after its traceback's frames, up to the next separator. A lint test that lists its
    offenders fails with them in this text (its AssertionError and diff), so the base's red of that test is told apart
    from a head's red of it that lists a new offender (leo-workspace#5683)."""
    found: list[tuple[str, list[str]]] = []
    at = 0
    while at < len(section):
        match = UNITTEST_RED.match(section[at])
        at += 1
        if not match:
            continue
        if at < len(section) and UNITTEST_RULE.match(section[at]):  # the dashes under "FAIL: test"
            at += 1
        body: list[str] = []
        frames = False
        while at < len(section) and not UNITTEST_RULE.match(section[at]) and not UNITTEST_RED.match(section[at]):
            text = section[at]
            at += 1
            if text == "Traceback (most recent call last):":
                frames = True
            elif frames and UNITTEST_FRAME.match(text):
                # Its source line, when Python printed one, and the carets under it.
                if at < len(section) and not (UNITTEST_FRAME.match(section[at]) or UNITTEST_RAISED.match(section[at])
                                              or UNITTEST_RULE.match(section[at])):
                    at += 1
                while at < len(section) and UNITTEST_CARETS.match(section[at]):
                    at += 1
            else:
                frames = False
                body.append(text)
        found.append((match[1], body))
    return found


# 2026-11-18: land-judge refused teamleaderleo/leo-workspace#5992 at aa178907 twice as red_not_excused, "'ws-check' has
# no result: job 'checks' in run 44407040407 is completed/cancelled: no result to read". Since hq#12237 the lane-gh
# broker moves a ws-check run no Actions runner starts to the build fleet: it cancels the run (its one `checks` job
# ends cancelled with no steps) and runs the snapshot as a controller job, whose log prints the same WS_CHECK_RESULT
# and a FAST_CHECKS_RECEIPT naming the cancelled run (hq tools/lane-gh-broker/parts/43-calls-ci-fleet.py). The broker
# judges and posts the ws-check status from that log, linking the cancelled run, and keeps it beside the run's record
# in its state folder (ci/JID.json, ci/JID.fleet-log). Read only as GitHub's job, every fleet-route ws-check was "no
# result", never excusable. A broker land's land-judge runs on the broker host, so this reads the kept log there:
# the record must name this run as the one it moved (fleet.from_run) and this head (cmux#46667, leo-workspace#5376 at
# b2b09e79: a record of another head's run is never read), be settled done with the status's verdict, and the log's
# receipt must name the run again (ws_check_verdict). The standby broker's state is read too, after the primary's. Elsewhere, or once the record is pruned (the broker
# keeps settled records CI_RECORD_RETENTION_S, 6 h), it is "no result" as before: run ws-check again.
FLEET_RECORDS_ENV = "BASE_RED_FLEET_RECORDS"  # the broker's ci records folder; default its state's (cfg "state")
FLEET_RECORDS_DEFAULT = Path(".local") / "state" / "lane-gh-broker" / "ci"
FLEET_RECORDS_STANDBY = Path(".local") / "state" / "lane-gh-broker-standby" / "ci"
FLEET_VERDICTS = {"failure": "failure", "success": "success"}  # status state: the record's conclusion


def fleet_records_dirs(env=os.environ) -> list[Path]:
    named = env.get(FLEET_RECORDS_ENV)
    if named:
        return [Path(named)]
    home = Path(env.get("HOME") or Path.home())
    return [home / FLEET_RECORDS_DEFAULT, home / FLEET_RECORDS_STANDBY]


def fleet_kept_log(repo: str, host: str, run: str, sha: str, state: str, env=os.environ) -> str | None:
    """The build-fleet log this host's lane-gh broker kept for REPO's ws-check run RUN (in HOST) of head SHA, the run
    it cancelled and moved to the fleet, when its record is settled done with the verdict STATE names; else None."""
    records = []
    for folder in fleet_records_dirs(env):
        try:
            records += sorted(folder.glob("*.json"))
        except OSError:
            continue
    for path in records:
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        fleet = record.get("fleet") if isinstance(record, dict) else None
        if not isinstance(fleet, dict) or str(fleet.get("from_run")) != str(run):
            continue
        if (fleet.get("state") != "done" or record.get("repo") != repo or record.get("dispatch") != host
                or str(record.get("run_id")) != str(run) or record.get("head") != sha
                or record.get("conclusion") != FLEET_VERDICTS.get(state) or record.get("mismatch")):
            return None
        try:
            text = path.with_name(f"{path.stem}.fleet-log").read_text(encoding="utf-8", errors="replace")
        except OSError:
            return None
        return text if text.strip() else None
    return None


# 2026-11-25: land-judge refused teamleaderleo/leo-workspace#10190 at c31fd01b as red_not_excused, "'ws-check' on
# c31fd01b...: its status links nothing, not a manaflow-ai/cmuxterm-hq Actions run". Since hq#15545 the lane-gh broker
# runs a leo-workspace head's ws-check on its own host when it has room (hq tools/lane-gh-broker/parts/43-calls-ci-
# local.py): no Actions run, a broker-owned run_id (LOCAL_RUN_BASE + n) and a lane-gh-broker:// url, and the status it
# posts links nothing (no http url to link). Read only as an Actions run, every such red was unclassifiable, and on a
# day the broker's host takes most heads, so was most of every PR's ws-check red. The broker keeps the run beside its
# record (ci/JID.json, ci/JID.local-log) exactly as a fleet run's, and a broker land's land-judge runs on that host, so
# this reads it there (fleet_records_dirs): the record must be settled done, of this repo and head, with the status's
# verdict and no mismatch, and its url must be this repo's local-run url; the log's receipt (written by the broker, not
# the run) must name that run and snapshot, say lane-gh-broker-local, and name the record's merged tree. A local run
# tests the whole merged tree (ci_merged_tree, uncut), so ws_check_tested_tree holds it to the uncut squash.
LOCAL_RUN_BASE = 4_000_000_000_000_000  # hq CI_LOCAL_RUN_BASE, leo-workspace tools/ws-check LOCAL_RUN_BASE
LOCAL_RUN_URL = r"lane-gh-broker://[\w.-]+/{repo}/local-runs/(\d+)"  # hq CI_LOCAL_URL_RE, for one repo
LOCAL_RAN_ON = "lane-gh-broker-local"  # hq CI_LOCAL_RAN_ON


def local_kept_run(repo: str, sha: str, state: str, url: str = "", env=os.environ) -> dict | None:
    """{"run_id", "snapshot", "tree", "log"} of the ws-check run this host's lane-gh broker ran itself (no Actions run)
    for REPO's head SHA, when its record is settled done with the verdict STATE names, no mismatch, and (when the status
    links one, URL) that run's url; the newest such run. None when this host keeps none (or the status links another)."""
    pattern = LOCAL_RUN_URL.format(repo=re.escape(repo))
    if url and not re.fullmatch(pattern, url):
        return None
    found = []
    for folder in fleet_records_dirs(env):
        try:
            records = sorted(folder.glob("*.json"))
        except OSError:
            continue
        for path in records:
            try:
                record = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            local = record.get("local") if isinstance(record, dict) else None
            run_id = record.get("run_id") if isinstance(local, dict) else None
            if (not isinstance(run_id, int) or isinstance(run_id, bool) or run_id < LOCAL_RUN_BASE
                    or local.get("state") != "done" or record.get("repo") != repo or record.get("head") != sha
                    or record.get("conclusion") != FLEET_VERDICTS.get(state) or record.get("mismatch")
                    or not re.fullmatch(pattern, str(record.get("url") or ""))
                    or (url and record.get("url") != url)
                    or not (isinstance(record.get("snapshot"), str) and HEX40.fullmatch(record["snapshot"]))
                    or not (isinstance(record.get("tree"), str) and HEX40.fullmatch(record["tree"]))):
                continue
            try:
                text = path.with_name(f"{path.stem}.local-log").read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            if text.strip():
                found.append({"run_id": str(run_id), "snapshot": record["snapshot"], "tree": record["tree"],
                              "log": text, "ended": str(record.get("ended") or "")})
    # The newest run of this head: the status the broker posts last is its last run's.
    return max(found, key=lambda run: (run["ended"], int(run["run_id"])), default=None)


def ws_check_verdict(repo: str, sha: str, github) -> tuple[str, dict]:
    """(kind, verdict) of SHA's ws-check status: kind "none" (no result), "pass" or "fail". A fail's verdict has
    "steps" ({step: {"tests", "lines", "failures" ({test: its failure text})}}), "url" and "at" (the status time);
    Refused when a failure cannot be read."""
    status = ws_check_status(repo, sha, github)
    if status is None:
        return "none", {"why": "no ws-check status"}
    state, description = status.get("state"), status.get("description") or ""
    found = {"url": status.get("target_url") or "", "at": status.get("updated_at") or status.get("created_at") or ""}
    if state in ("pending", "error"):
        return "none", dict(found, why=f"ws-check is {state} ({description or 'no description'})")
    if state == "success":
        return "pass", found
    where = f"'{WS_CHECK}' on {sha}"
    if state != "failure":
        raise Refused(f"{where}: an unknown status state {state!r}")
    named = WS_CHECK_DESCRIPTION.fullmatch(description) or WS_CHECK_LONG_DESCRIPTION.fullmatch(description)
    if not named:
        raise Refused(f"{where}: failure \"{description}\" names no failed steps; only 'N of M steps failed: ...' or "
                      "'N failed after discounting K on main SHA8: UNIT' is read per test")
    host = WS_CHECK_REPOS[repo]
    link = re.fullmatch(r"https://github\.com/" + re.escape(host) + r"/actions/runs/(\d+)(?:/job/\d+)?/?"
                        + WS_CHECK_FLEET_JOB, found["url"])
    fleet = kept = local = None
    if not link:
        # No Actions run: the lane-gh broker ran it on its own host (local_kept_run), and kept its log there.
        local = local_kept_run(repo, sha, state, found["url"])
        if local is None:
            raise Refused(f"{where}: its status links {found['url'] or 'nothing'}, not a {host} Actions run, and this "
                          f"host's lane-gh broker keeps no settled local run of {sha[:12]} ending {state} "
                          "(local_kept_run: read on the broker host, within its record retention)")
        link = (found["url"], local["run_id"], None)
    if local is not None:
        run, lines = {}, lines_of(local["log"])
    else:
        run = github.json(f"repos/{host}/actions/runs/{link[1]}")
        jobs = last_real_jobs(host, int(link[1]), github)
        # fleet-reconciler-ws-check.yml runs one check job per head, named for it; fast-checks.yml runs one, `checks`.
        picked = ([job for job in jobs if sha in (job.get("name") or "")]
                  or [job for job in jobs if job.get("name") == "checks"])
        if len(picked) != 1:
            raise Refused(f"{where}: run {link[1]} has {len(picked)} ws-check jobs for it, not one")
        job = picked[0]
    if local is not None:
        pass  # the broker's own receipt is held below, with the run's WS_CHECK_RESULT
    elif link[2]:
        # The build fleet ran it for the cancelled Actions job (WS_CHECK_FLEET_JOB): its log is the controller's.
        lines, fleet = ws_check_fleet_lines(where, link[1], run, job, link[2])
    else:
        if job.get("status") == "completed" and job.get("conclusion") == "cancelled":
            # The broker cancelled it and the build fleet ran its snapshot (fleet_kept_log): that log is the run's.
            kept = fleet_kept_log(repo, host, link[1], sha, state)
        if kept is None and (job.get("status") != "completed" or job.get("conclusion") not in ("success", "failure")):
            # No verdict (startup_failure, cancelled, still running): no result, skipped on the base (cmux#36219 F2).
            return "none", dict(found, why=f"job '{job.get('name')}' in run {link[1]} is {job.get('status')}/"
                                           f"{job.get('conclusion')}: no result to read"
                                           + (" (and this host keeps no build-fleet log for that run)"
                                              if job.get("conclusion") == "cancelled" else ""))
        lines = lines_of(kept) if kept is not None else lines_of(github.log(host, job))
        if kept is not None:
            # A log read off this host, not off GitHub: its receipt must name this run, whatever head it tested.
            receipt = next((text for text in reversed(lines) if text.startswith("FAST_CHECKS_RECEIPT=")), "")
            try:
                receipt = json.loads(receipt.split("=", 1)[1]) if receipt else {}
            except ValueError:
                receipt = {}
            if not (isinstance(receipt, dict) and str(receipt.get("run_id")) == link[1]
                    and receipt.get("ran_on") == "build-fleet"):
                raise Refused(f"{where}: the build-fleet log kept for run {link[1]} has no FAST_CHECKS_RECEIPT naming "
                              "that run")
    at = next((n for n in range(len(lines) - 1, -1, -1) if lines[n].startswith("WS_CHECK_RESULT=")), None)
    try:
        result = json.loads(lines[at].split("=", 1)[1]) if at is not None else None
    except ValueError:
        result = None
    failed = result.get("failed") if isinstance(result, dict) else None
    if (not isinstance(failed, list) or not failed or not all(isinstance(step, str) and step for step in failed)
            or result.get("ok") is not False or len(set(failed)) != len(failed)):
        raise Refused(f"{where}: run {link[1]} has no WS_CHECK_RESULT line listing its failed steps")
    if local is not None:
        # The broker always tests a snapshot commit of the head merged with its base, and writes the receipt itself.
        receipt = next((text for text in reversed(lines) if text.startswith("FAST_CHECKS_RECEIPT=")), "")
        try:
            receipt = json.loads(receipt.split("=", 1)[1]) if receipt else {}
        except ValueError:
            receipt = {}
        if not (isinstance(receipt, dict) and result.get("head") == local["snapshot"]
                and receipt.get("source_sha") == local["snapshot"] and receipt.get("head_after") == local["snapshot"]
                and str(receipt.get("run_id")) == link[1] and receipt.get("ran_on") == LOCAL_RAN_ON
                and receipt.get("source_tree") == local["tree"]):
            raise Refused(f"{where}: the log this host's broker kept for its local run {link[1]} has no "
                          f"FAST_CHECKS_RECEIPT naming that run, its snapshot {local['snapshot'][:12]} and tree")
        found["snapshot"] = {"run": link[1], "tree": local["tree"], "whole": True}
    elif result.get("head") != sha or fleet is not None:
        # Through cmux-ci the run tests a snapshot commit of the head: its own receipt must name that snapshot and run.
        # A fleet run's always does (the broker always tests a snapshot), and says it ran on that controller worker.
        receipt = next((text for text in reversed(lines) if text.startswith("FAST_CHECKS_RECEIPT=")), "")
        try:
            receipt = json.loads(receipt.split("=", 1)[1]) if receipt else {}
        except ValueError:
            receipt = {}
        if not (isinstance(receipt, dict) and result.get("head") and receipt.get("source_sha") == result.get("head")
                and str(receipt.get("run_id")) == link[1]
                and re.fullmatch(WS_CHECK_RUN_NAME.format(re.escape(str(result.get("head")))),
                                 run.get("display_title") or "")):
            raise Refused(f"{where}: the WS_CHECK_RESULT of run {link[1]} is from another checkout")
        if fleet is not None and (receipt.get("ran_on") != "build-fleet" or not fleet.get("worker")
                                  or receipt.get("fleet_host") != fleet.get("worker")):
            raise Refused(f"{where}: the receipt in fleet job {link[2]}'s log says it ran on "
                          f"{receipt.get('ran_on')}/{receipt.get('fleet_host')}, not on that job's worker "
                          f"{fleet.get('worker')}")
        # Which checkout or runner ran it says nothing; what it tested does. A head's snapshot run is held to its tree
        # (ws_check_red: the head merged with the base tip, ws_check_squash_tree); a base commit's is read as before.
        found["snapshot"] = {"run": link[1], "tree": receipt.get("source_tree")}
    if not ws_check_described(named, failed, result.get("steps"), lines, at):
        raise Refused(f"{where}: its status (\"{description}\") does not match run {link[1]}'s WS_CHECK_RESULT")
    # The run's own base pass, kept for ws_check_own_base_excuse: the units it saw fail in main's tree too.
    own_base = ws_check_own_base(lines, at, failed)
    if own_base is not None:
        found["own_base"] = own_base
    steps = {}
    for step in failed:
        if step == WS_CHECK_GIT_CONFIG_STEP:
            # No step line: the run's own line says it, one fact with no tests (its path and first watcher vary).
            if not any(line.startswith(WS_CHECK_GIT_CONFIG_LINE) for line in lines[:at]):
                raise Refused(f"{where}: run {link[1]} has no '{WS_CHECK_GIT_CONFIG_LINE}' line")
            steps[step] = {"tests": frozenset(), "lines": frozenset({WS_CHECK_GIT_CONFIG_LINE}), "failures": {},
                           "suites": frozenset({""}), "line_suites": {}}
            continue
        # The step's red result lines, one per red unit ("STEP" alone from a runner before units, else "STEP [UNIT]"),
        # each read in its own group; the step's tests and lines are every red unit's together.
        result = re.compile(re.escape(f"ws-check step FAILED: {step}") + f"({WS_CHECK_UNIT})" + r" \(exit ")
        ends = [(n, m[1]) for n in range(at) if (m := result.match(lines[n]))]
        if not ends:
            raise Refused(f"{where}: run {link[1]} has no 'ws-check step FAILED: {step}' line")
        tests, printed, failures, suites, line_suites = set(), set(), {}, set(), {}
        try:
            for end, unit in ends:
                red = ws_check_step(lines, end, step + unit)
                # A test is named with its unit's suite ("[test_new.py] test_check (__main__.FastForward.test_check)"):
                # every suite runs as __main__, so two suites' same-named tests read alike and one's red on the base
                # excused the other's on the head (cmux#41298 F1). A shard number ("2/4") is dropped, since shards move.
                suite = WS_CHECK_SHARD.sub("", unit.strip()[1:-1]) if unit else ""
                tests |= {f"[{suite}] {test}" if suite else test for test in red["tests"]}
                printed |= red["lines"]
                suites.add(suite)
                for line in red["lines"]:
                    line_suites.setdefault(line, set()).add(suite)
                for test, body in red["failures"].items():
                    failures.setdefault(f"[{suite}] {test}" if suite else test, set()).update(body)
        except Refused as error:
            raise Refused(f"{where}: run {link[1]}: {error}") from None
        # "suites": the step's red units by suite ("" for a step not split into units), and "line_suites" which units
        # printed each line: ws_check_red's per-suite base red (ws_check_suite_touched) reads them.
        steps[step] = {"tests": frozenset(tests), "lines": frozenset(printed),
                       "failures": {test: frozenset(body) for test, body in failures.items()},
                       "suites": frozenset(suites), "line_suites": {line: frozenset(s) for line, s in line_suites.items()}}
    return "fail", dict(found, steps=steps)


def failure_text(verdict: dict, step: str, test: str) -> frozenset:
    """TEST's failure text (normalised lines) in STEP of a ws_check_verdict fail VERDICT; empty when none was read."""
    return verdict["steps"].get(step, {}).get("failures", {}).get(test, frozenset())


def ws_check_step_keys(verdict: dict, step: str) -> list[str]:
    """The VERDICT step key(s) a head's STEP is compared against. A step label names a workflow step, not a failure's
    identity: a PR that renames, splits or shards a step moves every unit key with it (leo-workspace#10806 split one
    catch-all step into 1130 of them), and keyed on the label alone the base's own red stops matching and reads as the
    head's own red (13 land stops on 2026-11-25, every one naming that split step). With the head's label on the
    verdict, that label alone; without it, every step the verdict has - a failure is still matched by test name and
    failure text there, so the base's red is found wherever the base ran it."""
    return [step] if step in verdict.get("steps", {}) else sorted(verdict.get("steps", {}))


def ws_check_step_key(verdict: dict, step: str, test: str) -> str:
    """The one VERDICT step key to read TEST's failure text from (ws_check_step_keys): STEP when the verdict has it,
    else the step that ran TEST, else STEP (no failure text)."""
    keys = ws_check_step_keys(verdict, step)
    return next((key for key in keys if test in verdict["steps"][key]["tests"]), step)


def ws_check_units(steps: dict) -> list[tuple[str, str, str]]:
    """(step, kind, item) for each thing a red must match on the base: each failing test, and each compared line."""
    return [(step, "test", test) for step, red in steps.items() for test in sorted(red["tests"])] + [
        (step, "line", line) for step, red in steps.items() for line in sorted(red["lines"])]


def ws_check_fix_untouched(repo: str, base: str, sha: str, merge_base: str, passed: str, github) -> None:
    """Refused unless the PR (BASE...SHA) changes none of the paths changed from MERGE_BASE to the base pass PASSED,
    when PASSED is after MERGE_BASE (a pass before it ended nothing the merge-base fallback crosses)."""
    fix = github.json(f"repos/{repo}/compare/{merge_base}...{passed}")
    if fix.get("status") == "behind":
        return
    where = f"'{WS_CHECK}': {base} passed at {passed[:12]}, after this PR's merge-base {merge_base[:12]}"
    if fix.get("status") != "ahead":
        raise Refused(f"{where}? GitHub compares them as {fix.get('status')!r}; nothing shows the fix stays intact")
    pr = github.json(f"repos/{repo}/compare/{base}...{sha}")

    def paths(diff: dict, what: str) -> set[str]:
        files = diff.get("files")
        if not isinstance(files, list) or len(files) >= COMPARE_FILES_CAP:
            raise Refused(f"{where}: {what} lists {len(files) if isinstance(files, list) else 'no'} files, too many "
                          "or none to show this PR leaves the fix alone")
        return {path for found in files for path in (found.get("filename"), found.get("previous_filename"))
                if isinstance(path, str) and path}

    if hit := sorted(paths(fix, "the fix") & paths(pr, "this PR")):
        raise Refused(f"{where} (fixed on {base}), and this PR changes what that fix changed: {'; '.join(hit[:5])}; "
                      f"merge {base}")


class FixedOnBase(Refused):
    """A ws-check red that ws_check_red calls "fixed_on_base": still refused, since the PR needs CI at a head that has
    the fix, but said as "fixed on base by <commit>: update the branch", never as "not excused" (main prints it as it
    is)."""


# 2026-11-11: land-judge refused teamleaderleo/leo-workspace#4199 at e31e643a with "not excused: 'ws-check' is green on
# main e5a6bed1b950, red on e31e643a6b26; not excused 'ws-check' test ...". Its one red, test_knowledge_tiers.py's
# leo-asks room test, failed the same way at its merge-base e8873054 and was fixed on main by LW#4196; the PR touched
# only tools/lane-gh. Main's newest verdict was a pass, and nothing past it was read, so a base red main had since fixed
# read as the PR's own. Now a pass at or after the merge-base reads the merge-base's own verdict: when it failed every
# test and line the head fails, the verdict is "fixed_on_base", named by the first green base commit after the
# merge-base (best effort: the oldest green among the WS_CHECK_COMMITS read, back to the merge-base). ws_check_red is
# the one verdict: land-judge's message comes from it (judge, through ws_check), and the lane-gh broker's
# update_branch guard reads it (--ws-check-verdict) to let a SHIP'd PR's base merge through only for "fixed_on_base".
# Its kinds: "pass" (the head is green), "base_red" (every failure is red on the base too: excused), "fixed_on_base",
# "head_only" (a failure the base does not show: the head's own red, or a flake the classifier cannot tell from one),
# and "base_stale" (the base's newest verdict, a pass, is before the merge-base: re-check later).
WS_CHECK_KINDS = ("pass", "base_red", "fixed_on_base", "head_only", "base_stale")


def ws_check(repo: str, base: str, sha: str, github, evidence: "Evidence | None" = None) -> list[str]:
    """Audit lines excusing SHA's red ws-check status, one per failing test; Refused (with a line per test) else, and
    FixedOnBase for a red the base has fixed since the PR's merge-base. The verdict is ws_check_red's."""
    verdict = ws_check_red(repo, base, sha, github, evidence)
    if verdict["kind"] in ("pass", "base_red"):
        return verdict["audit"]
    raise (FixedOnBase if verdict["kind"] == "fixed_on_base" else Refused)(verdict["message"])


def ws_check_fix(repo: str, merge_base: str, tip: str, commits: list[str], github) -> str:
    """The first base commit after MERGE_BASE whose ws-check status is a success: COMMITS (the base's, newest first)
    walked back to MERGE_BASE, one status read each (no log). Best effort: when MERGE_BASE is not among them, the
    oldest green one read; TIP (the base's newest verdict, a pass) when none reads green."""
    fix = tip
    for commit in commits:
        if commit == merge_base:
            break
        status = ws_check_status(repo, commit, github)
        if status is not None and status.get("state") == "success":
            fix = commit
    return fix


def ws_check_base_verdict(repo: str, commit: str, github) -> tuple[str, dict]:
    """ws_check_verdict of a base COMMIT in the window the head is compared with (never the merge-base, whose read
    stays strict), with a failure whose log cannot be read as "none" (no verdict): it only takes
    evidence away, so the comparison goes on to the base's other verdicts. Before this one unreadable main verdict
    refused every head: 2026-11-24, main 106d10145c's run 45341598629 kept only the last 200 lines of its red
    test_demand_scaler.py (leo-workspace tools/ws_check_collect.py quiet), 16 of 17 FAIL lines, and every
    leo-workspace PR was refused "its failing tests cannot be listed" on main's run, not its own."""
    try:
        return ws_check_verdict(repo, commit, github)
    except Refused as error:
        return "none", {"why": f"its verdict cannot be read ({str(error)[:300]})", "url": "", "unreadable": True}


# 2026-11-24: 11 of 27 land-judge overrides in 9 h were leo-workspace heads whose ws-check was red only in suites the
# PR did not touch, suites red on main too (lw#10075 at e1457204: "ws-check reds are unrelated base reds (git env,
# guards, land_judge_engine); the changed suite test_pr_hour passed 34/34 in the same run"). Read per test, those reds
# were "failing another way there" (a tmp path, a list's order, a subprocess timeout) or a test main's red suite did
# not fail this time, so the head's red read as its own. Rulebook [base-red-not-yours]: "A red failing the same way
# on base is not yours". A failing unit of a step split into suites ("STEP [test_x.py]") is now excused as a whole
# when main's newest readable ws-check verdict (the window's tip, no unreadable verdict newer) fails the same step's
# same suite and this PR changes none of that suite's files (ws_check_suite_touched), the way an Actions job red on the
# base is the base's. A step not split into suites (a lint, a whole-step test) is still read per test and per line:
# its new offender is the head's own. Unreadable main verdict or PR diff: no per-suite excuse (fail closed).
WS_CHECK_UNREPORTED = "no WS_CHECK_RESULT line: the checks did not report"  # tools/ws-check's words for a cut run


def ws_check_test_suite(test: str) -> str:
    """The suite a ws_check_verdict test name carries ("[test_x.py] test_a (...)" -> "test_x.py"), "" when none."""
    return test[1:test.index("] ")] if test.startswith("[") and "] " in test else ""


def ws_check_suite_touched(suite: str, paths: "list[str] | None") -> bool:
    """Whether a PR changing PATHS (None: unread) changes SUITE (a tools/test_x.py suite's file name): the suite
    itself, or the module it is named for (x.py, x/, x-cli), anywhere. Unread paths count as touched."""
    if paths is None:
        return True
    stem = Path(suite).stem
    names = {stem, stem.removeprefix("test_"), stem.removeprefix("test_").replace("_", "-")} - {""}
    return any(Path(path).stem in names or names & set(Path(path).parts[:-1]) for path in paths)


def ws_check_names_paths(lines, paths: list[str]) -> bool:
    """Whether any of LINES (normalised failure text) names one of PATHS, by path or file name, raw or normalised."""
    names = {form for path in paths for name in (path, Path(path).name) for form in (name, normalise_error(name))
             if len(name) > 3}
    return any(name in line for line in lines for name in names)


def ws_check_own_base_excuse(base: str, sha: str, units: list, head: dict, changed, unreadable: list[str]
                            ) -> dict | None:
    """The verdict excusing SHA's red ws-check by its own run's base pass, for a BASE no commit of which carries a
    ws-check verdict to compare with; None when that evidence does not cover every red, so the caller refuses as
    before. Since leo-workspace#9404 a run reruns its failed units in main's tree and tools/ws-check discounts those
    that fail there too (discount_base_reds): a unit red in main's tree was red without this PR's changes in it, the
    same fact a base commit's red verdict carries, read off the head's own run. Held to what the per-suite base red
    is held to: every red unit names a suite the rerun saw fail on main, no shard of that suite passed there, and the
    PR changes none of the suite's files (ws_check_suite_touched; unread paths count as touched). A red unit with no
    suite (a lint, a whole step) is never excused this way: its new offender would be the head's own.
    2026-11-25: lw#8742 at 712f2b07 was refused "none of the 30 newest main commits has a ws-check verdict to compare
    with" though its own run had rerun every red (test_reach.py shards the PR does not touch) in main's tree and seen
    them fail there."""
    own = head.get("own_base")
    if not own:
        return None

    def suites_of(labels) -> dict:
        """{step: the suites of its labels}, a label being "STEP [UNIT]"; a label naming no unit is dropped."""
        found: dict = {}
        for label in labels:
            step, bracket, unit = label.partition(" [")
            if bracket and unit.endswith("]") and step in head["steps"]:
                found.setdefault(step, set()).add(WS_CHECK_SHARD.sub("", unit[:-1]).strip())
        return found

    on_main, head_only = suites_of(own["on_main"]), suites_of(own["head_only"])
    excused = {step: suites - head_only.get(step, set()) for step, suites in on_main.items()}
    for step, kind, item in units:
        suites = ({ws_check_test_suite(item)} if kind == "test"
                  else head["steps"][step].get("line_suites", {}).get(item, frozenset()))
        if not suites or not all(suite and suite in excused.get(step, ()) for suite in suites):
            return None
        if any(ws_check_suite_touched(suite, changed()) for suite in suites):
            return None
    named = sorted(f"{step} [{suite}]" for step, suites in excused.items() for suite in suites)
    seen = f"red in {base} {own['main'][:12]}'s tree too, in this run's own base pass"
    said = (f"excused '{WS_CHECK}': every failure on {sha[:12]} is {seen} ({len(named)} unit(s) whose suites this PR "
            f"does not touch: {', '.join(named)[:300]}); no {base} commit in the window has a ws-check verdict to "
            "compare with"
            + (f" ({len(unreadable)} unreadable, first {unreadable[0]})" if unreadable else ""))
    audit = [said]
    audit += [f"excused '{WS_CHECK}' test '{step} :: {test}': {seen}"
              for step, red in head["steps"].items() for test in sorted(red["tests"])]
    audit += [f"excused '{WS_CHECK}' step '{step}' (no test names): {seen}"
              for step, red in head["steps"].items() if not red["tests"]]
    return {"kind": "base_red", "fix": "", "message": said, "audit": audit}


def ws_check_red(repo: str, base: str, sha: str, github, evidence: "Evidence | None" = None) -> dict:
    """The one verdict on SHA's ws-check status against BASE: {"kind" (one of WS_CHECK_KINDS), "fix" (the fixing base
    commit, for "fixed_on_base", else ""), "message" (what a refusal says), "audit" (the lines an excuse prints)}.
    Refused when a status or log cannot be read, or the head has no result: never guessed. The base commits are
    EVIDENCE's (Evidence.status_commits: a stacked parent's head alone)."""
    kind, head = ws_check_verdict(repo, sha, github)
    if kind == "none":
        raise Refused(f"'{WS_CHECK}' has no result on {sha}: {head['why']}; never excused, wait for its verdict")
    if kind == "pass":
        # No failure is exit 0 (NoFailureExitsZero): a merge check may ask about every head, green ones included.
        said = f"'{WS_CHECK}' passed on {sha}: no failure to excuse"
        return {"kind": "pass", "fix": "", "message": said, "audit": [said]}
    units = ws_check_units(head["steps"])
    evidence = evidence or Evidence(repo, base, github)
    merge_base = evidence.merge_base(sha)
    commits = evidence.status_commits(WS_CHECK_COMMITS)
    if head.get("snapshot"):
        # The run tested the head on one of the base's commits, not always its tip: compare with that commit and the
        # ones before it. A newer base commit never tested this tree, and could only have fixed what the run found.
        anchor = ws_check_tested_tree(repo, base, sha, head["snapshot"], commits, github)
        commits = commits[commits.index(anchor):]
    pr_paths: list = []  # [the PR's changed paths, or None when unread], read once on the first suite asked about
    def changed() -> "list[str] | None":
        if not pr_paths:
            try:
                files = github.json(f"repos/{repo}/compare/{base}...{sha}").get("files")
            except Refused:
                files = None
            ok = isinstance(files, list) and 0 < len(files) < COMPARE_FILES_CAP
            pr_paths.append(sorted({path for found in files for path in (found.get("filename"),
                                                                          found.get("previous_filename"))
                                    if isinstance(path, str) and path}) if ok else None)
        return pr_paths[0]

    unreadable: list[str] = []

    def readable(found: tuple) -> bool:
        if found[1] == "none" and found[2].get("unreadable"):
            unreadable.append(f"{found[0][:12]}: {found[2]['why']}")
        return found[1] != "none"
    verdicts = ((commit, *ws_check_base_verdict(repo, commit, github)) for commit in commits)
    verdicts = (found for found in verdicts if readable(found))
    newest = next(verdicts, None)
    if newest is None:
        own = ws_check_own_base_excuse(base, sha, units, head, changed, unreadable)
        if own is not None:
            return own
        raise Refused(f"'{WS_CHECK}': none of the {WS_CHECK_COMMITS} newest {base} commits has a ws-check verdict to "
                      "compare with" + (f" ({len(unreadable)} unreadable, first {unreadable[0]})" if unreadable else ""))
    tip, tip_kind, tip_verdict = newest
    tested = f"{base} {tip[:12]} ({tip_verdict['url'] or 'no run'})"
    # The tip is main's latest finished verdict unless a newer one finished but went unread (fail closed); a run that
    # never reported (timed out before its WS_CHECK_RESULT) never finished, so it hides nothing.
    tip_fresh = all(WS_CHECK_UNREPORTED in why for why in unreadable)

    def has(verdict: dict, unit) -> bool:
        step, kind, item = unit
        reds = [verdict["steps"][key] for key in ws_check_step_keys(verdict, step)]
        if not reds:
            return False
        if kind != "test":
            return any(item in red["lines"] for red in reds)
        # A failing test is the base's red only when it fails there the same way: every line of its failure text
        # (normalised: numbers masked, file names kept) is in the base's failure of that test. 2026-11-17:
        # leo-workspace#5683 at 16b96c09 merged with its test_text_io_encoding.py red excused by name, main d240eaab
        # failing that test too, though the head's failure listed a new offender (tools/test_merge_hold.py) main's
        # did not.
        return any(item in red["tests"] and failure_text(head, step, item) <= red["failures"].get(item, frozenset())
                   for red in reds)

    if tip_kind == "pass":
        header = f"'{WS_CHECK}' is green on {base} {tip[:12]}, red on {sha[:12]}\n"
        after = (merge_base == tip or (re.fullmatch(r"[0-9a-f]{40}", merge_base) and github.json(
            f"repos/{repo}/compare/{merge_base}...{tip}?per_page=1").get("status") in ("ahead", "identical")))
        if not after:
            why = (f"the newest {base} verdict, a pass at {tested}, is before the merge-base {merge_base[:12]}; "
                   f"re-check once a {base} commit at or after it has a ws-check verdict")
            lines = [f"not excused '{WS_CHECK}' test '{step} :: {test}': {why}"
                     for step, red in head["steps"].items() for test in sorted(red["tests"])]
            lines += [f"not excused '{WS_CHECK}' step '{step}' (no test names): {why}"
                      for step, red in head["steps"].items() if not red["tests"]]
            return {"kind": "base_stale", "fix": "", "message": header + "\n".join(lines), "audit": []}
        # The merge-base's own verdict: a red it shares is a base red the base has fixed since (LW#4199).
        mb_kind, mb_verdict = ("pass", {}) if merge_base == tip else ws_check_verdict(repo, merge_base, github)
        mb = merge_base[:12]
        if mb_kind == "fail" and all(has(mb_verdict, unit) for unit in units):
            fix = ws_check_fix(repo, merge_base, tip, commits, github)
            seen = (f"red at this PR's merge-base {mb} too ({mb_verdict['url'] or 'no run'}), green on {base} at "
                    f"{fix[:12]}")
            lines = [f"fixed on base '{WS_CHECK}' test '{step} :: {test}': {seen}"
                     for step, red in head["steps"].items() for test in sorted(red["tests"])]
            lines += [f"fixed on base '{WS_CHECK}' step '{step}' (no test names): {seen}"
                      for step, red in head["steps"].items() if not red["tests"]]
            said = (f"fixed on base by {fix[:12]}: update the branch: '{WS_CHECK}' on {sha[:12]} fails the same way "
                    f"as at this PR's merge-base {mb}, and {base} is green since {fix[:12]} (newest verdict a pass at "
                    f"{tested}); the PR needs CI at a head that has the fix\n")
            return {"kind": "fixed_on_base", "fix": fix, "message": said + "\n".join(lines), "audit": []}
        newest_pass = f"passes on {tested}, the newest {base} verdict"
        note = (f"{newest_pass}; the merge-base {mb} has no ws-check verdict ({mb_verdict.get('why')}), so whether it "
                f"was red there is unknown: merge {base}") if mb_kind == "none" else ""

        def why(unit_list) -> str:
            if note:
                return note
            if mb_kind == "fail" and all(has(mb_verdict, unit) for unit in unit_list):
                return (f"red at this PR's merge-base {mb} too and fixed on {base}, but this head has a red of its "
                        "own besides")
            return f"{newest_pass}, and not red at this PR's merge-base {mb}; this head's own red"
        lines = [f"not excused '{WS_CHECK}' test '{step} :: {test}': {why([(step, 'test', test)])}"
                 for step, red in head["steps"].items() for test in sorted(red["tests"])]
        lines += [f"not excused '{WS_CHECK}' step '{step}' (no test names): "
                  f"{why([(step, 'line', line) for line in red['lines']])}"
                  for step, red in head["steps"].items() if not red["tests"]]
        return {"kind": "head_only", "fix": "", "message": header + "\n".join(lines), "audit": []}
    window, when = [(tip, tip_verdict)], created({"created_at": tip_verdict["at"]})
    at_merge_base: list[tuple[str, dict]] = []

    def on(unit) -> tuple[str, dict] | None:
        return next(((commit, verdict) for commit, verdict in window + at_merge_base if has(verdict, unit)), None)

    def older() -> str:
        return f" or the {len(window) - 1} red {base} verdict(s) before it" if len(window) > 1 else ""

    def mb_note() -> str:
        return f" or at the merge-base {merge_base[:12]}" if at_merge_base else ""

    by_suite_seen: set[tuple[str, str]] = set()

    def by_suite(step: str, suites, new=()) -> bool:
        """Whether every unit of STEP in SUITES is a per-suite base red: red on the tip too, untouched by the PR, and
        none of the head's lines NEW that the tip does not print names a path the PR changes (a repo-wide lint test's
        new offender, leo-workspace#5683: its suite red on main too, its new line naming the PR's own file)."""
        ok = bool(suites) and tip_fresh and all(
            suite and any(suite in tip_verdict["steps"].get(key, {}).get("suites", ())
                          for key in ws_check_step_keys(tip_verdict, step)) for suite in suites)
        if ok and (any(ws_check_suite_touched(suite, changed()) for suite in suites)
                   or ws_check_names_paths(new, changed() or [])):
            return False
        if ok:
            by_suite_seen.update((step, suite) for suite in suites)
        return ok

    def suite_said(step: str, suites) -> str:
        return (f"its suite(s) {', '.join(sorted(suites))} red on {tested} too, and this PR changes none of their "
                "files: a per-suite base red")

    passed_at = ""  # the base pass that ended the window, if one did
    while any(on(unit) is None for unit in units) and len(window) < BASE_WINDOW:
        before = next(verdicts, None)
        if before is None or before[1] != "fail":
            passed_at = before[0] if before is not None and before[1] == "pass" else ""
            break
        then = created({"created_at": before[2]["at"]})
        if when and then and when - then > timedelta(hours=BASE_WINDOW_HOURS):
            break
        window.append((before[0], before[2]))
    if (any(on(unit) is None for unit in units) and re.fullmatch(r"[0-9a-f]{40}", merge_base)
            and merge_base not in (commit for commit, _ in window)):
        mb_kind, mb_verdict = ws_check_verdict(repo, merge_base, github)
        if mb_kind == "fail":
            if passed_at:
                ws_check_fix_untouched(repo, base, sha, merge_base, passed_at, github)
            at_merge_base.append((merge_base, mb_verdict))
    lines, missing = [], []

    def where(found: tuple[str, dict]) -> str:
        crossed = (f" (fixed on {base} at {passed_at[:12]} after it; this PR changes none of that fix's paths)"
                   if passed_at else "")
        return (f"red at this PR's merge-base {found[0][:12]} too{crossed}, so not this PR's red"
                if at_merge_base and found[0] == at_merge_base[0][0] else f"red on {base} {found[0][:12]} too")
    for step, red in head["steps"].items():
        # One line per failing test; a step with none (a lint) is one line, matched by every line it printed.
        for test in sorted(red["tests"]):
            if (found := on((step, "test", test))) is not None:
                lines.append(f"excused '{WS_CHECK}' test '{step} :: {test}': {where(found)} "
                             f"({found[1]['url'] or 'no run'})")
            elif by_suite(step, {ws_check_test_suite(test)},
                          failure_text(head, step, test)
                          - failure_text(tip_verdict, ws_check_step_key(tip_verdict, step, test), test)):
                lines.append(f"excused '{WS_CHECK}' test '{step} :: {test}': "
                             f"{suite_said(step, {ws_check_test_suite(test)})}")
            else:
                # Red by name on a base verdict, but failing another way there: the failure lines none of those
                # verdicts' failures of it print, a few (a lint's new offender is often not its first new line).
                named = [verdict for _, verdict in window + at_merge_base
                         if any(test in verdict["steps"].get(key, {}).get("tests", ())
                                for key in ws_check_step_keys(verdict, step))]
                new = sorted(line for line in failure_text(head, step, test)
                             if not any(line in failure_text(verdict, ws_check_step_key(verdict, step, test), test)
                                        for verdict in named))
                if named and new:
                    missing.append(f"'{step} :: {test}' failure '{new[0][:200]}'")
                    shown = "".join(f", then '{line[:200]}'" for line in new[1:3])
                    lines.append(f"not excused '{WS_CHECK}' test '{step} :: {test}': red on {tested}{older()}"
                                 f"{mb_note()} too, but failing another way there: {len(new)} line(s) of its failure "
                                 f"are not in that red's, first '{new[0][:200]}'{shown}; this head's own red")
                else:
                    missing.append(f"'{step} :: {test}'")
                    lines.append(f"not excused '{WS_CHECK}' test '{step} :: {test}': not red on {tested}{older()}"
                                 f"{mb_note()}; this head's own red")
        unmatched = [line for line in sorted(red["lines"]) if on((step, "line", line)) is None
                     and not by_suite(step, red.get("line_suites", {}).get(line, frozenset()), (line,))]
        label = f"step '{step}'" + (" (its ws-check lines)" if red["tests"] else " (no test names: its output)")
        if unmatched:
            missing.append(f"'{step}' line '{unmatched[0][:200]}'")
            lines.append(f"not excused '{WS_CHECK}' {label}: {len(unmatched)} of {len(red['lines'])} line(s) not on "
                         f"{tested}{older()}{mb_note()}, first '{unmatched[0][:200]}'; this head's own red")
        elif not red["tests"]:
            found = {hit[0] for line in red["lines"] if (hit := on((step, "line", line))) is not None}
            suited = sorted({suite for line in red["lines"] if on((step, "line", line)) is None
                             for suite in red.get("line_suites", {}).get(line, ())})
            strict = sum(on((step, "line", line)) is not None for line in red["lines"])
            lines.append(f"excused '{WS_CHECK}' {label}: its {strict} line(s) are red on {base} "
                         f"{', '.join(sorted(commit[:12] for commit in found)) or tip[:12]} too"
                         + (" (the merge-base's included)" if at_merge_base and at_merge_base[0][0] in found else "")
                         + (f"; the rest are {suite_said(step, suited)}" if suited else ""))
    if missing:
        return {"kind": "head_only", "fix": "", "audit": [],
                "message": f"'{WS_CHECK}': {len(missing)} failure(s) not on {base}: {'; '.join(missing)[:600]}\n"
                           + "\n".join(lines)}
    via = (f"; at this PR's merge-base {merge_base[:12]} ({at_merge_base[0][1]['url'] or 'no run'}) for what the "
           "window does not show" if at_merge_base and any((on(unit) or ("",))[0] == merge_base for unit in units)
           else "")
    suited = (f"; per suite for {len(by_suite_seen)} suite(s) this PR does not touch: "
              f"{', '.join(sorted(suite for _, suite in by_suite_seen))[:300]}" if by_suite_seen else "")
    audit = [f"excused '{WS_CHECK}': every failure on {sha[:12]} is red on {base} too (newest {base} verdict "
             f"{tested}{via}{suited})"] + lines
    return {"kind": "base_red", "fix": "", "message": audit[0], "audit": audit}


def list_base_runs(repo: str, base: str, workflow, github, base_runs: dict) -> None:
    """BASE_RUNS[WORKFLOW] (a workflow id or file name): its BASE runs, newest first, read once per judge. Read only
    through Evidence.runs, which reads a stacked parent's runs instead."""
    if workflow in base_runs:
        return
    # Every status: a job's verdict is final once the job completes, so a base run still running its slower jobs
    # already answers for its finished ones (before_merge_base's note).
    listed = github.json(f"repos/{repo}/actions/workflows/{workflow}/runs?branch={base}&per_page={BASE_RUNS_PAGE}")
    # Newest first, whatever order GitHub lists them in; a run in a PR's context (pull_request or
    # pull_request_target) is never the base's.
    base_runs[workflow] = sorted(
        (run for run in (listed.get("workflow_runs") if isinstance(listed, dict) else None) or []
         if isinstance(run, dict) and run.get("event") not in ("pull_request", "pull_request_target")
         and run.get("conclusion") != "skipped" and not post_merge_probe(run)),
        key=lambda run: run.get("created_at") or "", reverse=True)


# A namesake read as a mismatch (2026-11-24, hq#20438): two workflows each ran a job 'tests' on the head, and the
# refusal named only the base run, so the green base run of one ('lane-gh-broker tests', whose own 'tests' red was a
# test budget overrun) was taken for the base verdict of the other ('fleet-reconcilers tests', excused as a shared base
# red). The verdict was right; the text hid which workflow each run was. So the refusal names both runs' workflows.
def workflow_label(run: dict, workflow=None) -> str:
    """RUN's workflow as a refusal names it: its name and file, else WORKFLOW (an id or a file) when RUN has neither."""
    name = run.get("name") if isinstance(run, dict) else None
    file = workflow_file(run)
    if name and file:
        return f"workflow '{name}' ({file})"
    if name or file:
        return f"workflow '{name or file}'"
    return f"workflow {workflow}"


def workflow_file(run: dict) -> str | None:
    """RUN's workflow file name (`ci.yml`), the one repo-independent way to name a workflow: a workflow's id is per
    repo, so another repo's runs of the same workflow are listed by this name (Evidence.listed, list_base_runs take
    either). None when the run came back without a workflow path under .github/workflows/."""
    path = run.get("path") if isinstance(run, dict) else None
    if not isinstance(path, str) or not path.startswith(".github/workflows/"):
        return None
    return path.removeprefix(".github/workflows/").split("@", 1)[0]


def post_merge_probe(run: dict) -> bool:
    """Whether RUN is a post-merge batch probe (POST_MERGE_PROBE_TITLE), which is no base verdict."""
    return (str(run.get("path") or "").startswith(f".github/workflows/{POST_MERGE_WORKFLOW}")
            and (run.get("display_title") or "").startswith(POST_MERGE_PROBE_TITLE))


@once_per_judgement("batch-suites", lambda repo, base, github: (repo, base))
def batch_suites(repo: str, base: str, github) -> dict[str, dict]:
    """The post-merge batch suites (POST_MERGE_MANIFEST's `suites`, each with a `workflow` file) BASE's batch runs
    call: the manifest beside this script, else BASE's own (source_text_if_present); {} for another repo or base, or
    when neither reads, so a red is judged by its own workflow alone, as before."""
    if repo != HOME_REPO or base not in POST_MERGE_BASES:
        return {}
    try:
        if POST_MERGE_MANIFEST_FILE.is_file():
            text = POST_MERGE_MANIFEST_FILE.read_text()
        elif hasattr(github, "blob_if_present"):
            text = source_text_if_present(repo, base, POST_MERGE_MANIFEST, github)
        else:
            text = None
        suites = json.loads(text).get("suites") if text else None
    except (OSError, ValueError, AttributeError, Refused):
        return {}
    if not isinstance(suites, dict):
        return {}
    return {key: suite for key, suite in suites.items()
            if isinstance(key, str) and isinstance(suite, dict) and isinstance(suite.get("workflow"), str)}


@functools.lru_cache(maxsize=None)
def _local_workflow_jobs(file: str) -> dict:
    return _workflow(yaml_module(), lambda name: (WORKFLOWS / name).read_text(), file)[1]


def workflow_jobs(repo: str, base: str, file: str, github) -> dict:
    """Workflow FILE's `jobs:`: the one beside this script, else BASE's (workflow_doc); {} when unread."""
    try:
        if (WORKFLOWS / file).is_file():
            return _local_workflow_jobs(file)
        if not hasattr(github, "blob"):
            return {}
        doc = workflow_doc(repo, base, f".github/workflows/{file}", github)
    except Refused:
        return {}
    jobs = doc.get("jobs") if isinstance(doc, dict) else None
    return jobs if isinstance(jobs, dict) else {}


def batch_check(repo: str, base: str, file: str, name: str, github) -> str | None:
    """The check name BASE's post-merge batch runs give PR job NAME of workflow FILE (POST_MERGE_WORKFLOW's rule):
    'S / NAME' when FILE is suite S's workflow; 'S / J' when NAME is 'P / J' and FILE's job checked as 'P / ...'
    calls S's workflow; None when no suite runs it."""
    suites = batch_suites(repo, base, github)
    for key, suite in sorted(suites.items()):
        if suite["workflow"] == file:
            return f"{key} / {name}"
    callees = {f"./.github/workflows/{suite['workflow']}": key for key, suite in suites.items()}
    if " / " not in name or not callees:
        return None
    for job_id, job in workflow_jobs(repo, base, file, github).items():
        key = callees.get(job.get("uses")) if isinstance(job, dict) else None
        if key is None:
            continue
        try:
            prefixes = _check_matcher(str(job_id), job, f".github/workflows/{file}")["prefixes"]
        except Refused:
            continue
        for prefix in prefixes:
            if name.startswith(prefix):
                return f"{key} / {name.removeprefix(prefix)}"
    return None


def base_caller(repo: str, base: str, run: dict, name: str, github=None) -> tuple[str, str] | None:
    """(workflow file, check name) of the base's verdict for job NAME when RUN's own workflow no longer runs it on
    BASE: the post-merge batch tier's (batch_check), else a base-push job named in BASE_CHECK_FOR, else the workflow
    that runs the same called job on pushes to
    BASE (BASE_WORKFLOW_FOR, a pull-request-only caller of the same reusable workflow) under NAME itself; None for any
    other job, base, repo or unread workflow path."""
    path = run.get("path") if isinstance(run, dict) else None
    if repo != HOME_REPO or not isinstance(path, str) or not path.startswith(".github/workflows/"):
        return None
    file = path.removeprefix(".github/workflows/").split("@", 1)[0]
    if (check := batch_check(repo, base, file, name, github)) is not None:
        return POST_MERGE_WORKFLOW, check
    if (renamed := BASE_CHECK_FOR.get((base, file, name))) is not None:
        return renamed
    caller = next((caller for (branch, pr_file, job_id), caller in BASE_WORKFLOW_FOR.items()
                   if branch == base and pr_file == file and name.startswith(f"{job_id} / ")), None)
    return None if caller is None else (caller, name)


def base_dispatch(repo: str, base: str, run: dict, runs: list[dict], github, now: datetime | None = None) -> str | None:
    """For RUN's workflow in BASE_DISPATCH: the state of its base dispatch, starting one when none is running and
    none started within BASE_DISPATCH_EVERY (RUNS: its BASE runs, newest first, as list_base_runs read them). None for
    any other workflow, base or repo."""
    file = workflow_file(run)
    if repo != HOME_REPO or file is None:
        return None
    if (base, file) not in BASE_DISPATCH:
        return None
    dispatched = [found for found in runs if found.get("event") == "workflow_dispatch"]
    if (pending := next((found for found in dispatched if found.get("status") != "completed"), None)) is not None:
        return (f"its {base} dispatch run {pending['id']} is {pending.get('status')}; "
                "re-check once it completes")
    now = now or datetime.now().astimezone()
    if dispatched and (started := created(dispatched[0])) is not None and now - started < BASE_DISPATCH_EVERY:
        return (f"its newest {base} dispatch run {dispatched[0]['id']} gave no verdict for it; the next dispatch "
                f"starts after {(started + BASE_DISPATCH_EVERY).strftime('%H:%MZ')}")
    try:
        started_run = github.dispatch(repo, file, base)
    except Refused as why:
        return (f"no {base} dispatch of {file} could start from this host ({str(why)[:200]}); a check from a host "
                "whose gh may dispatch starts it")
    named = f" run {started_run}" if started_run is not None else ""
    return f"dispatched {file}{named} on the {base} tip for a base verdict; re-check once it completes"


# A gallery health shard of a pull request replays its red states on the base it merged with (gallery-health.yml's
# GALLERY_REPLAY_STEP). When the base itself does not load, the replay dies before it compares and the shard is red
# with no per-state verdict: 2026-11-07, base d7e68dec's webviews imported 'pillAsks' from JumpPill.tsx after it
# moved ("SyntaxError: Export named 'pillAsks' not found", job 128448409188), and land-judge refused cmux#37916, the
# fix itself, as "'health (1)': no failing test or error line to match". Such a shard is judged as its replay would
# have judged it (test_reds.gallery_classify), against the newest first-parent base commit, at or before the replay's
# base and within GALLERY_FALLBACK_COMMITS / GALLERY_FALLBACK_HOURS, whose gallery health run gave every shard a whole
# health.json. The same rule as cmuxterm-hq#7649 (next_autoland.crashed_webview_replay): only a crash in the replay of
# the base counts, its first failed step the replay and a load error after the replay starts. A head that does not
# load never reaches the replay (it names no red state), and stays its own red.
GALLERY_WORKFLOW = ".github/workflows/gallery-health.yml"
GALLERY_JOB = re.compile(r"health \((\d+)\)")
GALLERY_RENDER_STEP = "Render the gallery and judge it"
GALLERY_REPLAY_STEP = "Judge the red states against the base"
GALLERY_REPLAY_START = re.compile(r"^replaying on base ([0-9a-f]{40}): \S")
GALLERY_ARTIFACT = "gallery-health-"
GALLERY_HEALTH = "health.json"
# cmuxterm-hq#7649's BASE_LOAD_CRASH: a module that does not load.
BASE_LOAD_CRASH = re.compile(r"SyntaxError|Export named '[^']*' not found|No matching export|Cannot find module|"
                             r"Could not resolve|Module not found|failed to load module", re.I)
GALLERY_FALLBACK_COMMITS = 50
GALLERY_FALLBACK_HOURS = 48
GALLERY_FALLBACK_RUNS = 6  # base runs whose jobs and artifacts are read, newest first
COMMITS_PAGES = 3
ARTIFACT_MAX_BYTES = 64 * 1024 * 1024  # a shard's zip, screenshots included, was 18 MB on 2026-11-07
ARTIFACT_SECONDS = 120
# What one artifact read by range may fetch in all: the end record, the central directory and one member, in
# RANGE_BLOCK pieces. A shard zip of 190 MB with about 2,000 screenshots reads about 300 KB.
RANGE_MAX_BYTES = 16 * 1024 * 1024
RANGE_BLOCK = 256 * 1024
# The zip end record with the longest comment a zip may carry.
ZIP_TAIL_BYTES = 22 + 65535


class RangeUnavailable(Exception):
    """The artifact's blob cannot be read by range here; the caller downloads it whole."""


def github_token() -> str | None:
    """A token for the one REST call that names the artifact's blob: GH_TOKEN or GITHUB_TOKEN (Actions), else gh's
    own (an agent host). None when there is none."""
    for name in ("GH_TOKEN", "GITHUB_TOKEN"):
        if os.environ.get(name, "").strip():
            return os.environ[name].strip()
    try:
        said = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return None
    token = said.stdout.strip()
    return token if said.returncode == 0 and token else None


def artifact_blob_url(repo: str, artifact: int, deadline) -> str:
    """The signed blob URL GitHub redirects ARTIFACT's zip download to. The token rides only this call
    (an unredirected header): it never reaches the blob host."""
    token = github_token()
    if not token:
        raise RangeUnavailable("no GitHub token")
    api = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    request = urllib.request.Request(f"{api}/repos/{repo}/actions/artifacts/{int(artifact)}/zip")
    request.add_unredirected_header("Authorization", f"Bearer {token}")
    request.add_unredirected_header("Accept", "application/vnd.github+json")
    try:
        status, _, headers = deadline_http.request(request, deadline=deadline, follow_redirects=False,
                                                   max_bytes=1 << 16)
    except (OSError, ValueError, deadline_http.RequestTimeout) as error:
        raise RangeUnavailable(f"artifact redirect: {error}") from None
    location = headers.get("Location") or ""
    parts = urllib.parse.urlsplit(location)
    loopback = parts.hostname in ("127.0.0.1", "localhost", "::1")
    if status not in (301, 302, 303, 307, 308) or not (parts.scheme == "https" or (parts.scheme == "http" and loopback)):
        raise RangeUnavailable(f"artifact {artifact} did not redirect to a blob (HTTP {status})")
    return location


class RangeFile(io.RawIOBase):
    """A read-only, seekable view of URL that fetches RANGE_BLOCK-aligned pieces on demand and keeps them, so
    zipfile reads the end record, the central directory and one member without the rest. Every fetch shares
    DEADLINE, and all of them together stay under RANGE_MAX_BYTES (Refused past it)."""

    def __init__(self, url: str, artifact: int, deadline):
        super().__init__()
        self.url, self.artifact, self.deadline = url, artifact, deadline
        self.blocks: dict[int, bytes] = {}
        self.fetched = 0
        self.position = 0
        # The blob host (Azure) answers a suffix range (bytes=-N) whole, so the size comes from a one-byte read
        # and the tail is read by its offsets.
        self.size = self._fetch("bytes=0-0")[0]
        start = max(0, self.size - ZIP_TAIL_BYTES)
        self.blocks_tail = (start, self._fetch(f"bytes={start}-{self.size - 1}")[1] if self.size else b"")

    def _fetch(self, spec: str) -> tuple[int, bytes]:
        request = urllib.request.Request(self.url, headers={"Range": spec})
        try:
            status, body, headers = deadline_http.request(request, deadline=self.deadline,
                                                          max_bytes=RANGE_BLOCK + ZIP_TAIL_BYTES)
        except deadline_http.AnswerTooLarge:
            raise RangeUnavailable(f"artifact {self.artifact}: the blob answered a range whole") from None
        except deadline_http.RequestTimeout:
            raise Refused(f"artifact {self.artifact} took over {ARTIFACT_SECONDS} seconds to read") from None
        except (OSError, ValueError) as error:
            raise RangeUnavailable(f"artifact {self.artifact}: range read failed ({error})") from None
        total = re.fullmatch(r"bytes \d+-\d+/(\d+)", (headers.get("Content-Range") or "").strip())
        if status != 206 or not total:
            raise RangeUnavailable(f"artifact {self.artifact}: the blob answered HTTP {status}, not a range")
        self.fetched += len(body)
        if self.fetched > RANGE_MAX_BYTES:
            raise Refused(f"artifact {self.artifact}: reading {RANGE_MAX_BYTES} bytes by range did not reach the file")
        return int(total.group(1)), body

    def _block(self, index: int) -> bytes:
        if index not in self.blocks:
            start = index * RANGE_BLOCK
            tail_start, tail = self.blocks_tail
            end = min(start + RANGE_BLOCK, self.size)
            if start >= tail_start:
                self.blocks[index] = tail[start - tail_start:end - tail_start]
            else:
                self.blocks[index] = self._fetch(f"bytes={start}-{end - 1}")[1]
        return self.blocks[index]

    def readable(self) -> bool:
        return True

    def seekable(self) -> bool:
        return True

    def tell(self) -> int:
        return self.position

    def seek(self, offset: int, whence: int = io.SEEK_SET) -> int:
        base = {io.SEEK_SET: 0, io.SEEK_CUR: self.position, io.SEEK_END: self.size}[whence]
        self.position = max(0, base + offset)
        return self.position

    def readinto(self, buffer) -> int:
        view = memoryview(buffer).cast("B")
        done = 0
        while done < len(view) and self.position < self.size:
            index, within = divmod(self.position, RANGE_BLOCK)
            piece = self._block(index)[within:within + len(view) - done]
            if not piece:
                break
            view[done:done + len(piece)] = piece
            done += len(piece)
            self.position += len(piece)
        return done


def artifact_member_by_range(repo: str, artifact: int, member: str) -> str | None:
    """MEMBER's text in ARTIFACT's zip, read by range (GitHub.artifact_file); RangeUnavailable when it can't be."""
    deadline = deadline_http.Deadline(ARTIFACT_SECONDS)
    view = RangeFile(artifact_blob_url(repo, artifact, deadline), artifact, deadline)
    try:
        with zipfile.ZipFile(view) as archive:
            if member not in archive.namelist():
                return None
            info = archive.getinfo(member)
            if info.file_size > ARTIFACT_MAX_BYTES or info.compress_size > RANGE_MAX_BYTES:
                raise Refused(f"artifact {artifact}: {member} unpacks past the cap")
            with archive.open(info) as found:
                raw = found.read(ARTIFACT_MAX_BYTES + 1)
    except zipfile.BadZipFile as error:
        raise Refused(f"artifact {artifact} is not a zip ({error})") from None
    if len(raw) > ARTIFACT_MAX_BYTES:
        raise Refused(f"artifact {artifact}: {member} unpacks past the cap")
    return raw.decode(errors="replace")


def gallery_replay_crash(job: dict, head_log: str) -> tuple[str, str] | None:
    """(the replay's base sha, its load error) when gallery health shard JOB's base replay crashed loading the base:
    its first failed step is GALLERY_REPLAY_STEP and a BASE_LOAD_CRASH line follows the replay's start, before the
    next step. None otherwise: any other red, or a crash before the replay (the head's own)."""
    failed = [step.get("name") for step in job.get("steps") or []  # step-name: classify
              if step.get("conclusion") not in (None, "success", "skipped")]
    if not failed or failed[0] != GALLERY_REPLAY_STEP:
        return None
    base = None
    for text in lines_of(head_log):
        if base is None:
            if started := GALLERY_REPLAY_START.match(text):
                base = started.group(1)
        elif text.startswith("##[group]Run "):
            return None  # the next step: the replay ended without a load error
        elif BASE_LOAD_CRASH.search(text):
            return base, text[:300]
    return None


def first_parent_chain(repo: str, base_sha: str, github) -> list[tuple[str, datetime]]:
    """BASE_SHA and its first parents, newest first: at most GALLERY_FALLBACK_COMMITS, none committed over
    GALLERY_FALLBACK_HOURS before BASE_SHA, read from up to COMMITS_PAGES pages of the commit listing."""
    by_sha: dict[str, dict] = {}
    chain: list[tuple[str, datetime]] = []
    sha, newest = base_sha, None
    for page in range(1, COMMITS_PAGES + 1):
        listed = github.json(f"repos/{repo}/commits?sha={base_sha}&per_page=100&page={page}")
        by_sha.update((commit["sha"], commit) for commit in listed if isinstance(commit, dict)
                      and isinstance(commit.get("sha"), str))
        while sha in by_sha and len(chain) < GALLERY_FALLBACK_COMMITS:
            stamp = ((by_sha[sha].get("commit") or {}).get("committer") or {}).get("date") or ""
            try:
                when = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
            except ValueError:
                return chain
            newest = newest or when
            if newest - when > timedelta(hours=GALLERY_FALLBACK_HOURS):
                return chain
            chain.append((sha, when))
            parents = by_sha[sha].get("parents") or []
            sha = parents[0].get("sha") if parents and isinstance(parents[0], dict) else None
        if sha is None or len(chain) >= GALLERY_FALLBACK_COMMITS or len(listed) < 100:
            return chain
    return chain


def newest_artifacts(listed: dict) -> dict[str, dict]:
    """A run's unexpired artifacts by name; of one name (a re-run's), the newest."""
    found: dict[str, dict] = {}
    for item in sorted((item for item in listed.get("artifacts") or []
                        if isinstance(item, dict) and isinstance(item.get("id"), int) and not item.get("expired")),
                       key=lambda item: item["id"]):
        found[str(item.get("name"))] = item
    return found


def gallery_run_results(repo: str, run: dict, github) -> list[str] | None:
    """Every rendered shard's health.json of gallery health RUN, or None when RUN gave no whole verdict: a shard
    job without a verdict conclusion, a shard whose render crashed (no health.json, or one with no per-state
    results), or a run that rendered nothing."""
    jobs = [job for job in base_run_jobs(repo, run, github) if GALLERY_JOB.fullmatch(job.get("name") or "")]
    if not jobs or any(job.get("conclusion") not in VERDICTS for job in jobs):
        return None
    for job in jobs:
        failed = [step.get("name") for step in job.get("steps") or []  # step-name: classify
                  if step.get("conclusion") not in (None, "success", "skipped")]
        if failed and failed[0] != GALLERY_REPLAY_STEP:
            return None  # red before its verdict step (a checkout, the entries it renders): no verdict
    rendered = [job for job in jobs if any(step.get("name") == GALLERY_RENDER_STEP  # step-name: classify
                                           and step.get("conclusion") not in (None, "skipped")
                                           for step in job.get("steps") or [])]
    if not rendered:
        return None
    listed = github.json(f"repos/{repo}/actions/runs/{run['id']}/artifacts?per_page=100")
    artifacts = newest_artifacts(listed)
    texts = []
    for job in rendered:
        item = artifacts.get(GALLERY_ARTIFACT + GALLERY_JOB.fullmatch(job["name"]).group(1))
        text = github.artifact_file(repo, item["id"], GALLERY_HEALTH) if item else None
        found = test_reds.gallery_read(text)
        if found.truncated or found.crashes:
            return None
        texts.append(text)
    return texts


def gallery_fallback(repo: str, base: str, workflow, base_sha: str, github,
                     evidence: "Evidence") -> tuple[str, list[str]] | str:
    """("SHA12 (run R)", its shards' health.json) for the newest gallery health run of a commit in BASE_SHA's
    first-parent chain (first_parent_chain) with a whole verdict, or why there is none."""
    if (parent := evidence.parent) is not None and base_sha != parent.head:
        return (f"its replay loaded {base_sha[:12]}, not PR #{parent.number}'s head {parent.head[:12]}, whose checks "
                f"are {base}'s only verdicts")
    chain = first_parent_chain(repo, base_sha, github) if parent is None else [(parent.head, None)]
    by_sha: dict[str, list[dict]] = {}
    for run in evidence.runs(workflow):
        if run.get("status") == "completed" and run.get("conclusion") in VERDICTS:
            by_sha.setdefault(tested_sha(run), []).append(run)
    reads = 0
    for sha, _ in chain:
        for run in sorted(by_sha.get(sha, []), key=lambda found: found["id"], reverse=True):
            if reads >= GALLERY_FALLBACK_RUNS:
                return (f"none of the {GALLERY_FALLBACK_RUNS} newest {base} gallery health runs before it gave "
                        "every shard a whole result")
            reads += 1
            if (texts := gallery_run_results(repo, run, github)) is not None:
                return f"{sha[:12]} (run {run['id']})", texts
    return (f"no {base} commit in the last {GALLERY_FALLBACK_COMMITS} first-parent commits or "
            f"{GALLERY_FALLBACK_HOURS} h at or before {base_sha[:12]} has a gallery health run with a whole result "
            f"(read {reads} of the {base} runs listed)")


def gallery_crash_verdict(repo: str, base: str, name: str, job: dict, head_log: str, workflow_info: dict,
                          github, evidence: "Evidence") -> str | None:
    """The audit line for gallery health shard JOB (NAME) whose base replay crashed loading the base
    (gallery_replay_crash), judged per state against an older base verdict (gallery_fallback); None for any other
    job or red. Raises Refused when a red state is not red the same way there, or nothing could be judged."""
    path = str(workflow_info.get("path") or "").split("@", 1)[0]
    if path != GALLERY_WORKFLOW or not (shard := GALLERY_JOB.fullmatch(name)):
        return None
    if (crash := gallery_replay_crash(job, head_log)) is None:
        return None
    base_sha, error = crash
    said = f"'{name}': its base replay crashed loading {base} {base_sha[:12]} ({error})"
    listed = github.json(f"repos/{repo}/actions/runs/{job['run_id']}/artifacts?per_page=100")
    head = newest_artifacts(listed).get(GALLERY_ARTIFACT + shard.group(1))
    if head is None:
        raise Refused(f"{said}, and its own {GALLERY_ARTIFACT}{shard.group(1)} artifact is not readable")
    head_text = github.artifact_file(repo, head["id"], GALLERY_HEALTH)
    fallback = gallery_fallback(repo, base, workflow_info["workflow_id"], base_sha, github, evidence)
    if isinstance(fallback, str):
        raise Refused(f"{said}; {fallback}: fix the base, then re-run it")
    where, texts = fallback
    verdict = test_reds.gallery_classify(head_text, texts, f"{base} {where}")
    if verdict is None:
        raise Refused(f"{said}, and its {GALLERY_HEALTH} names no red state: nothing to judge")
    if verdict.own:
        raise Refused(f"{said}, so judged against {base} {where}: " + "; ".join(verdict.reasons)[:800])
    return (f"excused '{name}': its base replay crashed loading {base} {base_sha[:12]} ({error}); judged per state "
            f"against {base} {where}, the newest whole gallery health verdict before it, where each red state is "
            f"red the same way: {'; '.join(verdict.shared)[:400]}")


# A webview test job is judged per test, never by its job name (2026-11-08). A pull request's red files run in a head
# shard (`web / react-apps-check (N)`) and are replayed on the merge parent by `web / react-apps-base-check`, a job
# ci-web.yml runs on pull requests only. So no base push ever has a job of the replay's name, and every red replay was
# refused as "no feat-cmux-next run of its workflow has a verdict for it to compare with" (cmux#34111 at 64617d70,
# replays (2), (5) and (7)), whatever the base showed. And the base's own push runs a test in whichever shard its split
# puts it, so even a head shard's name matches a base job that ran other files. test_reds.classify_web_window judges
# such a red the way next-autoland's web_red (cmuxterm-hq) does: the tests a replay charged to the change (its head
# re-run's verdict), with their errors from the head shard N of the same run, or a head shard's own failing tests,
# against the red shards of the base's newest webview runs (BASE_WORKFLOW_FOR's push caller, cmux-next-web.yml): a
# test is the base's when one of those runs fails it with the same error. The window is the base-red window: at most
# BASE_WINDOW runs that gave every shard a verdict, within BASE_WINDOW_HOURS of the newest, back to the first all-green
# run (every test passed there, so an older red never counts), reading at most WEB_BASE_JOB_READS job lists.
# The replay is one job, `web / react-apps-base-check`, since cmux#42540 (it was one a head shard, `(N)`): its head
# errors are then every head shard's of the run.
WEB_TEST_JOB = re.compile(r"web / react-apps-(?:check \((?P<shard>\d+)\)|(?P<replay>base-)check(?: \((?P<of>\d+)\))?)")
WEB_SHARD = "web / react-apps-check ({})"
WEB_SHARD_JOB = re.compile(r"web / react-apps-check \(\d+\)")
WEB_BASE_JOB_READS = BASE_JOB_READS
# The steps whose failure is a webview test red, as the jobs API shows them: every other step of these jobs that can
# fail is continue-on-error (it reads as a success there) and is gathered by the job's own last step, 'Fail on the gate
# checks' in a shard (bundles, type check, PR rules) or a head build step in a replay. A job with any other failed step
# failed outside its tests, and a per-test match never excuses it (review F1 on #38380): a head shard is then judged
# by its name and failed steps as before, and a replay, which has no base job of its name, is refused.
WEB_TEST_STEPS = {"replay": frozenset({"Re-run the change's reds alone on the head", "Fail on the change's own reds"}),
                  "shard": frozenset({"Test webviews"})}


def web_base_runs(repo: str, workflow, github, evidence: "Evidence"):
    """(run, its red webview shard jobs) for each of EVIDENCE's newest webview runs of WORKFLOW that gave every shard
    a verdict, newest first, read lazily: the window above. An all-green run is yielded and ends it."""
    reads, count, newest = 0, 0, None
    for run in evidence.runs(workflow):
        if run.get("status") == "completed" and run.get("conclusion") in ("cancelled", "skipped"):
            continue  # a superseded coalesced run: no shard of it ran
        if reads >= WEB_BASE_JOB_READS:
            return
        reads += 1
        shards = [job for job in base_run_jobs(repo, run, github) if WEB_SHARD_JOB.fullmatch(job.get("name") or "")]
        if not shards or any(job.get("status") != "completed" or job.get("conclusion") not in VERDICTS
                             for job in shards):
            continue
        when = created(run)
        newest = newest or when
        if newest and when and newest - when > timedelta(hours=BASE_WINDOW_HOURS):
            return
        red = sorted((job for job in shards if job.get("conclusion") == "failure"), key=lambda job: job["name"])
        yield run, red
        count += 1
        if not red or count >= BASE_WINDOW:
            return


def web_test_verdict(repo: str, base: str, name: str, job: dict, head_log: str, workflow_info: dict, github,
                     evidence: "Evidence") -> str | None:
    """The audit line for a red webview test job NAME (WEB_TEST_JOB) judged per test against the base's newest webview
    runs (the rule above); None for any other job, or a head shard whose log names no failing webview test (judged by
    its name as before). Raises Refused when a test is not red on the base the same way, or nothing could be judged."""
    found = WEB_TEST_JOB.fullmatch(name)
    if repo != HOME_REPO or found is None:
        return None
    replay = bool(found.group("replay"))
    failed = [step.get("name") or "" for step in job.get("steps") or []  # step-name: classify
              if step.get("conclusion") not in (None, "success", "skipped")]
    outside = [step for step in failed if step not in WEB_TEST_STEPS["replay" if replay else "shard"]]
    if outside or not failed:
        if not replay:
            return None
        raise Refused(f"'{name}' failed outside its webview test steps: {', '.join(outside) or 'no step failed'}; "
                      f"a replay has no {base} job of its name to compare with, so it is never a base red")
    head_logs: list[str | None] = [head_log]
    if replay:
        run_jobs = base_run_jobs(repo, {"id": job["run_id"]}, github)
        if found.group("of"):
            shard = WEB_SHARD.format(found.group("of"))
            siblings = [other for other in run_jobs if other.get("name") == shard][:1]
        else:
            shard = WEB_SHARD.format("N")
            siblings = [other for other in run_jobs if WEB_SHARD_JOB.fullmatch(other.get("name") or "")]
        if not siblings:
            raise Refused(f"'{name}': its run has no head shard '{shard}' whose errors its tests could be "
                          "compared by")
        for sibling in siblings:
            try:
                head_logs.append(github.log(repo, sibling))
            except Refused as why:
                raise Refused(f"'{name}': the log of its head shard '{sibling.get('name') or shard}', where its tests' "
                              f"errors are printed, could not be read: {str(why)[:300]}") from None
    # A web shard is checked under its own name on the base (the batch suite `web` is the caller job `web`).
    workflow = (base_caller(repo, base, workflow_info, name, github) or (workflow_info["workflow_id"],))[0]
    green: list[dict] = []
    unread: list[str] = []  # why a base log could not be read, named in the refusal

    def windows():
        for run, red in web_base_runs(repo, workflow, github, evidence):
            if not red:
                green.append(run)
                return
            logs = []
            for found_job in red:
                try:
                    logs.append(github.log(repo, found_job))
                except Refused as why:
                    unread.append(f"job {found_job.get('id')}: {str(why)[:200]}")
                    logs.append(None)
            yield f"{base} run {run['id']}", logs

    verdict = test_reds.classify_web_window(head_logs, windows(), name, base)
    if verdict is None:
        if not replay:
            return None
        raise Refused(f"'{name}': its replay names no failing webview test (it failed outside its tests); a replay "
                      f"has no {base} job of its name to compare with, so it is never a base red")
    if verdict.own:
        said = "; ".join(verdict.reasons)
        if green:
            said += f" (every webview test passed on {base} run {green[0]['id']}, which ends the window)"
        if unread:
            said += f" (unread: {unread[0]})"
        raise Refused(f"'{name}' judged per test against {base}'s webview runs: {said}"[:1000])
    return f"excused '{name}': each failing webview test is red the same way on {base}: " + "; ".join(verdict.shared)[:600]


# A head shard GitHub cancelled or timed out mid-run is judged per file (test_reds.classify_web_cut_short): cmux#39676's
# `web / react-apps-check (1)` was cancelled after 31 min (jobs 129249378930 and 129359593602) while every file it
# failed fails on feat-cmux-next too, and every merge was refused as "no verdict" (claude-sr2-coord, 2026-11-09: "a
# timed-out/cancelled shard whose failing files also fail the same way on base is classified as base red, not 'no
# verdict'"). Only a head shard (a replay's cancel leaves no charged-test verdict), only when the one step cut short is
# its test step, and only when its log names a red file: a shard cancelled while green, in setup or in another step
# still has no verdict and gets re-run.
CUT_SHORT = frozenset({"cancelled", "timed_out"})


def cut_short_web_verdict(repo: str, base: str, name: str, job: dict, github, run_reads: dict,
                          evidence: "Evidence") -> str | None:
    """The audit line excusing cancelled or timed-out head shard NAME, every red file of which is red on BASE's
    webview runs; None when it is not such a shard or its log names no red file (the caller refuses it as no verdict).
    Raises Refused when a red file is not red on the base, or the run crashed or timed a file out."""
    if repo != HOME_REPO or job.get("conclusion") not in CUT_SHORT or not WEB_SHARD_JOB.fullmatch(name):
        return None
    cut = [step.get("name") or "" for step in job.get("steps") or []  # step-name: classify
           if step.get("conclusion") not in (None, "success", "skipped")]
    if not cut or any(step not in WEB_TEST_STEPS["shard"] for step in cut):
        return None
    try:
        head_log = github.log(repo, job)
    except Refused:
        return None
    if test_reds.classify_web_cut_short(head_log, (), name, base) is None:
        return None  # no red file: nothing to compare, and no base run is read
    workflow_info = rest_run(repo, job["run_id"], github, run_reads)
    workflow = (base_caller(repo, base, workflow_info, name, github) or (workflow_info.get("workflow_id"),))[0]
    if workflow is None:
        return None
    green: list[dict] = []
    unread: list[str] = []

    def windows():
        for run, red in web_base_runs(repo, workflow, github, evidence):
            if not red:
                green.append(run)
                return
            logs = []
            for found_job in red:
                try:
                    logs.append(github.log(repo, found_job))
                except Refused as why:
                    unread.append(f"job {found_job.get('id')}: {str(why)[:200]}")
                    logs.append(None)
            yield f"{base} run {run['id']}", logs

    verdict = test_reds.classify_web_cut_short(head_log, windows(), name, base)
    if verdict is None:
        return None
    if verdict.own:
        said = "; ".join(verdict.reasons)
        if green:
            said += f" (every webview test passed on {base} run {green[0]['id']}, which ends the window)"
        if unread:
            said += f" (unread: {unread[0]})"
        raise Refused(f"'{name}' is {job['conclusion']}; judged per file against {base}'s webview runs: {said}"[:1000])
    return (f"excused '{name}': {job['conclusion']} mid-run (job {job.get('id')}), and each file it failed or left "
            f"running is red on {base}: " + "; ".join(verdict.shared)[:600]
            + "; the files the cancel kept from running are not judged")


class Head(NamedTuple):
    """read_head's answer: an audit line that settles the job without a base comparison (AUDIT), or its failed_view
    (VIEW, UNPLACED for a log not placed), whether it is a Chromium currency red with no diagnostics, and PER_TEST, the
    gallery and webview per-test verdicts (each None for any other job), which take the run's record."""
    audit: str | None
    view: "FailedView | Unplaced | None" = None
    chromium_without_diagnostics: bool = False
    per_test: Callable[[dict], str | None] = lambda workflow_info: None
    # The whole-log signature of an unplaced head (VIEW UNPLACED) or of a placed one with nothing to compare, else
    # None: unplaced_verdict compares it.
    unplaced: "UnplacedSignature | None" = None
    # Its compiler errors (compile_errors) of its failed sections, or of its whole log when VIEW is UNPLACED:
    # compile_errors_verdict compares them.
    compile: "CompileErrors | None" = None


def checkout_death(repo: str, base: str, sha: str, job: dict, log: str | None, github) -> str | None:
    """Why red JOB's LOG is a checkout that died before any step of the change ran (test_reds.died_in_checkout: its
    first error is inside actions/checkout and no other step ran after it), when the change at SHA cannot have made
    it fail: it changes neither .gitmodules nor a gitlink against BASE (runs_no_pr_code's rule), read in full. Else
    None, and the red is judged as before. cmux#51655 at fd3c0b17: 'changes' died fetching from github.com in
    actions/checkout ("Operation too slow", git exit 128) and land-judge stopped the land on it as the PR's own red;
    it is the same red leo-workspace tools/ws-check reruns (failed_in_checkout, leo-workspace#11281)."""
    error = test_reds.died_in_checkout(log)
    if error is None:
        return None
    diff = github.json(f"repos/{repo}/compare/{base}...{sha or job.get('head_sha')}")
    files = diff.get("files") if isinstance(diff, dict) else None
    if not isinstance(files, list) or len(files) >= COMPARE_FILES_CAP:
        return None  # which paths the change touches is not known in full: its red stays its own
    changed = {str(path) for found in files if isinstance(found, dict)
               for path in (found.get("filename"), found.get("previous_filename")) if path is not None}
    if ".gitmodules" in changed or compare_gitlinks(files):
        return None  # a submodule pin the change moves can fail the checkout on its own (#43915)
    return f"actions/checkout step, which died before any step of this change ran ({error[:300]})"


def read_head(repo: str, base: str, sha: str, name: str, job: dict, github, run_reads: dict,
              evidence: "Evidence") -> Head:
    """The one reader of red head JOB's raw log for judge(), which reads only its failed_view. Raw, it is read only
    by gates that refuse (a runner refusal at setup, a generated files, summary or no-verdict line, a crash or a run
    cut short), by the verdicts that are not a comparison of its lines with a base's (a no-verdict compile another
    pass compiled, the fleet's compile receipts at the merge-base), and by the gallery and webview per-test verdicts,
    which read their runners' own per-state and per-file blocks (test_reds.gallery_classify, classify_web_window),
    not its steps' sections, and by unplaced_signature when its failed_view is UNPLACED (compared whole, only on
    identity: UnplacedSignature). Raises Refused; Infra for a lost runner."""
    head_log = lost_runner_log(repo, name, job, github)
    # Which steps the workflow names (step_owners), read before any reader places this log's lines.
    names = job_step_names(repo, job, github, run_reads)
    if refused_at_setup(job, head_log):
        raise Refused(f"'{name}' was refused at setup by its runner; it gets re-run, never excused")
    if (died := checkout_death(repo, base, sha, job, head_log, github)) is not None:
        raise Refused(f"'{name}' was refused at setup by its runner's {died}; it gets re-run, never excused")
    if name == TREE_HANDOFF_JOB and (said := tree_handoff_quota_only(job, head_log)) is not None:
        raise JobRateLimited(f"'{name}' reported only its repo installation API quota refusal ({said}); rerun the job "
                             "after that boundary")
    if name == GENERATED_VERDICT_JOB and (said := generated_no_verdict(head_log)) is not None:
        raise Refused(f"'{name}' gave no generated files verdict ({said[:300]}); "
                      "re-run its prerequisite and this dependent job together")
    if (said := summary_no_verdict(head_log)) is not None:
        raise Refused(f"'{name}' gave no verdict ({said[:300]}): nothing it summarizes was judged, so it is "
                      "neither a pass nor this PR's own red; re-run it")
    if (said := summary_red(head_log)) is not None:
        raise Refused(f"'{name}' is a summary red ({said[:300]}): its line names failed children in words every "
                      "summary shares, never a red the base can share; compare its failed children, each as itself")
    if name in NO_VERDICT_JOBS and (said := no_verdict(head_log)) is not None:
        proof = compile_pass_at(repo, sha, github)
        if proof is None:
            raise Refused(f"'{name}' gave no compile verdict ({said[:300]}) and nothing else compiled {sha}: "
                          "a no-verdict compile is never a base red; re-run it once the fleet answers")
        return Head(f"ignored '{name}': it gave no compile verdict, but {proof} compiled {sha} and passed")
    if name == FLEET_COMPILE_JOB and any(FLEET_COMPILE_FAIL.match(text) for text in lines_of(head_log)):
        # A pull-request-only job: the fleet's receipts at the merge-base are its base verdict. When they do not
        # excuse it, the job is compared with base runs, as before.
        try:
            return Head(inherited_compile_red(repo, base, sha, name, github, evidence))
        except Refused:
            pass
    view = failed_view(job, head_log, step_names=names, base=False)
    early = signature(view)
    if any(str(step.get("name") or "") in ROLLUP_STEPS for step in job.get("steps") or []):  # step-name: classify
        # The rollup's own list, for a check run that carries no annotation of it (rolled_up_reds).
        run_reads.setdefault("rollup-log-reds", {})[job["id"]] = rollup_log_reds(head_log)
    # An unplaced head has no signature: no rule that reads one (the Chromium currency step, the app FFI pin) applies
    # to it, and the base comparison refuses it; per-test web and gallery verdicts read their own evidence.
    chromium_without_diagnostics = (early is not UNPLACED and name == CHROMIUM_CURRENCY_JOB
                                    and CHROMIUM_CURRENCY_STEP in early[0]
                                    and not (early[1] or early[2] or crash_signals(view)))
    # A webview replay's log holds the merge parent's run too: only its head part can crash or be cut short as
    # the head's (test_reds.web_head_part; cmux#34111's replay (2), whose merge parent timed out a file).
    own = test_reds.read(test_reds.web_head_part(head_log) if WEB_TEST_JOB.fullmatch(name) else head_log)
    if not WEB_TEST_JOB.fullmatch(name):
        own = owned_unnamed(own, view, test_reds.unjudged(head_log) if view is UNPLACED else None)
    if name == GUARD_GROUP_JOB:
        own.truncated = guard_group_truncated(own.truncated, view)
    if own.crashes or (own.truncated and not chromium_without_diagnostics):
        raise Refused(f"'{name}': " + "; ".join(own.crashes + own.truncated[:1])[:800]
                      + " (a crash, a cut-short run or a failure no parser names is never a base red)")

    def per_test(workflow_info: dict) -> str | None:
        return (gallery_crash_verdict(repo, base, name, job, head_log, workflow_info, github, evidence)
                or web_test_verdict(repo, base, name, job, head_log, workflow_info, github, evidence))
    # A placed head whose failed sections name no failing test, error line or crash (hq#9191's `FAIL: plist content`)
    # is compared whole too, never refused for want of a key: the whole-log identity is the fallback either way.
    bare = (early is not UNPLACED and not early[1] and not early[2] and not crash_signals(view)
            and not chromium_without_diagnostics)
    return Head(None, view, chromium_without_diagnostics, per_test,
                unplaced_signature(job, head_log) if view is UNPLACED or bare else None,
                compile_errors(test_reds.lines_of(head_log) if view is UNPLACED else list(lines_of(view_text(view))),
                               job))


def compile_base_evidence(repo: str, run: dict, found: dict, github, run_reads: dict) -> "CompileErrors":
    """compile_errors of red base job FOUND (of base run RUN): of its failed sections (failed_view), or of its whole
    log when step_owners cannot place it, as pr_only_step_verdict reads an unplaced base job. The one reader of the
    raw log of a base job compile_errors_verdict compares."""
    text = github.log(repo, found)
    view = failed_view(found, text, base=True,
                       step_names=job_step_names(repo, found, github, run_reads, path=run.get("path")))
    return compile_errors(test_reds.lines_of(text) if view is UNPLACED else list(lines_of(view_text(view))), found)


class BaseUnplaced(Refused):
    """base_evidence's refusal of a red base job whose log step_owners does not place (BASE_UNPLACED_WHY)."""


def base_evidence(repo: str, base: str, name: str, run: dict, found: dict, github, run_reads: dict) -> tuple:
    """(RUN, the failed_view of red base job FOUND's log, its signature, its step_errors), the window entry
    compare_window reads: the one reader of a compared base job's raw log. A base log failed_view does not place is
    never base evidence: BaseUnplaced, which judge() answers with a whole-log comparison. Its words say the base was
    unread, never the head's red, for every caller it reaches (journey, the merge-base step check; review F1 on
    cmux#46811)."""
    text = github.log(repo, found)
    view = failed_view(found, text, step_names=job_step_names(repo, found, github, run_reads, path=run.get("path")),
                       base=True)
    if view is UNPLACED:
        raise BaseUnplaced(f"'{name}': {base} run {run['id']}'s log does not map one to one onto its steps "
                           "(step_owners), so no base line can be told to a failed step; nothing is compared: "
                           f"unread, not this PR's own red: retry once a {base} verdict of it is placed")
    return run, view, signature(view), step_errors(view)


# A stacked child (hq#9249, 2026-11-11): a child PR into a lane branch that is itself an open PR's head (hq#9226's
# lane/rerun-guard-fixed-on-base) has no run of the lane branch on base to compare with: the lane branch is only ever
# run as its own PR's pull_request runs. So every red the child inherited from the parent's stale base was refused as
# "no lane/... run of its workflow has a verdict" ('Skill policy tests', the LaunchAgent test #9236 fixed on main,
# red on hq#9249 at a0f7212f and on its parent's head d755d38b alike). Such a base is judged by its parent PR's checks
# at the parent's current head, with the same identity-keyed comparison as any base verdict. Sound because the parent
# is gated again before it reaches its own base: nothing lands without CI, and a red the parent has too is not the
# child's. Only one open same-repo PR headed by the base branch, whose head is the branch's tip, is that parent: none
# or several judge as before; a branch that moved past its PR's head, or a parent head with no completed run of the
# workflow carrying the job, refuses. A green parent job means the red is the child's own.
INTEGRATION_BRANCHES = frozenset({"main", "feat-cmux-next"})


class StackedParent(NamedTuple):
    number: int
    head: str  # the parent PR's head sha, which is the base branch's tip


def stacked_parent(repo: str, base: str, github, cache: dict) -> StackedParent | None:
    """The open PR of REPO headed by lane branch BASE (StackedParent), read once per judge into CACHE; None when BASE
    is an integration branch or heads no open PR, or several. Refused when the branch's tip is not that PR's head."""
    key = ("stacked-parent", repo, base)
    if key in cache:
        return cache[key]
    cache[key] = None
    if base in INTEGRATION_BRANCHES:
        return None
    owner = repo.split("/", 1)[0]
    listed = github.json(f"repos/{repo}/pulls?head={owner}:{base}&state=open&per_page=100")
    pulls = [pull for pull in (listed if isinstance(listed, list) else [])
             if isinstance(pull, dict) and pull.get("state") == "open"
             and (pull.get("head") or {}).get("ref") == base
             and ((pull.get("head") or {}).get("repo") or {}).get("full_name") == repo]
    if len(pulls) != 1:
        return None
    pull = pulls[0]
    head = str((pull.get("head") or {}).get("sha") or "")
    tip = str(((github.json(f"repos/{repo}/branches/{base}") or {}).get("commit") or {}).get("sha") or "")
    if not re.fullmatch(r"[0-9a-f]{40}", head) or head != tip:
        raise Refused(f"{base} is the head of open PR #{pull.get('number')}, but its tip {tip[:12] or '(unread)'} is "
                      f"not that PR's head {head[:12] or '(unread)'}: the branch moved, so the parent's checks are "
                      "not its verdict; re-check once the parent's head has run")
    cache[key] = StackedParent(int(pull.get("number") or 0), head)
    return cache[key]


# One evidence source per judge (cmux#41235's review, dep-fleet-6, 2026-11-11): the stacked-parent rule above was
# applied only where judge() compares a job by name, and every other verdict path read base runs on its own. F1: the
# web replay and cut-short shard verdicts returned before stacked_parent was asked, so a child's web red inherited
# from its lane parent was compared with the lane branch's own runs (it has none) and refused. F2: base_verdicts added
# the branch's workflow_dispatch runs (tip_suite_verdicts) after the parent's had been kept to its head's pull_request
# and push runs, so a dispatch at the parent's sha could supply an excuse. So judge chooses the source once, before
# any path runs (evidence_source), and passes it to every verdict path: each reads runs, dispatches and base statuses
# through it alone, and none can reach the branch's own runs while a parent is chosen.
PARENT_EVENTS = frozenset({"pull_request", "push"})  # a stacked parent's checks at its head; never a dispatch


class Evidence:
    """Where one judge reads every base verdict. With no parent, BASE's own runs (list_base_runs: every event but a
    pull request's), its dispatches (tip_suite_verdicts) and its commits' statuses (base_status). With a parent (a
    StackedParent), that PR's completed pull_request and push runs at its head and nothing else: no dispatch, no other
    run or commit of the branch, and its head is the merge-base and the tip every comparison reads. The parent is BASE's stacked_parent, asked on the first read any path makes (CACHE
    keeps it per judge), so a judge with nothing to compare reads none; each workflow's list is read once per judge."""

    def __init__(self, repo: str, base: str, github, cache: dict | None = None):
        self.repo, self.base, self.github = repo, base, github
        self.cache = {} if cache is None else cache
        self.listed: dict[int | str, list[dict]] = {}  # by workflow id, or file name (a BASE_WORKFLOW_FOR caller)
        self.reads: dict[tuple[str, str], dict] = {}  # compares and commits, read once per judge

    @property
    def parent(self) -> StackedParent | None:
        """BASE's stacked parent (stacked_parent), or None; Refused as stacked_parent refuses."""
        return stacked_parent(self.repo, self.base, self.github, self.cache)

    @property
    def verdict_repo(self) -> str:
        """The repo whose runs are this base's verdict of record (BASE_VERDICT_REPO), which is REPO itself for every
        repo that runs its own base pushes. A stacked parent's verdict is its own PR's checks at its head, which
        exist only in the PR's repo, so a parent keeps REPO whatever the mapping says."""
        if self.parent is not None:
            return self.repo
        return BASE_VERDICT_REPO.get(self.repo, self.repo)

    def allows(self, run) -> bool:
        """Whether RUN can be this source's evidence at all (its event, and for a parent its head)."""
        if not isinstance(run, dict):
            return False
        if self.parent is None:
            return run.get("event") not in ("pull_request", "pull_request_target")
        return (run.get("head_sha") == self.parent.head and run.get("event") in PARENT_EVENTS
                and run.get("status") == "completed")

    def runs(self, workflow) -> list[dict]:
        """WORKFLOW's runs, newest first: the base's window (list_base_runs), or the parent's at its head."""
        if workflow not in self.listed:
            if self.parent is None:
                list_base_runs(self.verdict_repo, self.base, workflow, self.github, self.listed)
            else:
                listed = self.github.json(f"repos/{self.repo}/actions/workflows/{workflow}/runs?"
                                          f"head_sha={self.parent.head}&per_page=100")
                self.listed[workflow] = sorted(
                    (run for run in (listed.get("workflow_runs") if isinstance(listed, dict) else None) or []
                     if self.allows(run) and run.get("conclusion") != "skipped"),
                    key=lambda run: run.get("created_at") or "", reverse=True)
        return self.listed[workflow]

    def queried(self, workflow, query: str, per_page: int) -> list[dict]:
        """WORKFLOW's runs a QUERY (`head_sha=...`, `created=...`) asks of the base, every one this source allows;
        for a parent, its runs at its head (runs), which the caller filters by the same query's terms."""
        if self.parent is not None:
            return list(self.runs(workflow))
        found = self.github.json(f"repos/{self.verdict_repo}/actions/workflows/{workflow}/runs?"
                                 f"branch={self.base}&{query}&per_page={per_page}")
        return [run for run in (found.get("workflow_runs") if isinstance(found, dict) else None) or []
                if self.allows(run) and not post_merge_probe(run)]

    def dispatches(self, workflow) -> list[dict]:
        """The base's workflow_dispatch runs of WORKFLOW (every status, so a first run's same-tree run is seen while
        it still queues or runs: TREE_JOBS); none for a parent, whose verdict is its PR's own checks (F2)."""
        if self.parent is not None:
            return []
        listed = self.github.json(f"repos/{self.verdict_repo}/actions/workflows/{workflow}/runs?"
                                  f"branch={self.base}&event=workflow_dispatch&per_page={BASE_RUNS_PAGE}")
        return (listed.get("workflow_runs") if isinstance(listed, dict) else None) or []

    def status_commits(self, per_page: int = BASE_STATUS_COMMITS) -> list[str]:
        """The commits whose statuses are base statuses (base_status, github_compile_red, ws_check_red), newest first:
        the base's PER_PAGE newest, or the parent's head alone."""
        if self.parent is not None:
            return [self.parent.head]
        listed = self.github.json(f"repos/{self.repo}/commits?sha={self.base}&per_page={per_page}") or []
        return [commit["sha"] for commit in listed if isinstance(commit, dict) and isinstance(commit.get("sha"), str)]

    def diff(self, sha: str) -> dict:
        """GitHub's compare of the base with SHA (one page), read once per judge: its merge-base and base tip."""
        key = ("compare", sha)
        if key not in self.reads:
            found = self.github.json(f"repos/{self.repo}/compare/{self.base}...{sha}?per_page=1")
            self.reads[key] = found if isinstance(found, dict) else {}
        return self.reads[key]

    def merge_base(self, sha: str, diff: dict | None = None) -> str:
        """The commit SHA's red is compared at as its merge-base. With a parent, the parent's head: its checks are the
        base's only verdicts, and the lane commit the child branched from (older, when the parent moved on) is no
        evidence at all (#41403's review). Else GitHub's merge-base, from DIFF when the caller read one."""
        if self.parent is not None:
            return self.parent.head
        return str(((diff if diff is not None else self.diff(sha)).get("merge_base_commit") or {}).get("sha") or "")

    def merge_base_time(self, sha: str) -> str:
        """merge_base(SHA)'s commit time ("" unread). With a parent, read from the parent's head commit itself."""
        if self.parent is None:
            commit = self.diff(sha).get("merge_base_commit") or {}
        else:
            key = ("commit", self.parent.head)
            if key not in self.reads:
                found = self.github.json(f"repos/{self.repo}/commits/{self.parent.head}")
                self.reads[key] = found if isinstance(found, dict) else {}
            commit = self.reads[key]
        return str(((commit.get("commit") or {}).get("committer") or {}).get("date") or "")

    def tip(self, sha: str) -> str:
        """The base's tip as compared with SHA: the parent's head, or GitHub's base commit."""
        if self.parent is not None:
            return self.parent.head
        return str((self.diff(sha).get("base_commit") or {}).get("sha") or "")

    def where(self) -> str:
        """The source as a refusal names it."""
        if self.parent is None:
            return self.base
        return f"PR #{self.parent.number}'s head {self.parent.head[:12]}"


def evidence_source(repo: str, base: str, github, cache: dict) -> Evidence:
    """The one Evidence for a judge of a red into BASE: its stacked parent's (stacked_parent) when BASE heads one,
    else BASE's own, told on its first read (Evidence.parent)."""
    return Evidence(repo, base, github, cache)


def stacked_parent_verdicts(name: str, base: str, parent: StackedParent, verdicts, cut=lambda: None):
    """VERDICTS (base_verdicts' (run, job) pairs, all read from the parent's Evidence) at PARENT's head only, of its
    PR's own events, so no other run of the branch (a dispatch, say) stands in; Refused when there is none: the
    parent's head has no completed verdict for job NAME, or, when CUT() names the job lists read before the cap cut
    the search short, the search is incomplete (#47687's review F4)."""
    found = [(run, job) for run, job in verdicts
             if tested_sha(run) == parent.head and run.get("event") in PARENT_EVENTS]
    if not found and (read := cut()) is not None:
        raise Refused(f"{cut_refusal(name, base, read)} (PR #{parent.number}'s head {parent.head[:12]})")
    if not found:
        raise Refused(f"'{name}': {base} is PR #{parent.number}'s head; its head {parent.head[:12]} has no completed "
                      "run of this workflow with a verdict for it to compare with; re-check once it has")
    if found[0][1].get("conclusion") != "failure":
        raise Refused(f"'{name}' passed on {base}'s PR #{parent.number} at its head {parent.head[:12]} (run "
                      f"{found[0][0].get('id')}): the red is this PR's own; fix it on this head")
    return iter(found)


# A red from the pull request's old base (2026-11-17, cmux#44908 at e19e1487): opened into feat-cmux-next, then
# retargeted to main. 'cmux-next defaults guard' ran at 00:41Z under the old base (pull_request_target, run
# 43989567080) and failed on a main-based tree; its workflow on main runs only for `branches: [feat-cmux-next]`, so no
# run for base main will ever replace that red, and closing and reopening fires none either. It was refused as "no main
# run of its workflow has a verdict" for good. A red job with no base verdict is excused here only when all hold:
#   (a) its run's event is pull_request or pull_request_target;
#   (b) the pull request's base when the run fired is not its base now: the run's pull_requests[].base.ref when GitHub
#       records another base there, else a base_ref_changed event in the pull request's timeline after the run was
#       created (GitHub's run record lists the current base, and its REST timeline event names no refs);
#   (c) the workflow file at the current base has an `on.<event>.branches` (or `branches-ignore`) filter that excludes
#       the current base; for pull_request, which reads the workflow from the merge commit, the head's copy too.
#       In place of a filter, only a job `if:` that is exactly `github.event.pull_request.base.ref == 'X'`, X not the
#       current base, counts; any other job `if:` excuses nothing.
# Any part unread or of another shape (a glob with `?`, `+` or `[`, a file absent or not YAML) excuses nothing.
RETARGET_EVENTS = ("pull_request", "pull_request_target")
BASE_REF_IF = re.compile(r"(?:\$\{\{\s*)?github\.event\.pull_request\.base\.ref\s*==\s*'([^'\s]+)'(?:\s*\}\})?")


def branch_pattern(pattern: object) -> re.Pattern | None:
    """A GitHub branch filter PATTERN as a regex: `*` any run of characters but `/`, `**` any run at all. None for a
    pattern with `?`, `+`, `[` or `\\` (not modelled here) or of another type."""
    if not isinstance(pattern, str) or not pattern or re.search(r"[?+\[\]\\]", pattern):
        return None
    parts = re.split(r"(\*\*|\*)", pattern)
    return re.compile("".join(".*" if part == "**" else "[^/]*" if part == "*" else re.escape(part)
                              for part in parts))


def filter_excludes(doc: object, event: str, base: str) -> str | None:
    """The `on.EVENT` branch filter of workflow DOC, as `branches: [...]`, when it excludes BASE; None when it admits
    BASE, has no branch filter, or has a shape this does not read. `branches` patterns apply in order, the last one
    matching deciding, a `!` one excluding (GitHub's rule); `branches-ignore` excludes what any pattern matches."""
    triggers = doc.get(True, doc.get("on")) if isinstance(doc, dict) else None
    spec = triggers.get(event) if isinstance(triggers, dict) else None
    if not isinstance(spec, dict):
        return None  # `on: [pull_request]`, `on: pull_request` or `pull_request:` alone: every branch
    for key in ("branches", "branches-ignore"):
        patterns = spec.get(key)
        if patterns is None:
            continue
        patterns = [patterns] if isinstance(patterns, str) else patterns
        if not isinstance(patterns, list) or not patterns:
            return None
        admitted = key == "branches-ignore"
        for pattern in patterns:
            negated = key == "branches" and isinstance(pattern, str) and pattern.startswith("!")
            regex = branch_pattern(pattern[1:] if negated else pattern)
            if regex is None:
                return None
            if regex.fullmatch(base):
                admitted = key == "branches" and not negated
        if admitted:
            return None
        return f"{key}: [{', '.join(str(pattern) for pattern in patterns)}]"
    return None


def single_branch(doc: object, event: str) -> str | None:
    """The branch of workflow DOC's `on.EVENT.branches` when it is one literal name (no glob, no `!`), else None."""
    triggers = doc.get(True, doc.get("on")) if isinstance(doc, dict) else None
    spec = triggers.get(event) if isinstance(triggers, dict) else None
    patterns = spec.get("branches") if isinstance(spec, dict) else None
    patterns = [patterns] if isinstance(patterns, str) else patterns
    if isinstance(patterns, list) and len(patterns) == 1 and isinstance(patterns[0], str) \
            and re.fullmatch(r"[\w./-]+", patterns[0]) and not patterns[0].startswith("!"):
        return patterns[0]
    return None


def job_base_condition(doc: object, name: str) -> str | None:
    """The branch X of the one job of workflow DOC named NAME when its `if:` is exactly
    `github.event.pull_request.base.ref == 'X'`; None for any other `if:`, or when no one job is NAME."""
    jobs = doc.get("jobs") if isinstance(doc, dict) else None
    if not isinstance(jobs, dict):
        return None
    found = []
    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            continue
        try:
            matcher = _check_matcher(str(job_id), job, "")
        except Refused:
            continue
        if matches(matcher, name):
            found.append(job)
    condition = found[0].get("if") if len(found) == 1 else None
    match = BASE_REF_IF.fullmatch(condition.strip()) if isinstance(condition, str) else None
    return match.group(1) if match else None


def workflow_doc(repo: str, ref: str, path: str, github) -> object:
    """Workflow PATH at REF, parsed (source_text, read once per judgement); None when it is unread, absent there or
    not YAML, or no YAML parser imports. A rate-limited read is raised (RateLimitedRead is no Refused)."""
    try:
        yaml = yaml_module()
        text = source_text(repo, ref, path, github)
    except Refused:
        return None
    try:
        return yaml.safe_load(text)
    except yaml.YAMLError:
        return None


def base_at_run(repo: str, base: str, sha: str, run: dict, github, seen: dict) -> tuple[int, str | None, str] | None:
    """(pull request number, its base when RUN fired or None when unnamed, how that is known) when that base was not
    BASE; None when it was BASE or cannot be told. The pull request is the one RUN lists for head SHA; its timeline is
    read once per judge call (SEEN)."""
    listed = [entry for entry in run.get("pull_requests") or []
              if isinstance(entry, dict) and isinstance(entry.get("number"), int)
              and (entry.get("head") or {}).get("sha") in (None, sha)]
    if len(listed) != 1:
        return None
    number = listed[0]["number"]
    recorded = (listed[0].get("base") or {}).get("ref")
    if isinstance(recorded, str) and recorded and recorded != base:
        return number, recorded, f"run {run.get('id')} records base {recorded}"
    fired = created(run)
    if fired is None:
        return None
    key = ("timeline", number)
    if key not in seen:
        pages = github.json(f"repos/{repo}/issues/{number}/timeline?per_page=100", paginate=True)
        pages = pages if isinstance(pages, list) else [pages]
        seen[key] = [event for page in pages for event in (page if isinstance(page, list) else [page])
                     if isinstance(event, dict)]
    changed = sorted(when for event in seen[key] if event.get("event") == "base_ref_changed"
                     and (when := created(event)) is not None and when > fired)
    if not changed:
        return None
    return number, None, f"#{number}'s base was changed at {changed[0].isoformat().replace('+00:00', 'Z')}, after it"


def retargeted_red(repo: str, base: str, sha: str, name: str, job: dict, run: dict, github, seen: dict) -> str | None:
    """The audit line excusing red job NAME of RUN (its REST record) as a red from the pull request's old base by the
    rule above, or None so it is judged as before. The workflow is read before the timeline: a red whose workflow
    still runs for BASE costs no timeline read."""
    event, path = run.get("event"), str(run.get("path") or "").split("@", 1)[0]
    if event not in RETARGET_EVENTS or not path.startswith(".github/workflows/"):
        return None
    docs = [workflow_doc(repo, base, path, github)]
    if event == "pull_request":
        docs.append(workflow_doc(repo, sha, path, github))  # the merge commit's copy is the one GitHub reads
    if any(doc is None for doc in docs):
        return None
    filters = [filter_excludes(doc, event, base) for doc in docs]
    conditions = [job_base_condition(doc, name) for doc in docs]
    if all(filters):
        why = f"its workflow does not run for base {base} ({filters[0]})"
    elif all(condition not in (None, base) for condition in conditions):
        why = f"its job does not run for base {base} (if: github.event.pull_request.base.ref == '{conditions[0]}')"
    else:
        return None
    try:
        then = base_at_run(repo, base, sha, run, github, seen)
    except Refused:
        return None  # an unread timeline excuses nothing
    if then is None:
        return None
    number, old, how = then
    if old is None and conditions[0] not in (None, base):
        # The job ran (it is red), so its `base.ref == 'X'` held when the run fired.
        old, how = conditions[0], f"{how}; the job ran, so its if: held for {conditions[0]}"
    elif old is None and (only := single_branch(docs[0], event)) not in (None, base):
        # The run fired, so its base was the one branch the filter runs for.
        old, how = only, f"{how}; the run fired, so its base was the one branch its filter runs for"
    ran_for = f"ran for base {old}" if old else f"ran for #{number}'s earlier base"
    return (f"excused '{name}': run {run.get('id')} ({event}, job {job.get('id')}) {ran_for}, not {base} ({how}); "
            f"{why}, so no run will replace this red")


def one_judgement(function):
    """FUNCTION (judge) run in one judgement's read memo (JUDGEMENT_READS): every source is read once, however many
    excuse paths ask it. A judgement inside another (a derived status's parts) shares the outer one's."""
    @functools.wraps(function)
    def run(*args, **kwargs):
        if JUDGEMENT_READS.get() is not None:
            return function(*args, **kwargs)
        token = JUDGEMENT_READS.set({})
        try:
            return function(*args, **kwargs)
        except JobBudgetCut as cut:  # a read that never happened, from any path: the timed retry (job_budget)
            base = args[1] if len(args) > 1 else kwargs.get("base", "the base")
            raise Refused(cut_refusal(cut.name or "the base search", base, cut.reads)) from None
        finally:
            JUDGEMENT_READS.reset(token)
    return run


@one_judgement
def judge(repo: str, base: str, sha: str, runs: list[int], github, *, checks: list[str] = (),
          flake_state: dict | None = None, purpose: str | None = None) -> list[str]:
    """Audit lines for every excused failure; raises Refused on the first that is not, or RateLimitedRead
    when a read was rate-limited (no verdict on any red, so nothing below may excuse or charge one). PURPOSE is the
    caller's (PURPOSES; None is a land): only PER_STEP_PURPOSE gets the per-step reading (fixed_on_base_by_step)."""
    if purpose is not None and purpose not in PURPOSES:
        raise Refused(f"purpose {purpose!r} is not one of {', '.join(PURPOSES)}; nothing was judged")
    github = rate_limit_aware(github)
    sha = exact_sha(repo, sha, github)  # every compare below is with a job's full head_sha
    audit: list[str] = []
    base_jobs: dict[int, list[dict] | None] = {}
    job_reads: dict[int | str, int] = {}
    suites = SuiteChecks(github, repo)
    run_reads: dict = {}  # head_jobs' SEEN: the head's check runs, each run's workflow, each head's run list
    load_rollups(repo, base, github)
    # Where every base verdict below is read, chosen once, before any path (Evidence: the base's own, or a stacked
    # parent's head), and passed to each, so no path reads runs on its own (cmux#41235's review, F1 and F2).
    evidence = evidence_source(repo, base, github, run_reads)
    checks = list(checks)
    if repo in WS_CHECK_REPOS and (WS_CHECK in checks or not (runs or checks)):
        # Its one gate is a commit status judged per test (WS_CHECK); with no run or check named it is the one.
        checks = [name for name in checks if name != WS_CHECK]
        audit.extend(ws_check(repo, base, sha, github, evidence))
        if not (runs or checks):
            return audit
    derived: dict[str, list[Part]] = {}
    for name in [name for name in checks if name in DERIVED_STATUSES]:
        # A derived status is judged by its parts (DERIVED_STATUSES): each is judged here as if named on its own, by
        # a name that is one Actions job's or one status's at the head (derived_status_parts).
        derived[name] = derived_status_parts(repo, sha, name, github)
        checks = [check for check in checks if check != name]
        checks += [part.name for part in derived[name] if part.name not in checks]
    if not (runs or checks):
        # Asked about no red run or check: no failure, exit 0 (cmuxterm-hq#7234 at ce69ab6d, 16/16 green, exited 1
        # here as "no failed job found", and a merge check that asks about every head refused every green PR). A red
        # run or check that was named and shows no failed job is still refused below.
        return audit or [f"no red run or check named on {sha}: no failure to excuse"]
    rollup_jobs: list[dict] = []
    jobs = head_jobs(repo, sha, runs, checks, github, base=base, excused=audit, suites=suites, ignored=audit,
                     seen=run_reads, evidence=evidence, rollup_jobs=rollup_jobs)
    if not jobs and not audit:
        # A red run or check with no failed job to show has nothing the base can excuse.
        raise Refused("no failed job found on the head to compare with the base")
    # The shared generated-files check is judged after its host (generated_stale_host).
    jobs = sorted(jobs, key=lambda found: found.get("name") == GENERATED_VERDICT_JOB)
    pr_only: set[tuple] = set()  # (run id, job name) excused by pr_only_step_verdict
    for job in jobs:
        name = job.get("name", "")
        if (budget := job_budget()) is not None:
            budget["name"] = name  # whose judgement a JobBudgetCut cuts (one_judgement)
        if (name == GENERATED_VERDICT_JOB and job.get("conclusion") == "failure" and not refused_at_setup(job)
                and (host := shared_generated_host(repo, job, github)) is not None
                and (job.get("run_id"), host) in pr_only):
            audit.append(f"excused '{name}': its one red is the 'stale' verdict of '{host}', whose regeneration "
                         "failed only on base reds (excused above)")
            continue
        if (name == GENERATED_VERDICT_JOB and job.get("conclusion") == "failure" and not refused_at_setup(job)
                and (host := shared_catalog_host(repo, job, github)) is not None):
            audit.append(shared_catalog_verdict(repo, base, sha, name, job, host, github, evidence, base_jobs,
                                                job_reads, suites, run_reads))
            continue
        if job.get("conclusion") != "failure":
            if (cut := cut_short_web_verdict(repo, base, name, job, github, run_reads, evidence)) is not None:
                audit.append(cut)
                continue
            raise Refused(f"'{name}' is {job.get('conclusion')}: it has no verdict to compare with the base; re-run it")
        if refused_at_setup(job):
            raise Refused(f"'{name}' was refused at setup by its runner; it gets re-run, never excused")
        got = read_head(repo, base, sha, name, job, github, run_reads, evidence)
        if got.audit is not None:
            audit.append(got.audit)
            continue
        view, chromium_without_diagnostics = got.view, got.chromium_without_diagnostics
        early = signature(view)
        pinned, aside = (None, None)
        if early is not UNPLACED:
            head_steps, head_tests, head_errors = early
            # By (name, conclusion), counted (failed_step_keys), never the names signature() keeps.
            pinned, aside = ffi_pin_step_a(repo, base, sha, name, failed_step_keys(view.job),
                                           without_warn_only(view, head_errors), head_tests,
                                           crash_signals(view), github, seen=run_reads)
        elif got.unplaced is not None:
            # The pin's rules read this PR's paths, never the log's layout: an unplaced head is judged by them too.
            u = got.unplaced
            pinned, aside = ffi_pin_step_a(repo, base, sha, name, u.steps, set(u.errors), set(u.tests),
                                           set(u.crashes), github, seen=run_reads)
            pin = normalise_error(FFI_PIN_ERROR)
            if pinned is None and sum(n for error, n in u.errors.items() if error.startswith(pin)) == 1:
                # The whole log's error lines hold every step's, a passing one's too (cmux#40552: a next-batch line),
                # so read whole they may set the pin aside. When the jobs API fails the rollup alone, the rollup's own
                # list is the job's every red: the pin rule asks no more. Only its excuse is taken; a pin it sets
                # aside keeps the whole-log reading's verdict. Its annotation read is an extra one, asked only here:
                # one that fails (a 503) leaves the whole-log verdict standing, never a refusal of its own (review of
                # cmux#41151 at fd50c9b7, F1; OPTIONAL_READS).
                try:
                    rolled = rollup_signature(repo, job, github, run_reads)
                except Refused:
                    rolled = None
                if rolled is not None and any(step == FFI_PIN_CHECK for step, _ in rolled[0]):
                    pinned, _ = ffi_pin_step_a(repo, base, sha, name, rolled[0], rolled[1] | {pin}, set(),
                                               set(u.crashes), github, seen=run_reads)
        if pinned is not None:
            audit.append(pinned)
            continue
        workflow_info = run_reads.get(("run-record", job["run_id"]))
        if not isinstance(workflow_info, dict):
            workflow_info = rest_run(repo, job["run_id"], github, run_reads)
        workflow = workflow_info.get("workflow_id")
        if not isinstance(workflow, int):
            # never `actions/workflows/None/runs` (cmux#37033's 404): a run whose workflow is unread has no base
            raise Refused(f"'{name}': run {job['run_id']} came back without its workflow_id; nothing to compare "
                          "with the base")
        if (vrepo := evidence.verdict_repo) != repo:
            # The base verdict is another repo's (BASE_VERDICT_REPO), where this workflow has a different id: name it
            # by its file, which every base-run read takes. A run that came back without its workflow path cannot be
            # named there, so the search finds nothing and the no-verdict refusal below stands, naming that repo.
            if (file := workflow_file(workflow_info)) is None:
                raise Refused(f"'{name}': run {job['run_id']} came back without its workflow path, so its workflow "
                              f"cannot be named in {vrepo}, where {repo}'s {base} is verified; nothing to compare "
                              "with the base")
            workflow = file
        # This supplement uses only measured base observations with an active public quarantine issue. It can
        # bridge a green base run; it never changes the deterministic comparison when state is absent or invalid.
        known = ({} if view is UNPLACED
                 else test_reds.flaky_failures(view_text(view), name, workflow_info.get("name", ""), flake_state))
        if base == "feat-cmux-next" and quarantined_only(view, known):
            audit.append(f"excused '{name}': quarantined base flakes: "
                         + "; ".join(f"{test} ({why})" for test, why in sorted(known.items())))
            continue
        if (per_test := got.per_test(workflow_info)) is not None:
            audit.append(per_test)
            continue
        # The newest base run where this job has a verdict decides whether it is red on the base.
        verdicts = base_verdicts(repo, workflow, name, github, evidence, base_jobs, job_reads, suites)
        if (parent := evidence.parent) is not None:
            # A lane base heading an open PR: its verdicts are that PR's at its head (stacked_parent).
            verdicts = stacked_parent_verdicts(name, base, parent, verdicts,
                                               cut=lambda: search_cut(job_reads, name, workflow))
            audit.append(f"base for '{name}': {base} is open PR #{parent.number}'s head {parent.head[:12]}; its "
                         "checks there are the base verdicts below")
        base_run, base_job = next(verdicts, (None, None))
        base_workflow, base_name = workflow, name  # the workflow whose run gives the base verdict, and its check
        caller, caller_name = base_caller(repo, base, workflow_info, name, github) or (None, name)
        if caller is not None and (base_run is None or before_merge_base(repo, base, sha, base_run, github, evidence)):
            # The PR run's workflow has no base verdict at or after the merge-base: the post-merge batch tier's suite
            # that runs it (batch_check), or the workflow that runs the same called job on base pushes, may
            # (BASE_WORKFLOW_FOR). Its verdict decides only when it is at or after the merge-base, or when the PR's
            # workflow has none at all; else the stale one below refuses as before.
            pushed = base_verdicts(repo, caller, caller_name, github, evidence, base_jobs, job_reads, suites)
            pushed_run, pushed_job = next(pushed, (None, None))
            if pushed_run is not None and (
                    base_run is None or before_merge_base(repo, base, sha, pushed_run, github, evidence) is None):
                base_run, base_job, verdicts = pushed_run, pushed_job, pushed
                base_workflow, base_name = caller, caller_name
        # A quota-only red with no red base verdict to share is Infra (github_quota_only); a red base verdict keeps
        # its comparison below, which may excuse it as the base's.
        quota = github_quota_only(view) if base_run is None or base_job.get("conclusion") != "failure" else None
        if quota is not None:
            raise infra(name, job, f"its failed steps printed only GitHub's API rate-limit refusal {quota[:300]!r}")
        if base_run is None:
            if (old_base := retargeted_red(repo, base, sha, name, job, workflow_info, github, run_reads)) is not None:
                audit.append(old_base)  # a red from the pull request's old base (retargeted_red)
                continue
            if (asked := asks_only_rerun(view)) is not None:
                raise infra(name, job, f"its check could not run and printed only {asked!r}")
            shared, why_not = other_pr_setup_verdict(repo, base, name, job, got, workflow_info, workflow, github,
                                                     run_reads, evidence)
            if shared:
                audit.append(why_not)  # a setup red other PRs share (other_pr_setup_verdict)
                continue
            peers, why_not_peers = other_pr_peer_verdict(repo, base, name, job, workflow_info, workflow, github)
            if peers:
                audit.append(why_not_peers)  # the workflow's red on other PRs' heads (other_pr_peer_verdict)
                continue
            # Every workflow searched: the PR run's, and the base caller's (searched whenever it has one here, since
            # the PR run's workflow gave no verdict), not only the one that gave a verdict (#47687's review F1).
            if (cut := search_cut_any(job_reads, (workflow, name), (caller, caller_name))) is not None:
                raise Refused(cut_refusal(name, base, cut))
            dispatch = base_dispatch(repo, base, workflow_info, evidence.runs(workflow), github)
            raise Refused(f"'{name}': no {base} run of its workflow has a verdict for it to compare with "
                          + (f"in {vrepo}, where {repo}'s {base} is verified (BASE_VERDICT_REPO), "
                             if vrepo != repo else "")
                          + f"(read the {BASE_RUNS_PAGE} newest, up to {BASE_JOB_READS} job lists, "
                          f"and its tip suite runs)" + (f": {dispatch}" if dispatch else "")
                          + f"; not a setup red other PRs share: {why_not}"
                          + f"; not the workflow's red on other PRs: {why_not_peers}")
        if name == GUARD_GROUP_JOB:
            audit.append(guard_group(repo, base, name, job, view, base_run, base_job, github, sha, run_reads))
            continue
        if journey_job(name, workflow_info) and base_job.get("conclusion") == "failure":
            audit.append(journey(repo, base, name, job, view, base_run, base_job, github, sha, run_reads))
            continue

        def by_step() -> str:
            # The per-step reading (fixed_on_base_by_step), tried once the job-level reads do not excuse the red, and
            # only for update_branch's base merge: a land never gets it.
            if purpose != PER_STEP_PURPOSE:
                raise Refused(f"the per-step reading is for --purpose {PER_STEP_PURPOSE} alone (a base merge that "
                              f"reruns CI), never for a land (purpose {purpose or 'land'})")
            return fixed_on_base_by_step(repo, base, sha, name, job, view, workflow_info, base_run, base_job, github,
                                         base_jobs=base_jobs, run_reads=run_reads,
                                         others=jobs, evidence=evidence, suites=suites,
                                         base_workflow=base_workflow, base_name=base_name,
                                         verdict_repo=vrepo)
        if base_job.get("conclusion") != "failure":
            try:
                audit.append(fixed_on_base(repo, base, sha, name, view, base_run, github, evidence,
                                           verdict_repo=vrepo))
            except Refused as why:
                try:
                    audit.append(by_step())
                    continue
                except Refused as step_why:
                    why = Refused(f"{why}; per step: {step_why}")
                # A green verdict that skipped a step the head failed: that step may be the PR-only kind
                # (pr_only_step_verdict), red here only on tests another base job fails (the menu cap deadlock,
                # 2026-11-11: cmux#41086, #40991). A green job has no failed step, test or error line of its own.
                if got.unplaced is not None and (only := pr_only_step_verdict(
                        vrepo, base, name, got.unplaced,
                        [(base_run, base_job, UnplacedSignature(Counter(), Counter(), Counter()))],
                        evidence.runs(workflow), base_jobs, github)) is not None:
                    audit.append(only)
                    pr_only.add((job.get("run_id"), name))
                    continue
                # Or a step the green verdict skipped, red only on compiler errors another red base job prints in
                # files this PR does not change (compile_errors_verdict; cmux#40935's acpmux simulation clippy step).
                if aside is None and (same := compile_errors_verdict(
                        repo, base, sha, name, job, view, got.compile, got.unplaced, base_job, evidence.runs(workflow),
                        base_jobs, github, run_reads, verdict_repo=vrepo)) is not None:
                    audit.append(same)
                    continue
                if purpose == PER_STEP_PURPOSE:
                    try:
                        audit.append(green_since(repo, base, sha, name, job, workflow_info, base_run, base_job,
                                                 github, evidence, verdict_repo=vrepo))
                        continue
                    except Refused as green_why:
                        why = Refused(f"{why}; green since: {green_why}")
                if (stale := before_merge_base(repo, base, sha, base_run, github, evidence)) is not None:
                    dispatch = base_dispatch(repo, base, workflow_info, evidence.runs(workflow), github)
                    raise Refused(f"'{name}' has no {base} verdict at or after this PR's merge-base yet: the newest, "
                                  f"a pass in run {base_run['id']}, {stale}; re-check once a {base} run at or after "
                                  "the merge-base has a verdict for it" + (f": {dispatch}" if dispatch else "")
                                  ) from None
                raise Refused(f"'{name}' is not red on {base} run {base_run['id']} ({base_job.get('conclusion')}), "
                              f"{workflow_label(base_run, base_workflow)}, the base's run of the head's red in run "
                              f"{job.get('run_id')} ({workflow_label(workflow_info, workflow)}), "
                              f"and not fixed on base: {why}; fix it on this head") from None
            continue
        bare = view is not UNPLACED and got.unplaced is not None
        if bare and aside is None:
            head = signature(view)
            bare = not head[1] and not head[2]
        why_whole = UNPLACED_WHY if view is UNPLACED else BARE_WHY
        if view is UNPLACED or bare:
            # An unplaced head is read per step first (update-branch alone: by_step refuses a land), then compared
            # whole with the base (#41129, carried forward): within one red base verdict. So is a placed head
            # whose failed sections name nothing to compare (BARE_WHY).
            try:
                audit.append(by_step())
                continue
            except Final:
                raise
            except Refused as why:
                per_step = why
            try:
                # Why: UnplacedSignature (compared whole, excused only within one red base verdict of the window)
                if got.unplaced is None:
                    raise Refused(f"'{name}': {why_whole}; nothing is compared with the base")
                # A pin red ffi_pin_step_a did not excuse or set aside raised there; one it set aside leaves the
                # comparison. Never compared by identity: the masked pin error is the same for any pin.
                mine = unplaced_without_ffi_pin(got.unplaced) if aside is not None else got.unplaced
                pin = normalise_error(FFI_PIN_ERROR)
                if name == FFI_PIN_JOB and any(error.startswith(pin) for error in mine.errors):
                    raise Refused(f"'{name}': {UNPLACED_WHY}, and its app FFI pin is red where no pin rule covers it; "
                                  "nothing is compared with the base")
                # The window the placed comparison reads (BASE_WINDOW verdicts within BASE_WINDOW_HOURS of the newest,
                # a green one ends it): within any one red verdict in it, never a mix of several. cmux#41086 at
                # 5d0fb077: the newest base run had one more failing test than the head (a pre-push gate flake).
                newest, read, seen, newest_job = created(base_run), 1, [], base_job
                while True:
                    try:
                        theirs = unplaced_base_evidence(vrepo, base_job, github)
                        # A pin the rules set aside leaves both sides: the base's own pin red (cmux#41086's base) is no
                        # difference, and identity still holds for all the rest.
                        theirs = unplaced_without_ffi_pin(theirs) if aside is not None else theirs
                        seen.append((base_run, base_job, theirs))
                        audit.append(unplaced_verdict(vrepo, name, base, mine, theirs, base_run, why=why_whole)
                                     + (f"; {aside}" if aside is not None else ""))
                        break
                    except Final:
                        raise
                    except Refused as mismatch:
                        run, found = next(verdicts, (None, None)) if read < BASE_WINDOW else (None, None)
                        if (run is None or found.get("conclusion") != "failure"
                                or (newest and created(run)
                                    and newest - created(run) > timedelta(hours=BASE_WINDOW_HOURS))):
                            if (only := pr_only_step_verdict(vrepo, base, name, mine, seen,
                                                             evidence.runs(workflow),
                                                             base_jobs, github)) is not None:
                                audit.append(only + (f"; {aside}" if aside is not None else ""))
                                pr_only.add((job.get("run_id"), name))
                                break
                            if aside is None and (same := compile_errors_verdict(
                                    repo, base, sha, name, job, view, got.compile, got.unplaced, newest_job,
                                    evidence.runs(workflow), base_jobs, github, run_reads,
                                    verdict_repo=vrepo)) is not None:
                                audit.append(same)
                                break
                            # Out of verdicts because the cap cut the search, with older runs unread (#47971's review
                            # F1, as the placed window's F3): an older red matching the whole head may be among them.
                            if (run is None and read < BASE_WINDOW
                                    and (cut := search_cut_any(job_reads, (workflow, name),
                                                               (base_workflow, base_name))) is not None):
                                raise Refused(f"{cut_refusal(name, base, cut)}; the newest so far: "
                                              f"{mismatch}") from None
                            # Last, so it pre-empts no excuse: a refusal that says the base ran and passed the check
                            # the head fails, and to merge the base (passed_on_base_verdict).
                            passed_on_base_verdict(vrepo, base, name, mine, seen, github)
                            raise
                        read += 1
                        base_run, base_job = run, found
                continue
            except Final:
                raise
            except Refused as why:
                raise Refused(f"{why}; per step: {per_step}") from None
        head = signature(view)
        if head is UNPLACED:  # refused above: never, and never compared if it were
            raise Refused(f"'{name}': {UNPLACED_WHY}; nothing is compared with the base")
        if aside is not None:
            head = without_ffi_pin(head)
        if not head[1] and not head[2] and not crash_signals(view) and not chromium_without_diagnostics:
            raise Refused(f"'{name}': no failing test or error line to match; nothing to compare with the base")
        # The window: the newest verdict first, then older red ones, up to BASE_WINDOW verdicts within
        # BASE_WINDOW_HOURS of it, read only while a head failure is on none so far. A green verdict ends it.
        def red(run: dict, found: dict) -> tuple:
            return base_evidence(vrepo, base, name, run, found, github, run_reads)
        try:
            window, newest, read = [red(base_run, base_job)], created(base_run), 1
        except BaseUnplaced as unplaced:
            # The newest red base verdict's log is not placed (hq#13746): this head is compared whole with it, as an
            # unplaced head is (unplaced_verdict, only within it), then per step; never refused as the head's own.
            mine = unplaced_head_evidence(repo, job, github)
            theirs = unplaced_base_evidence(vrepo, base_job, github)
            if aside is not None:
                mine, theirs = unplaced_without_ffi_pin(mine), unplaced_without_ffi_pin(theirs)
            try:
                # Only by failing tests named: a passing base step can print the head's error line (an expected-failure
                # check), which a whole base log cannot tell from a failure (#40542's fourth Codex BLOCK, F2). The tests
                # are the placed head's own failed steps' (HEAD), never a passing step's line in its whole log (review
                # F1 on #46811 at 5d7cb257).
                if not head[1]:
                    raise Refused(f"'{name}': {BASE_UNPLACED_WHY}, and this head's failed steps name no failing test, "
                                  "so its error lines are not compared with a whole base log")
                audit.append(unplaced_verdict(vrepo, name, base, mine, theirs, base_run, why=BASE_UNPLACED_WHY)
                             + (f"; {aside}" if aside is not None else ""))
                continue
            except Final:
                raise
            except Refused as whole:
                try:
                    audit.append(by_step())
                    continue
                except Final:
                    raise
                except Refused as step_why:
                    raise Refused(f"{whole}; per step: {step_why}; {unplaced}") from None
        while True:
            try:
                audit.append(compare_window(vrepo, base, name, head, view, window, chromium_without_diagnostics,
                                            flake_state=flake_state, workflow=workflow_info.get("name", ""),
                                            head_pairs=step_errors(view))
                             + (f"; {aside}" if aside is not None else ""))
                break
            except Final:
                raise
            except Refused as why:
                run, found = next(verdicts, (None, None)) if read < BASE_WINDOW else (None, None)
                if (run is None or found.get("conclusion") != "failure"
                        or (newest and created(run) and newest - created(run) > timedelta(hours=BASE_WINDOW_HOURS))):
                    # Out of verdicts because the cap cut the search, with older runs unread (#47687's review F3):
                    # an older matching red may be among them, so not a verdict either way.
                    cut = (search_cut_any(job_reads, (workflow, name), (base_workflow, base_name))
                           if run is None and read < BASE_WINDOW else None)
                    if aside is not None:  # the step-A pin rule set its red aside: judged as before
                        if cut is not None:
                            raise Refused(f"{cut_refusal(name, base, cut)}; the newest so far: {why}") from None
                        raise
                    # BASE_JOB: the newest verdict's job, as read from the jobs API (never the window's view).
                    if (same := compile_errors_verdict(repo, base, sha, name, job, view, got.compile, got.unplaced,
                                                       base_job, evidence.runs(workflow), base_jobs, github,
                                                       run_reads, verdict_repo=vrepo)) is not None:
                        audit.append(same)
                        break
                    try:
                        audit.append(by_step())
                        break
                    except Refused as step_why:
                        if cut is not None:
                            raise Refused(f"{cut_refusal(name, base, cut)}; the newest so far: {why}; per step: "
                                          f"{step_why}") from None
                        raise Refused(f"{why}; per step: {step_why}") from None
                read += 1
                try:
                    window.append(red(run, found))
                except BaseUnplaced:
                    pass  # an older verdict not placed adds nothing to compare; the window reads on
    # A red run rollup is named by its own line once every failed job under its needs is excused (run_rollup_line).
    named_rollups: set = set()
    for rollup in rollup_jobs:
        if rollup.get("id") not in named_rollups:
            named_rollups.add(rollup.get("id"))
            audit.append(run_rollup_line(repo, rollup, audit, jobs))
    # A status judged by its job (status_job) is named too, the way land-judge reads the head's reds: by the
    # status's own context. Every job above was excused or ignored, or judge() raised.
    for job in jobs:
        for context in job.get("status_contexts", ()):
            name = job.get("name", "")
            verb = next((line.split(" ", 1)[0] for line in reversed(audit)
                         if line.startswith((f"excused '{name}'", f"ignored '{name}'"))), "excused")
            audit.append(f"{verb} '{context}': its status is the verdict of job '{name}' {job['id']} in run "
                         f"{job.get('run_id')}, {verb} above")
    for name, parts in derived.items():
        audit.append(derived_status_line(repo, name, sha, parts, audit, jobs))
    return audit


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    if argv is None:
        argv = sys.argv[1:]
    if argv == ["--write-rollups"]:
        ROLLUPS_FILE.write_text(json.dumps(derive_rollups(), indent=2, sort_keys=True) + "\n")
        GUARD_JOBS_FILE.write_text(json.dumps(derive_guard_jobs(), indent=2, sort_keys=True) + "\n")
        return 0
    parser.add_argument("--repo", required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--run", type=int, action="append", default=[], help="a failed workflow run on the head")
    parser.add_argument("--check", action="append", default=[], help="a red required check on the head")
    parser.add_argument("--purpose", choices=PURPOSES,
                        help=f"the caller's: {PER_STEP_PURPOSE} (the lane broker's update_branch guard, whose base merge "
                             "only reruns CI) may get the per-step reading; land (land-judge, the default) never does")
    parser.add_argument("--flake-state", help="tap-tests/v1 JSON; TAP_TESTS_STATE=off disables base-flake quarantine")
    parser.add_argument("--ws-check-verdict", action="store_true",
                        help="print ws_check_red's verdict on the head's ws-check as JSON (the lane-gh broker's "
                             "update_branch guard reads it); exit 0 with it, else as a judge")
    args = parser.parse_args(argv)
    if PLACEHOLDER_SHA.fullmatch(args.sha) and os.environ.get("BASE_RED_EXCUSE_FIXTURE_SHA") != "1":
        print(f"not excused: --sha {args.sha} is a placeholder, not a commit; nothing was read", file=sys.stderr)
        return 1
    limit = deadline_seconds()
    previous = signal.signal(signal.SIGALRM, _past_deadline) if hasattr(signal, "SIGALRM") else None
    if previous is not None:
        signal.alarm(limit)
    try:
        if args.ws_check_verdict:
            if args.repo not in WS_CHECK_REPOS:
                raise Refused(f"{args.repo} has no '{WS_CHECK}' status to judge")
            github = rate_limit_aware(GitHub())
            audit = [json.dumps(ws_check_red(args.repo, args.base, exact_sha(args.repo, args.sha, github), github,
                                             evidence_source(args.repo, args.base, github, {})), sort_keys=True)]
        else:
            audit = judge(args.repo, args.base, args.sha, args.run, GitHub(), checks=args.check,
                          flake_state=test_reds.load_flake_state(args.flake_state, fetch=True), purpose=args.purpose)
    except JobRateLimited as error:
        print(f"job-rate-limited: {error}", file=sys.stderr)
        return 3
    except rate_limited_classes() as error:
        print(f"rate-limited: {error}", file=sys.stderr)
        return 3
    except Infra as error:
        print(f"not excused: infra, not a verdict: {error}", file=sys.stderr)
        return 1
    except FixedOnBase as error:
        print(str(error), file=sys.stderr)  # "fixed on base by <commit>: update the branch: ..."
        return 1
    except (Refused, KeyError, ValueError) as error:
        print(f"not excused: {error}", file=sys.stderr)
        return 1
    except Deadline:
        print(f"not excused: infra, not a verdict: ran past its {limit} s deadline", file=sys.stderr)
        return 1
    finally:
        if previous is not None:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, previous)
    print("\n".join(audit))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
