#!/usr/bin/env python3
"""Nightly speed budget for cmux NEXT: one timing record per published nightly-next build, a check of each against
the budget and every stage's trailing median, and one cmuxterm-hq issue that keeps the verdict and the history.

Leo, 2026-11-12: "we need to start freaking enforcing, like, the speed, you know?" The budget is merge to feed: from
the landing of a nightly's head commit on feat-cmux-next (its committer time on the first-parent line) to the end of
its appcast upload, p95 under BUDGET_MIN (30 min). The 8 builds published on 2026-11-12 took p50 104 min, p95 151;
the job-started hook (step "Set up runner") alone held jobs on cmux15 up to 23.5 min each, so a record keeps every
job's queue time (started - created) and hook time with its runner host, not only the stage walls.

A nightly is two nightly.yml runs. A push to nightly-next starts the push run, which builds; its job
dispatch-nightly-next-sign dispatches the sign run, titled "Sign nightly-next run <push run> attempt <N>", which
signs, notarizes, verifies and publishes. The feed time is the end of step FEED_STEP in the sign run's job
publish-nightly, and the build number is <push run><attempt as 2 digits>. The stages, in minutes (STAGES):

  promote        head landing on feat-cmux-next -> push run created (the promotion tick)
  a_push_wait    push run created -> its first job created (the push concurrency group)
  b_pre_build    first job created -> build-nightly-app started (decide, runner picks, inputs)
  c_build        build-nightly-app, start to end; c1_compile is its step BUILD_STEP
  d_build_tail   build-nightly-app end -> dispatch-nightly-next-sign end
  e_sign_wait    dispatch end -> the sign run's first job created (the sign concurrency group)
  f_pre_sign     sign run's first job created -> build-sign-notarize-nightly started
  g_sign         build-sign-notarize-nightly, start to end; g1_notarize is its step NOTARIZE_STEP
  h_verify       sign job end -> publish-nightly started (the verify jobs and the publish queue)
  i_publish      publish-nightly started -> feed time
  job:<name>     every job that ran, start to end, by its name in the run; a sign-run job whose name the push run
                 also has is job:<name> (sign run), and a name repeated in one run is numbered #2, #3 by start

A one-job nightly is one run: the push run itself uploads the feed and no sign run names it. It is found as a push
run that succeeded with no sign run, and its record carries promote, a_push_wait, then:

  b_pre_build    first job created -> the job with FEED_STEP started
  j_one_job      that job started -> feed time; c1_compile and g1_notarize are its steps, when it has them
  step:<name>    every step of that job that took STEP_FLOOR_MIN or more

The named stages follow today's job graph; the job:<name> walls follow whatever jobs a run has, so when the
pipeline changes shape (build, sign, notarize and publish in one job on one Mac is next) its new jobs are recorded
and judged with no change here, and a named stage a run does not have is left out, never an error. The feed step
is looked for in publish-nightly first, then in any job of the run that dispatched or published it.

    nightly_speed.py record --out STATE.json [--repo manaflow-ai/cmux] [--hq-repo manaflow-ai/cmuxterm-hq]
                            [--newest 8] [--git-dir .] [--base-ref origin/feat-cmux-next]
    nightly_speed.py check --state STATE.json [--json OUT.json] [--md OUT.md]
    nightly_speed.py issue --state STATE.json [--hq-repo manaflow-ai/cmuxterm-hq]

`record` reads the history kept in the hq issue (HQ_GH_TOKEN, issues read; none leaves it empty and says why), then
one list of nightly.yml's newest runs on nightly-next (GH_TOKEN, actions read; push and sign runs in one page), and
for each completed sign run not yet recorded (the newest --newest) the two jobs lists of its attempt and of its push
run's attempt: nothing more when nothing is new. A sign run that did not publish (failed, or cancelled when a newer
one replaced it) costs no read past the list: it is one line with its conclusion and the minutes it was open in the
sign group (created -> completed), the waste account. Such a run is read again when it is re-run (a higher attempt).
A run that started before the oldest record is not read; "started" is its newest attempt's (run_started_at), since a
rerun keeps the run's created_at.

`check` judges the newest record. Over budget: merge_to_feed over BUDGET_MIN. A stage is slow when it is over
SLOW_RATIO (1.5) x its median over the TRAILING (20) records before it AND at least SLOW_FLOOR_MIN (1 min) over
that median: the floor keeps a 4 s stage from alarming at 7 s. A median needs MIN_TRAILING records. The diff is
against the last fast run (the newest earlier record in budget with no slow stage; the fastest recorded one when
none was): per-stage deltas, runner host changes, hook and queue wait deltas by host, and the commit range between
the two heads. When one stage was slow in BISECT_AFTER (3) consecutive records it adds a bisect: the run history
is complete (every published build is recorded), so this is a change-point search over the recorded runs, not a
rebuild of intermediate commits. The change point is the last record where the stage was not slow and the first
of the slow streak; between their heads it lists the commits that touch the pipeline (PIPELINE_PATHS), and for the
compile stages the count of changed Swift and Rust files by top-level directory.

`issue` opens or updates the one open cmuxterm-hq issue titled ISSUE_TITLE that carries ISSUE_MARK (the pattern of
scripts/cmux-next/quality-report.py's sticky): the verdict, the diff, the bisect, a table of the newest TABLE_ROWS
nightlies, the unpublished sign runs, and the history as a hidden comment that `record` and the quality report read:
its JSON document, zlib-compressed and base64 on one line (HISTORY_Z_RE; the plain JSON of HISTORY_RE, the first
form, is still read). It holds the newest HISTORY_KEEP records with the body under BODY_LIMIT: when it is over, the
oldest records go down to TRAILING + BISECT_AFTER, then every record's per-job detail, then older records below that
floor, and the unpublished lines only when no record is left, so the issue can always be written. What is read back
is checked (sound_record, sound_unpublished): the issue is editable text, so valid JSON of another shape is an empty
history and a record of another shape is dropped, never an exception. It re-reads the issue right
before writing and merges its history, so a failed read in `record` never drops history. In budget, the same issue
says so. Nothing here gates a nightly: nightly-speed.yml is its own workflow and nothing needs it.

Tests: tests/test_nightly_speed.py (no network; gh and git are fakes or a temporary repository).
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import os
import re
import subprocess
import sys
import zlib
from typing import Any, Callable, Dict, List, Optional, Tuple

SCHEMA = 1
REPO = "manaflow-ai/cmux"
HQ_REPO = "manaflow-ai/cmuxterm-hq"
WORKFLOW = "nightly.yml"
BRANCH = "nightly-next"
BASE_REF = "origin/feat-cmux-next"
BUDGET_MIN = 30.0
SLOW_RATIO = 1.5
SLOW_FLOOR_MIN = 1.0
TRAILING = 20
MIN_TRAILING = 5
BISECT_AFTER = 3
# Sign runs handled per record call: a push to nightly-next comes about once per landing, so a handful catches up
# after a quiet spell, and a first run with no history reads at most 2 x NEWEST jobs lists.
NEWEST = 8
# 100 runs of nightly.yml on nightly-next spanned 10 h on 2026-11-12 (74 push runs, 18 sign runs).
LIST_PAGE = 100
ISSUE_TITLE = "cmux NEXT nightly speed budget"
ISSUE_MARK = "<!-- cmux-next-nightly-speed -->"
HISTORY_RE = re.compile(r"<!-- nightly-speed-history: (\{.*?\}) -->", re.S)
HISTORY_Z_RE = re.compile(r"<!-- nightly-speed-history-z: (.*?) -->", re.S)
# The most a compressed history may inflate to: the history inflates about 7 times, so a whole body of it stays
# under 0.5 MB, and a hostile body costs no more memory than this.
INFLATE_CAP = 4_000_000
# An issue body holds 65536 characters. Build 4318547490101's record is 3.8 KB of JSON with its 33 jobs and 2.1 KB
# without, so per-job detail stays on the newest JOBS_KEEP records and the others keep their per-host sums. 40 such
# records (twice the trailing window), every wall and wait varied, are 93 KB of JSON and a 12.9 KB compressed comment,
# a 17.9 KB body: room for the visible report (VISIBLE_RESERVE) and for records several times larger.
HISTORY_KEEP = 40
JOBS_KEEP = 6
UNPUBLISHED_KEEP = 40
BODY_LIMIT = 60000
VISIBLE_RESERVE = 16000
TABLE_ROWS = 20
COMMITS_SHOWN = 15
FEED_STEP = "Upload nightly-next appcasts to R2"
BUILD_STEP = "Build nightly app (Release)"
NOTARIZE_STEP = "Notarize app ticket through final DMG"
HOOK_STEP = "Set up runner"
SIGN_RE = re.compile(r"^Sign nightly-next run (\d+) attempt (\d+)$")
SHA_RE = re.compile(r"^[0-9a-f]{7,40}$")
# A one-job nightly's steps are its stages. One under this many minutes is left out of the record (the history is
# one issue body), and a slow one still shows in the job's own wall.
STEP_FLOOR_MIN = 0.2
# (key, label, nested): a nested stage is a step inside the stage before it, so it is left out of sums and of the
# quality report's largest stage.
STAGES: List[Tuple[str, str, bool]] = [
    ("promote", "promote (landing -> push run)", False),
    ("a_push_wait", "a push-group wait", False),
    ("b_pre_build", "b pre-build", False),
    ("c_build", "c build job", False),
    ("c1_compile", "c1 compile step", True),
    ("d_build_tail", "d build tail + dispatch", False),
    ("e_sign_wait", "e sign-group wait", False),
    ("f_pre_sign", "f pre-sign", False),
    ("g_sign", "g sign job", False),
    ("g1_notarize", "g1 notarize step", True),
    ("h_verify", "h verify + publish queue", False),
    ("i_publish", "i publish to feed", False),
    ("j_one_job", "j one job (start -> feed)", False),
]
STAGE_LABEL = {k: label for k, label, _ in STAGES}
TOP_STAGES = [k for k, _, nested in STAGES if not nested]
COMPILE_STAGES = {"c_build", "c1_compile"}
PIPELINE_PATHS = [".github/workflows/nightly.yml", "scripts/ci/", "scripts/cmux-next/"]
CODE_SUFFIXES = (".swift", ".rs")


class SourceError(Exception):
    """A source that could not be read; its message is the report's `why`."""


def ts(text: Optional[str]) -> Optional[float]:
    if not text:
        return None
    try:
        return dt.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def iso(t: Optional[float]) -> Optional[str]:
    return None if t is None else dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def minutes(a: Optional[float], b: Optional[float]) -> Optional[float]:
    return None if a is None or b is None else round((b - a) / 60, 2)


def quantile(values: List[float], p: float) -> Optional[float]:
    """Linear interpolation between closest ranks (the measurement script's, so the numbers match it)."""
    v = sorted(values)
    if not v:
        return None
    k = p * (len(v) - 1)
    lo = int(k)
    hi = min(lo + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (k - lo)


def host_of(runner_name: Optional[str]) -> str:
    """The machine of a runner: cmux15-glaeda-nightly-only-4 -> cmux15; a hosted runner is github-hosted."""
    name = runner_name or ""
    if not name:
        return "?"
    if name.startswith("GitHub Actions"):
        return "github-hosted"
    return re.sub(r"-glaeda.*$", "", name)


# GitHub and git

def gh_api(path: str, token: Optional[str], run: Callable = subprocess.run) -> Any:
    """One `gh api` GET on the given token (GH_TOKEN for the call only)."""
    if not token:
        raise SourceError(f"no token for {path}")
    env = {**os.environ, "GH_TOKEN": token}
    try:
        done = run(["gh", "api", path], capture_output=True, text=True, timeout=90, env=env)
    except (OSError, subprocess.SubprocessError) as e:
        raise SourceError(f"gh could not read {path}: {e}") from e
    if done.returncode != 0:
        raise SourceError(f"gh could not read {path}: " + " ".join((done.stderr or done.stdout).split())[:240])
    try:
        return json.loads(done.stdout or "null")
    except ValueError as e:
        raise SourceError(f"gh returned no JSON for {path}: {e}") from e


def git(git_dir: str, args: List[str], run: Callable = subprocess.run) -> Optional[str]:
    try:
        done = run(["git", "-C", git_dir] + args, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout if done.returncode == 0 else None


def landing_times(git_dir: str, base_ref: str, run: Callable = subprocess.run) -> Dict[str, float]:
    """Committer time of each commit on the base branch's first-parent line (a landing), by sha."""
    out = git(git_dir, ["log", "--first-parent", "-n", "3000", "--format=%H %ct", base_ref], run) or ""
    times: Dict[str, float] = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].isdigit():
            times[parts[0]] = float(parts[1])
    return times


# One record

def find_job(jobs: List[Dict[str, Any]], name: str) -> Optional[Dict[str, Any]]:
    """The first job that ran under `name`, or a matrix leg of it ("build-sign-notarize-nightly (arm64)")."""
    for j in jobs:
        n = j.get("name") or ""
        if (n == name or n.startswith(name + " (")) and j.get("conclusion") != "skipped":
            return j
    return None


def find_step(job: Optional[Dict[str, Any]], name: str) -> Optional[Dict[str, Any]]:
    for s in (job or {}).get("steps") or []:
        if s.get("name") == name:
            return s
    return None


def span(item: Optional[Dict[str, Any]]) -> Optional[float]:
    if not item:
        return None
    return minutes(ts(item.get("started_at")), ts(item.get("completed_at")))


def job_lines(jobs: List[Dict[str, Any]]) -> List[List[Any]]:
    """[name, host, queue min, hook min] per job that ran: the waits a stage wall hides."""
    out = []
    for j in jobs:
        if j.get("conclusion") == "skipped" or not j.get("started_at"):
            continue
        hook = span(find_step(j, HOOK_STEP))
        out.append([(j.get("name") or "?")[:60], host_of(j.get("runner_name")),
                    minutes(ts(j.get("created_at")), ts(j.get("started_at"))), hook])
    return out


def host_sums(lines: List[List[Any]]) -> Dict[str, List[Any]]:
    """{host: [jobs, queue min, hook min, longest hook min]}."""
    out: Dict[str, List[Any]] = {}
    for _, host, queue, hook in lines:
        h = out.setdefault(host, [0, 0.0, 0.0, 0.0])
        h[0] += 1
        h[1] = round(h[1] + (queue or 0), 2)
        h[2] = round(h[2] + (hook or 0), 2)
        h[3] = max(h[3], hook or 0)
    return out


def build_record(sign: Dict[str, Any], push: Dict[str, Any], sign_jobs: List[Dict[str, Any]],
                 push_jobs: List[Dict[str, Any]], landed: Optional[float]) -> Tuple[Optional[Dict[str, Any]], Optional[str]]:
    """The timing record of one published nightly, or (None, why) when its sign run has no feed upload. A one-job
    nightly has no sign run: its push run uploads the feed, and is passed as `sign` too, with no sign jobs."""
    one_job = sign.get("id") == push.get("id")
    m = SIGN_RE.match(sign.get("display_title") or "")
    feed_jobs = push_jobs if one_job else sign_jobs
    pub = find_job(feed_jobs, "publish-nightly")
    feed_step = find_step(pub, FEED_STEP)
    if not feed_step:  # a reshaped pipeline: the upload in any job of the run
        pub = next((j for j in feed_jobs if find_step(j, FEED_STEP)), None)
        feed_step = find_step(pub, FEED_STEP)
    if not (m or one_job) or not feed_step or feed_step.get("conclusion") != "success" \
            or not ts(feed_step.get("completed_at")):
        return None, "no feed upload"
    push_run, push_attempt = (int(m.group(1)), int(m.group(2))) if m else (push.get("id"), push.get("run_attempt") or 1)
    feed = ts(feed_step["completed_at"])
    p_created = ts(push.get("created_at"))
    s_created = ts(sign.get("created_at"))
    p_first = min((t for t in (ts(j.get("created_at")) for j in push_jobs) if t), default=None)
    s_first = min((t for t in (ts(j.get("created_at")) for j in sign_jobs) if t), default=None)
    build = find_job(push_jobs, "build-nightly-app")
    dispatch = find_job(push_jobs, "dispatch-nightly-next-sign")
    signer = find_job(sign_jobs, "build-sign-notarize-nightly")
    b_start, b_end = ts((build or {}).get("started_at")), ts((build or {}).get("completed_at"))
    d_end = ts((dispatch or {}).get("completed_at"))
    g_start, g_end = ts((signer or {}).get("started_at")), ts((signer or {}).get("completed_at"))
    pub_start = ts((pub or {}).get("started_at"))
    stages = {
        "promote": minutes(landed, p_created),
        "a_push_wait": minutes(p_created, p_first),
        "b_pre_build": minutes(p_first, b_start),
        "c_build": minutes(b_start, b_end),
        "c1_compile": span(find_step(build, BUILD_STEP)),
        "d_build_tail": minutes(b_end, d_end),
        "e_sign_wait": minutes(d_end, s_first),
        "f_pre_sign": minutes(s_first, g_start),
        "g_sign": minutes(g_start, g_end),
        "g1_notarize": span(find_step(signer, NOTARIZE_STEP)),
        "h_verify": minutes(g_end, pub_start),
        "i_publish": minutes(pub_start, feed),
    }
    if one_job:
        # One job builds, signs and publishes: the wait for it, its wall up to the feed, and its steps. The compile
        # and notarize steps keep their names so their medians carry over from the two-run pipeline.
        stages = {"promote": stages["promote"], "a_push_wait": stages["a_push_wait"],
                  "b_pre_build": minutes(p_first, pub_start), "j_one_job": minutes(pub_start, feed),
                  "c1_compile": span(find_step(pub, BUILD_STEP)), "g1_notarize": span(find_step(pub, NOTARIZE_STEP))}
        for step in (pub or {}).get("steps") or []:
            wall = span(step) if step.get("conclusion") != "skipped" else None
            if wall is not None and wall >= STEP_FLOOR_MIN and step.get("name") not in (BUILD_STEP, NOTARIZE_STEP):
                stages.setdefault(f"step:{(step.get('name') or '?')[:60]}", wall)
    # Both runs have jobs of one name (build-nightly-app), and a matrix repeats one in a run: the push run's first keeps
    # the plain key (the history's), a sign run's copy says so, and later ones are numbered in start order.
    push_names = {(j.get("name") or "?")[:60] for j in push_jobs}
    for run_jobs, suffix in ((push_jobs, ""), (sign_jobs, " (sign run)")):
        count: Dict[str, int] = {}
        for j in sorted(run_jobs, key=lambda j: (j.get("started_at") or "", j.get("name") or "")):
            wall = span(j) if j.get("conclusion") != "skipped" else None
            if wall is None:
                continue
            name = (j.get("name") or "?")[:60]
            n = count[name] = count.get(name, 0) + 1
            stages[f"job:{name}{suffix if name in push_names else ''}{f' #{n}' if n > 1 else ''}"] = wall
    lines = job_lines(push_jobs) + job_lines(sign_jobs)
    return {
        "build": f"{push_run}{push_attempt:02d}", "sha": push.get("head_sha"),
        "push_run": push_run, "push_attempt": push_attempt,
        "sign_run": sign.get("id"), "sign_attempt": sign.get("run_attempt") or 1,
        "sign_created": sign.get("created_at"), "sign_started": started(sign), "pushed_at": push.get("created_at"),
        "landed_at": iso(landed), "feed_at": iso(feed),
        "merge_to_feed": minutes(landed, feed), "push_to_feed": minutes(p_created, feed),
        "stages": {k: v for k, v in stages.items() if v is not None},
        "runners": {k: host_of((j or {}).get("runner_name")) for k, j in
                    (("build", pub if one_job else build), ("sign", signer), ("publish", pub)) if j},
        "hosts": host_sums(lines), "jobs": lines,
    }, None


def started(run_obj: Dict[str, Any]) -> str:
    """When a run's newest attempt started (run_started_at moves on a rerun, created_at does not)."""
    return run_obj.get("run_started_at") or run_obj.get("created_at") or ""


def unpublished_line(sign: Dict[str, Any], why: Optional[str] = None) -> Dict[str, Any]:
    m = SIGN_RE.match(sign.get("display_title") or "")
    return {"sign_run": sign.get("id"), "attempt": sign.get("run_attempt") or 1,
            "push_run": int(m.group(1)) if m else sign.get("id"),
            "conclusion": why or sign.get("conclusion"), "created_at": sign.get("created_at"),
            "held_min": minutes(ts(sign.get("created_at")), ts(sign.get("updated_at")))}


# The history in the issue

def history_json(body: str) -> Any:
    """The hidden history's document: the compressed form, else the plain one; {} when absent or unreadable."""
    try:
        z = HISTORY_Z_RE.search(body or "")
        if z:
            inflate = zlib.decompressobj()
            raw = inflate.decompress(base64.b64decode(z.group(1), validate=True), INFLATE_CAP)
            return {} if inflate.unconsumed_tail or not inflate.eof else json.loads(raw)
        m = HISTORY_RE.search(body or "")
        return json.loads(m.group(1)) if m else {}
    except (ValueError, zlib.error, RecursionError):
        return {}


def is_num(v: Any) -> bool:
    """A number of minutes or a count: no bool, NaN, infinity, or integer too large for float arithmetic."""
    return isinstance(v, (int, float)) and not isinstance(v, bool) and -1e9 < v < 1e9


def sound_record(r: Any) -> bool:
    """A stored record in the shape build_record writes. The issue is text anyone with write access can edit, valid
    JSON of another shape would raise in check, and a sha reaches git as an argument: anything else is no record."""
    if not isinstance(r, dict):
        return False

    def opt(key: str, ok: Callable[[Any], bool]) -> bool:
        return r.get(key) is None or ok(r[key])

    def text(v: Any) -> bool:
        return isinstance(v, str)

    return (type(r.get("sign_run")) is int and r["sign_run"] > 0 and text(r.get("feed_at")) and bool(r["feed_at"])
            and text(r.get("build")) and opt("sha", lambda v: text(v) and bool(SHA_RE.match(v)))
            and all(opt(k, text) for k in ("sign_created", "sign_started", "landed_at", "pushed_at"))
            and all(opt(k, is_num) for k in ("merge_to_feed", "push_to_feed"))
            and opt("stages", lambda v: isinstance(v, dict) and all(is_num(x) for x in v.values()))
            and opt("runners", lambda v: isinstance(v, dict) and all(x is None or text(x) for x in v.values()))
            and opt("hosts", lambda v: isinstance(v, dict) and all(
                isinstance(x, list) and len(x) == 4 and all(is_num(n) for n in x) for x in v.values()))
            and opt("jobs", lambda v: isinstance(v, list) and all(
                isinstance(j, list) and len(j) == 4 and text(j[0]) and text(j[1])
                and all(n is None or is_num(n) for n in j[2:]) for j in v)))


def sound_unpublished(u: Any) -> bool:
    """A stored unpublished line in the shape unpublished_line writes."""
    return (isinstance(u, dict) and type(u.get("sign_run")) is int and u["sign_run"] > 0
            and (u.get("attempt") is None or type(u["attempt"]) is int)
            and (u.get("created_at") is None or isinstance(u["created_at"], str))
            and (u.get("held_min") is None or is_num(u["held_min"])))


def parse_history(body: str) -> Dict[str, Any]:
    """The records and unpublished lines of the issue's history that are sound; never raises on what the body holds."""
    doc = history_json(body)

    def rows(key: str, sound: Callable[[Any], bool]) -> List[Dict[str, Any]]:
        v = doc.get(key) if isinstance(doc, dict) else None
        return [x for x in v if sound(x)] if isinstance(v, list) else []

    return {"records": rows("records", sound_record), "unpublished": rows("unpublished", sound_unpublished)}


def merge(old: List[Dict[str, Any]], new: List[Dict[str, Any]], order: str, keep: int) -> List[Dict[str, Any]]:
    """By sign run, the newer copy winning; oldest first by `order`; the newest `keep`."""
    by = {r["sign_run"]: r for r in old}
    by.update({r["sign_run"]: r for r in new})
    return sorted(by.values(), key=lambda r: (r.get(order) or "", r["sign_run"]))[-keep:]


def find_issue(repo: str, token: Optional[str], run: Callable = subprocess.run) -> Optional[Dict[str, Any]]:
    """The open speed issue (title and mark), or None when there is none yet; SourceError when unreadable."""
    if not token:
        raise SourceError("no cmuxterm-hq token (HQ_GH_TOKEN is empty: the App mint failed or there is no App)")
    env = {**os.environ, "GH_TOKEN": token}
    try:
        found = run(["gh", "issue", "list", "--repo", repo, "--state", "open", "--search", f'"{ISSUE_TITLE}" in:title',
                     "--json", "number,title,body", "--limit", "10"], capture_output=True, text=True, timeout=60, env=env)
    except (OSError, subprocess.SubprocessError) as e:
        raise SourceError(f"gh could not list {repo} issues: {e}") from e
    if found.returncode != 0:
        raise SourceError(f"gh could not list {repo} issues: {(found.stderr or found.stdout).strip()[-200:]}")
    try:
        issues = json.loads(found.stdout or "[]")
    except ValueError as e:
        raise SourceError(f"gh returned no JSON for {repo} issues: {e}") from e
    own = [i for i in issues if i.get("title") == ISSUE_TITLE and ISSUE_MARK in (i.get("body") or "")]
    return min(own, key=lambda i: i["number"]) if own else None


# record

def record(repo: str, hq_repo: str, newest: int, git_dir: str, base_ref: str, token: Optional[str],
           hq_token: Optional[str], run: Callable = subprocess.run) -> Dict[str, Any]:
    history_why = None
    try:
        issue = find_issue(hq_repo, hq_token, run)
        hist = parse_history(issue["body"]) if issue else {"records": [], "unpublished": []}
    except SourceError as e:
        history_why, hist = str(e), {"records": [], "unpublished": []}
    # GitHub keeps a run's id when it is re-run, so an unpublished run is known only at the attempt it was seen at (a
    # line from before attempts were kept saw attempt 1); a recorded one is known at any attempt.
    recorded = {r["sign_run"] for r in hist["records"]}
    seen = {(u["sign_run"], u.get("attempt") or 1) for u in hist["unpublished"]}

    def known(r: Dict[str, Any]) -> bool:
        return r.get("id") in recorded or (r.get("id"), r.get("run_attempt") or 1) in seen

    # Nothing that started before the oldest record is read: it fell off the history. A rerun keeps its run's
    # created_at, so the time is the newest attempt's start, or a rerun of an old run would never be read.
    oldest = min((r.get("sign_started") or r.get("sign_created") or "" for r in hist["records"]), default="")
    state: Dict[str, Any] = {"schema": SCHEMA, "records": hist["records"], "unpublished": hist["unpublished"],
                             "new": [], "new_unpublished": [], "history_why": history_why, "why": None}
    try:
        runs = gh_api(f"repos/{repo}/actions/workflows/{WORKFLOW}/runs?branch={BRANCH}&per_page={LIST_PAGE}",
                      token, run).get("workflow_runs") or []
    except (SourceError, AttributeError) as e:
        state["why"] = f"no run list: {e}"
        return state
    by_id = {r.get("id"): r for r in runs}
    signs = [r for r in runs if SIGN_RE.match(r.get("display_title") or "") and r.get("status") == "completed"
             and not known(r) and started(r) >= oldest]
    # A one-job nightly: a push run that succeeded and that no sign run names. With the two-run pipeline a push run
    # that succeeded has dispatched its sign run before it ends (48 of 48 on 2026-11-11 and 12; the superseded ones
    # are cancelled), so none is read here for nothing. One listed before its sign run is forgotten once that run is.
    signed = {int(SIGN_RE.match(r["display_title"]).group(1)) for r in runs if SIGN_RE.match(r.get("display_title") or "")}
    signs += [r for r in runs if r.get("event") == "push" and not SIGN_RE.match(r.get("display_title") or "")
              and r.get("status") == "completed" and r.get("conclusion") == "success" and r.get("id") not in signed
              and not known(r) and started(r) >= oldest]
    signs.sort(key=started, reverse=True)
    landed = landing_times(git_dir, base_ref, run) if signs else {}
    new_recs, new_unp, whys = [], [], []
    for sign in signs[:newest]:
        if sign.get("conclusion") != "success":
            new_unp.append(unpublished_line(sign))
            continue
        m = SIGN_RE.match(sign.get("display_title") or "")
        push_id, push_attempt = m.groups() if m else (sign["id"], sign.get("run_attempt") or 1)
        try:
            push = by_id.get(int(push_id)) or gh_api(f"repos/{repo}/actions/runs/{push_id}", token, run)
            sign_jobs = gh_api(f"repos/{repo}/actions/runs/{sign['id']}/attempts/{sign.get('run_attempt') or 1}/jobs?per_page=100",
                               token, run).get("jobs") or [] if m else []
            push_jobs = gh_api(f"repos/{repo}/actions/runs/{push_id}/attempts/{push_attempt}/jobs?per_page=100",
                               token, run).get("jobs") or []
        except (SourceError, AttributeError) as e:
            whys.append(f"sign run {sign.get('id')}: {e}")
            continue
        rec, why = build_record(sign, push, sign_jobs, push_jobs, landed.get(push.get("head_sha") or ""))
        if rec:
            new_recs.append(rec)
        else:
            new_unp.append(unpublished_line(sign, f"success, {why}"))
    state["records"] = merge(state["records"], new_recs, "feed_at", HISTORY_KEEP)
    # A rerun that published is no longer an unpublished run.
    published = {r["sign_run"] for r in state["records"]}
    state["unpublished"] = [u for u in merge(state["unpublished"], new_unp, "created_at", UNPUBLISHED_KEEP)
                            if u["sign_run"] not in signed and u["sign_run"] not in published]
    state["new"] = [r["build"] for r in sorted(new_recs, key=lambda r: r["feed_at"])]
    state["new_unpublished"] = [u["sign_run"] for u in new_unp]
    state["why"] = "; ".join(whys) or None
    return state


# check

def stage_keys(records: List[Dict[str, Any]]) -> List[str]:
    """The named stages in order, then every other stage (job:<name>) any record has, sorted."""
    seen = {k for r in records for k in (r.get("stages") or {})}
    return [k for k, _, _ in STAGES] + sorted(seen - set(STAGE_LABEL))


def trailing_medians(records: List[Dict[str, Any]], i: int) -> Dict[str, float]:
    """Each stage's median over the TRAILING records before records[i] that have it (MIN_TRAILING or more)."""
    window = records[max(0, i - TRAILING):i]
    out = {}
    for k in stage_keys(window):
        vals = [r["stages"][k] for r in window if isinstance((r.get("stages") or {}).get(k), (int, float))]
        if len(vals) >= MIN_TRAILING:
            out[k] = quantile(vals, 0.5)
    return out


def judge(records: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Per record (oldest first): over budget, and its slow stages {stage: [value, median]}."""
    out = []
    for i, r in enumerate(records):
        med = trailing_medians(records, i)
        slow = {}
        for k, m in med.items():
            v = (r.get("stages") or {}).get(k)
            if isinstance(v, (int, float)) and v > SLOW_RATIO * m and v - m >= SLOW_FLOOR_MIN:
                slow[k] = [v, round(m, 2)]
        mtf = r.get("merge_to_feed")
        out.append({"over": None if mtf is None else mtf > BUDGET_MIN, "slow": slow, "medians": med})
    return out


def is_fast(v: Dict[str, Any]) -> bool:
    return v["over"] is False and not v["slow"]


def commits_between(git_dir: str, a: Optional[str], b: Optional[str], paths: Optional[List[str]] = None,
                    run: Callable = subprocess.run) -> Optional[List[List[str]]]:
    """[sha, subject] of the first-parent commits in a..b (newest first), touching `paths` when given."""
    if not a or not b:
        return None
    out = git(git_dir, ["log", "--first-parent", "--format=%H%x09%s", f"{a}..{b}"] + (["--"] + paths if paths else []), run)
    if out is None:
        return None
    return [line.split("\t", 1) for line in out.splitlines() if "\t" in line]


def code_files_by_dir(git_dir: str, a: str, b: str, run: Callable = subprocess.run) -> Optional[Dict[str, int]]:
    out = git(git_dir, ["diff", "--name-only", a, b], run)
    if out is None:
        return None
    counts: Dict[str, int] = {}
    for path in out.splitlines():
        if path.endswith(CODE_SUFFIXES):
            top = path.split("/", 1)[0] if "/" in path else "."
            counts[top] = counts.get(top, 0) + 1
    return dict(sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])))


def diff(ref: Dict[str, Any], cur: Dict[str, Any], medians: Dict[str, float], git_dir: str,
         run: Callable = subprocess.run) -> Dict[str, Any]:
    stages = []
    for k in stage_keys([ref, cur]):
        a, b = (ref.get("stages") or {}).get(k), (cur.get("stages") or {}).get(k)
        if a is None and b is None:
            continue
        stages.append({"stage": k, "now": b, "ref": a, "delta": None if a is None or b is None else round(b - a, 2),
                       "median": None if k not in medians else round(medians[k], 2)})
    ref_jobs = {j[0]: j[1] for j in ref.get("jobs") or []}
    cur_jobs = {j[0]: j[1] for j in cur.get("jobs") or []}
    if ref_jobs and cur_jobs:
        moved = [[n, ref_jobs[n], cur_jobs[n]] for n in sorted(cur_jobs) if n in ref_jobs and ref_jobs[n] != cur_jobs[n]]
    else:  # an older record keeps only its main runners
        moved = [[k, (ref.get("runners") or {}).get(k), v] for k, v in sorted((cur.get("runners") or {}).items())
                 if (ref.get("runners") or {}).get(k) != v]
    waits = []
    rh, ch = ref.get("hosts") or {}, cur.get("hosts") or {}
    for host in sorted(set(rh) | set(ch)):
        r, c = rh.get(host) or [0, 0, 0, 0], ch.get(host) or [0, 0, 0, 0]
        waits.append({"host": host, "jobs": [r[0], c[0]], "queue": [r[1], c[1]], "hook": [r[2], c[2]],
                      "hook_max": [r[3], c[3]], "delta": round((c[1] + c[2]) - (r[1] + r[2]), 2)})
    waits.sort(key=lambda w: -abs(w["delta"]))
    commits = commits_between(git_dir, ref.get("sha"), cur.get("sha"), run=run)
    return {"ref_build": ref["build"], "ref_sha": ref.get("sha"), "ref_feed_at": ref.get("feed_at"),
            "ref_merge_to_feed": ref.get("merge_to_feed"), "stages": stages, "runner_changes": moved, "waits": waits,
            "commits": None if commits is None else {"count": len(commits), "shown": commits[:COMMITS_SHOWN]}}


def bisect(records: List[Dict[str, Any]], verdicts: List[Dict[str, Any]], i: int, stage: str, git_dir: str,
           run: Callable = subprocess.run) -> Optional[Dict[str, Any]]:
    """The change point of a stage slow in the BISECT_AFTER records up to records[i], over the recorded history."""
    if i + 1 < BISECT_AFTER or not all(stage in verdicts[j]["slow"] for j in range(i - BISECT_AFTER + 1, i + 1)):
        return None
    first = i
    while first > 0 and stage in verdicts[first - 1]["slow"]:
        first -= 1
    last_ok = records[first - 1] if first > 0 else None
    bad = records[first]
    out: Dict[str, Any] = {"stage": stage, "streak": i - first + 1,
                           "first_slow": {"build": bad["build"], "sha": bad.get("sha"), "value": bad["stages"].get(stage)},
                           "last_ok": None if not last_ok else {"build": last_ok["build"], "sha": last_ok.get("sha"),
                                                                "value": (last_ok.get("stages") or {}).get(stage)},
                           "pipeline_commits": None, "code_files": None}
    if last_ok:
        out["pipeline_commits"] = commits_between(git_dir, last_ok.get("sha"), bad.get("sha"), PIPELINE_PATHS, run)
        if stage in COMPILE_STAGES and last_ok.get("sha") and bad.get("sha"):
            out["code_files"] = code_files_by_dir(git_dir, last_ok["sha"], bad["sha"], run)
    return out


def check(records: List[Dict[str, Any]], git_dir: str, run: Callable = subprocess.run) -> Dict[str, Any]:
    """The verdict of the newest record."""
    if not records:
        return {"build": None, "verdict": "no record", "over": None, "slow": {}, "diff": None, "bisect": [], "rows": []}
    verdicts = judge(records)
    i = len(records) - 1
    cur, v = records[i], verdicts[i]
    ref_i = next((j for j in range(i - 1, -1, -1) if is_fast(verdicts[j])), None)
    ref_kind = "last fast run"
    if ref_i is None:
        done = [j for j in range(i) if records[j].get("merge_to_feed") is not None]
        ref_i = min(done, key=lambda j: records[j]["merge_to_feed"]) if done else None
        ref_kind = "fastest recorded run (none was fast)"
    bisects = [b for b in (bisect(records, verdicts, i, k, git_dir, run) for k in v["slow"]) if b]
    if v["over"]:
        verdict = "over budget"
    elif v["slow"]:
        verdict = "slow stage"
    else:
        verdict = "in budget" if v["over"] is False else "no landing time"
    rows = [{"build": r["build"], "sha": r.get("sha"), "feed_at": r.get("feed_at"), "merge_to_feed": r.get("merge_to_feed"),
             "stages": r.get("stages") or {}, "build_runner": (r.get("runners") or {}).get("build"),
             "over": verdicts[j]["over"], "slow": sorted(verdicts[j]["slow"])}
            for j, r in enumerate(records)][-TABLE_ROWS:]
    over_now = [r["merge_to_feed"] for r in records[-TRAILING:] if r.get("merge_to_feed") is not None]
    return {"build": cur["build"], "sha": cur.get("sha"), "feed_at": cur.get("feed_at"), "verdict": verdict,
            "merge_to_feed": cur.get("merge_to_feed"), "budget_min": BUDGET_MIN, "over": v["over"], "slow": v["slow"],
            "ref_kind": ref_kind if ref_i is not None else None,
            "diff": diff(records[ref_i], cur, v["medians"], git_dir, run) if ref_i is not None else None,
            "bisect": bisects, "rows": rows,
            "p50": quantile(over_now, 0.5), "p95": quantile(over_now, 0.95), "window": len(over_now)}


# Markdown

def num(v: Any, unit: str = "") -> str:
    return "n/a" if v is None else f"{v:.1f}{unit}"


def signed(v: Any) -> str:
    return "n/a" if v is None else f"{v:+.1f}"


def short(sha: Optional[str]) -> str:
    return (sha or "?")[:9]


def render_verdict(c: Dict[str, Any], repo: str = REPO) -> str:
    if not c.get("build"):
        return "## Nightly speed\n\nNo published nightly is recorded yet.\n"
    head = (f"## Nightly speed: build {c['build']} ({short(c['sha'])}), merge to feed {num(c['merge_to_feed'], ' min')}, "
            f"{c['verdict']}")
    out = [head, "", f"Budget: merge to feed p95 under {c['budget_min']:.0f} min. Over the newest {c['window']} nightlies: "
                     f"p50 {num(c['p50'], ' min')}, p95 {num(c['p95'], ' min')}. Feed upload at {c['feed_at']}."]
    if c["over"]:
        out += ["", f"Over budget by {c['merge_to_feed'] - c['budget_min']:.1f} min."]
    if c["slow"]:
        out += ["", "Slow stages (over 1.5x their trailing median and 1 min over it): " + ", ".join(
            f"`{STAGE_LABEL.get(k, k)}` {val:.1f} min (median {m:.1f})" for k, (val, m) in sorted(c["slow"].items()))]
    if c["verdict"] == "in budget":
        out += ["", "In budget, no slow stage."]
    d = c.get("diff")
    if d and (c["over"] or c["slow"]):
        out += ["", f"### Diff from the {c['ref_kind']}: build {d['ref_build']} ({short(d['ref_sha'])}), "
                    f"merge to feed {num(d['ref_merge_to_feed'], ' min')}", "",
                "| Stage | Now | Then | Delta | Trailing median |", "| --- | --- | --- | --- | --- |"]
        for s in d["stages"]:
            # A job wall or a step is shown when it is slow or moved a minute; the named stages always.
            if s["stage"].startswith(("job:", "step:")) and s["stage"] not in c["slow"] \
                    and abs(s["delta"] or 0) < SLOW_FLOOR_MIN:
                continue
            mark = " **slow**" if s["stage"] in c["slow"] else ""
            out.append(f"| {STAGE_LABEL.get(s['stage'], s['stage'])}{mark} | {num(s['now'])} | {num(s['ref'])} | "
                       f"{signed(s['delta'])} | {num(s['median'])} |")
        if d["runner_changes"]:
            out += ["", "Runner host changes: " + ", ".join(f"`{n}` {a} -> {b}" for n, a, b in d["runner_changes"][:20])]
        waits = [w for w in d["waits"] if abs(w["delta"]) >= 0.1]
        if waits:
            out += ["", "| Host | Jobs then/now | Queue min then/now | Hook min then/now | Longest hook then/now | Wait delta |",
                    "| --- | --- | --- | --- | --- | --- |"]
            out += [f"| {w['host']} | {w['jobs'][0]}/{w['jobs'][1]} | {num(w['queue'][0])}/{num(w['queue'][1])} | "
                    f"{num(w['hook'][0])}/{num(w['hook'][1])} | {num(w['hook_max'][0])}/{num(w['hook_max'][1])} | "
                    f"{signed(w['delta'])} |" for w in waits]
        cm = d.get("commits")
        if cm is None:
            out += ["", f"Commits {short(d['ref_sha'])}..{short(c['sha'])}: not in this checkout's history."]
        else:
            out += ["", f"Commits [{short(d['ref_sha'])}..{short(c['sha'])}](https://github.com/{repo}/compare/"
                        f"{d['ref_sha']}...{c['sha']}): {cm['count']} on feat-cmux-next."]
            out += [f"- `{sha[:9]}` {subject}" for sha, subject in cm["shown"]]
            if cm["count"] > len(cm["shown"]):
                out.append(f"- and {cm['count'] - len(cm['shown'])} more")
    for b in c.get("bisect") or []:
        out += ["", f"### Bisect: `{STAGE_LABEL.get(b['stage'], b['stage'])}` slow in {b['streak']} consecutive nightlies", ""]
        fs, lo = b["first_slow"], b["last_ok"]
        if not lo:
            out.append(f"Slow since the oldest recorded nightly, build {fs['build']} ({short(fs['sha'])}): no change point in the history.")
            continue
        out.append(f"Change point over the recorded runs: last not slow build {lo['build']} ({short(lo['sha'])}, "
                   f"{num(lo['value'], ' min')}), first slow build {fs['build']} ({short(fs['sha'])}, {num(fs['value'], ' min')}).")
        pc = b.get("pipeline_commits")
        if pc is None:
            out += ["", "Pipeline commits between them: not in this checkout's history."]
        else:
            out += ["", f"Pipeline commits between them ({', '.join(PIPELINE_PATHS)}): {len(pc) or 'none'}"]
            out += [f"- `{sha[:9]}` {subject}" for sha, subject in pc[:COMMITS_SHOWN]]
        if b.get("code_files") is not None:
            out += ["", "Changed Swift and Rust files by top-level directory: " +
                    (", ".join(f"{k} {n}" for k, n in b["code_files"].items()) or "none")]
    return "\n".join(out) + "\n"


def render_table(rows: List[Dict[str, Any]]) -> str:
    cols = TOP_STAGES + ["c1_compile", "g1_notarize"]
    out = ["| Feed (UTC) | Build | Head | Merge to feed | " + " | ".join(k.split("_")[0] for k in cols) +
           " | Build runner | Verdict |", "| --- " * (6 + len(cols)) + "|"]
    for r in reversed(rows):
        flags = (["over"] if r["over"] else []) + [f"slow {k.split('_')[0]}" for k in r["slow"]]
        out.append(f"| {(r['feed_at'] or '')[5:16].replace('T', ' ')} | {r['build']} | {short(r['sha'])} | "
                   f"{num(r['merge_to_feed'])} | " + " | ".join(num(r["stages"].get(k)) for k in cols) +
                   f" | {r.get('build_runner') or '?'} | {', '.join(flags) or 'ok'} |")
    return "\n".join(out)


def history_doc(records: List[Dict[str, Any]], unpublished: List[Dict[str, Any]], jobs_keep: int = JOBS_KEEP) -> str:
    keep_jobs = {r["sign_run"] for r in records[-jobs_keep:]} if jobs_keep else set()
    recs = [r if r["sign_run"] in keep_jobs else {k: v for k, v in r.items() if k != "jobs"} for r in records]
    doc = {"schema": SCHEMA, "budget_min": BUDGET_MIN, "top_stages": TOP_STAGES, "records": recs,
           "unpublished": unpublished}
    return json.dumps(doc, separators=(",", ":"))


def history_comment(records: List[Dict[str, Any]], unpublished: List[Dict[str, Any]],
                    jobs_keep: int = JOBS_KEEP) -> str:
    """The hidden comment as written: base64 holds no "-->", so a job name cannot end it early."""
    z = base64.b64encode(zlib.compress(history_doc(records, unpublished, jobs_keep).encode("utf-8"), 9)).decode("ascii")
    return f"<!-- nightly-speed-history-z: {z} -->"


def issue_body(records: List[Dict[str, Any]], unpublished: List[Dict[str, Any]], git_dir: str,
               run: Callable = subprocess.run) -> str:
    """The issue body, the oldest records dropped until it fits BODY_LIMIT, down to TRAILING + BISECT_AFTER; past that
    floor every record's per-job detail goes, then the oldest records again, and only with no record left the oldest
    unpublished lines (a line is 150 bytes; it is never dropped to make room for a record), so it is never over."""
    floor = TRAILING + BISECT_AFTER
    while len(records) > floor and len(history_comment(records, unpublished)) > BODY_LIMIT - VISIBLE_RESERVE:
        records = records[1:]
    jobs_keep = JOBS_KEEP
    while True:
        c = check(records, git_dir, run)
        unp = list(reversed(unpublished))[:10]
        lines = [f"{ISSUE_MARK}\nWritten on each push to nightly-next by cmux `.github/workflows/nightly-speed.yml` "
                 f"(`scripts/ci/nightly_speed.py`). Do not edit: the next run replaces this body.\n", render_verdict(c),
                 f"## Newest {len(c['rows'])} nightlies (minutes)\n", render_table(c["rows"]), ""]
        if unp:
            lines += [f"## Runs that did not publish (newest {len(unp)} of {len(unpublished)} kept)\n",
                      "| Created (UTC) | Run | Push run | Conclusion | Open in the sign group, min |", "| --- | --- | --- | --- | --- |"]
            lines += [f"| {(u.get('created_at') or '')[5:16].replace('T', ' ')} | {u['sign_run']} | {u.get('push_run')} | "
                      f"{u.get('conclusion')} | {num(u.get('held_min'))} |" for u in unp]
            lines.append("")
        body = "\n".join(lines) + f"\n{history_comment(records, unpublished, jobs_keep)}\n"
        if len(body) <= BODY_LIMIT or not (records or unpublished):
            return body
        if len(records) <= floor and jobs_keep:
            jobs_keep = 0
        elif records:
            records = records[1:]
        else:
            unpublished = unpublished[1:]


def write_issue(state: Dict[str, Any], hq_repo: str, token: Optional[str], git_dir: str,
                run: Callable = subprocess.run) -> str:
    issue = find_issue(hq_repo, token, run)
    if issue and not state.get("new") and not state.get("new_unpublished"):
        return f"#{issue['number']} (nothing new, not written)"
    old = parse_history(issue["body"]) if issue else {"records": [], "unpublished": []}
    records = merge(old["records"], state.get("records") or [], "feed_at", HISTORY_KEEP)
    published = {r["sign_run"] for r in records}
    unpublished = [u for u in merge(old["unpublished"], state.get("unpublished") or [], "created_at", UNPUBLISHED_KEEP)
                   if u["sign_run"] not in published]
    body = issue_body(records, unpublished, git_dir, run)
    env = {**os.environ, "GH_TOKEN": token or ""}
    if issue:
        cmd = ["gh", "issue", "edit", str(issue["number"]), "--repo", hq_repo, "--body-file", "-"]
    else:
        cmd = ["gh", "issue", "create", "--repo", hq_repo, "--title", ISSUE_TITLE, "--body-file", "-"]
    try:
        done = run(cmd, input=body, capture_output=True, text=True, timeout=60, env=env)
    except (OSError, subprocess.SubprocessError) as e:
        raise SourceError(f"gh could not write the speed issue: {e}") from e
    if done.returncode != 0:
        raise SourceError(f"gh could not write the speed issue: {(done.stderr or done.stdout).strip()[-200:]}")
    return f"#{issue['number']}" if issue else (done.stdout or "").strip()


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    rec = sub.add_parser("record", help="record the nightlies published since the last record")
    rec.add_argument("--out", required=True)
    rec.add_argument("--repo", default=REPO)
    rec.add_argument("--hq-repo", default=HQ_REPO)
    rec.add_argument("--newest", type=int, default=NEWEST)
    rec.add_argument("--git-dir", default=".")
    rec.add_argument("--base-ref", default=BASE_REF)
    chk = sub.add_parser("check", help="judge the newest record against the budget and the trailing medians")
    chk.add_argument("--state", required=True)
    chk.add_argument("--json")
    chk.add_argument("--md")
    chk.add_argument("--git-dir", default=".")
    iss = sub.add_parser("issue", help="open or update the one cmuxterm-hq speed issue")
    iss.add_argument("--state", required=True)
    iss.add_argument("--hq-repo", default=HQ_REPO)
    iss.add_argument("--git-dir", default=".")
    args = ap.parse_args(argv)
    if args.cmd == "record":
        state = record(args.repo, args.hq_repo, args.newest, args.git_dir, args.base_ref,
                       os.environ.get("GH_TOKEN") or None, os.environ.get("HQ_GH_TOKEN") or None)
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(state, f, separators=(",", ":"))
        print(f"nightly-speed: {len(state['new'])} new published, {len(state['new_unpublished'])} new unpublished, "
              f"{len(state['records'])} in history" + "".join(f"; {w}" for w in (state["history_why"], state["why"]) if w))
        return 0
    with open(args.state, encoding="utf-8") as f:
        state = json.load(f)
    if args.cmd == "check":
        c = check(state.get("records") or [], args.git_dir)
        md = render_verdict(c)
        for path, text in ((args.json, json.dumps(c, indent=1, sort_keys=True) + "\n"), (args.md, md)):
            if path:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(text)
        print(md.splitlines()[0].lstrip("# "))
        return 0
    try:
        print(f"nightly-speed: issue {write_issue(state, args.hq_repo, os.environ.get('HQ_GH_TOKEN') or None, args.git_dir)}")
    except SourceError as e:
        print(f"nightly-speed: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
