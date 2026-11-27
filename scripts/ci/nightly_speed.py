#!/usr/bin/env python3
"""Nightly speed budget for cmux NEXT: one timing record per published nightly-next build, a check of each against
the budget and every stage's trailing median, and per-PR merge-to-NIGHTLY attribution in one cmuxterm-hq issue that
keeps the verdict and the history.

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
one list of nightly.yml's newest runs on nightly-next (GH_TOKEN, actions read; the list has no event or title filter,
so push, sign, "Retry nightly-next" and manual dispatch runs share one page). Every completed run in it, whatever its
event, title or conclusion, not yet known at its attempt (the newest --newest), costs the jobs list of that attempt
(a sign run's, then its push run's): a publisher job that later jobs failed still published. A run counts as
published only by its write-gated steps: FEED_STEP succeeded and READBACK_STEP, which runs only when the feed was
written, succeeded; a skipped read-back is "no fresh write" (a refused, superseded or already-live write, or a
tail-only dispatch), and a run with no receipt is one unpublished line with its conclusion and the minutes it was
open, the waste account. A failed sign run with no receipt costs that one read. The list shows a run's newest
attempt only, so up to EARLIER_ATTEMPTS earlier attempts no pass saw are read too, and one that published adds its
feed; a run with more earlier attempts than that stays unclassified. A run that started before the oldest record is not read; "started" is its newest attempt's (run_started_at),
since a rerun keeps the run's created_at. The runs it has classified are kept as one span (classified_span), which
is what proves the PR window covered. Each new or unidentified feed entry (NOTES_PER_PASS a pass) is checked against
the publisher's signed release notes (signed_head: two HTTPS reads, no GitHub quota), which name the published head.

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
nightlies, the unpublished sign runs, the PR merge-to-NIGHTLY summary (pr_summary: counts, p50/p90, reasons, at
most PR_SUMMARY_ROWS rows; every row is in `check --json`, and `check --pr-json` writes the PR-only rows, pr_stream,
that nightly-speed.yml uploads as the nightly-pr-attribution artifact), and the history as a hidden comment that
`record` and the quality report read: its JSON document, zlib-compressed and base64 on one line (HISTORY_Z_RE; the
plain JSON of HISTORY_RE, the first form, is still read). Beside the records it keeps the feed list (feed_list: every
published feed of the newest PR_WINDOW_DAYS days and the one before them, seeded from the records), which PR
attribution reads. It holds the newest HISTORY_KEEP records with the body under BODY_LIMIT: when it is over, the
oldest records go down to TRAILING + BISECT_AFTER, then every record's per-job detail, then older records below that
floor, the unpublished lines only when no record is left, and the oldest feed-list entries last, so the issue can
always be written. What is read back is checked (sound_record, sound_unpublished, sound_feed): the issue is editable
text, so valid JSON of another shape is an empty history and a record or entry of another shape is dropped, never an
exception. It re-reads the issue right before writing and merges its history, so a failed read in `record` never
drops history. In budget, the same issue says so. Nothing here gates a nightly: nightly-speed.yml is its own workflow and nothing needs it.

Tests: tests/test_nightly_speed.py (no network; gh, git and the notes feed are fakes or a temporary repository).
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
import time
import zlib
from urllib.parse import urlencode
from typing import Any, Callable, Dict, List, Optional, Tuple

SCHEMA = 2
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
PR_WINDOW_DAYS = 7
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
# The write-gated step after it, in the same job of both pipeline shapes (nightly.yml publish-nightly and
# nightly-next-one, one YAML anchor): it runs only when the upload's feed_written output is true. write_feed exits zero
# without writing on a refused (superseded) write and on an already-live replay, so the upload's success alone proves
# no write: the read-back's success is the publication receipt.
READBACK_STEP = "Read the live nightly-next feed back"
NO_FRESH_WRITE = "no fresh write"
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
# A squash merge's subject ends in "(#N)", its own PR; a number earlier in the subject ("PR 1 of ...", "after #40")
# is not. A merge commit's subject starts "Merge pull request #N". Anything else carries no PR number.
PR_TRAILING_RE = re.compile(r"\(#(\d+)\)\s*$")
PR_MERGE_RE = re.compile(r"^Merge pull request #(\d+)\b")
# The issue shows at most this many attribution rows (the worst and the unattributed); the history keeps none. A
# week is ~2,500 first-parent merges: one row each was a 279 KB body against BODY_LIMIT.
PR_SUMMARY_ROWS = 20
PR_SUBJECT_SHOWN = 80
BEFORE_FEEDS = "before the oldest observed feed"
# Commit metadata supplies candidates only; provider merge SHA + PR number establish identity.
# Keep the committer marker for fixture/backward compatibility, never as proof of a merge.
GITHUB_COMMITTER = "noreply@github.com"
DUPLICATE_PR = "commit names a PR counted at its GitHub merge"
DIRECT_PR = "direct commit names a PR number (no GitHub merge in the window)"
# The history's feed list (one entry per published nightly: head sha, feed_at, build, sign run) is kept apart from
# HISTORY_KEEP: every feed of the newest PR_WINDOW_DAYS plus the one just before them, so a busy week (more than 40
# nightlies) still finds each merge's first feed, and the window is proven covered once that predecessor is held.
# `confirmed` is true only for a record whose read-back step succeeded; an entry seeded from an older record, which
# never kept it, is unconfirmed: attribution excludes it from matches and percentiles.
# The receipt proves the job wrote and read back the feed at feed_at, not what it published: nightly.yml's step
# "source" picks its own build, a recovered or a republished one (build and build_sha) before the upload, and the jobs
# API shows no step output. So a record's `sha` is its run's head commit (sha_source "run_head", confirmed_identity
# false). The publisher's signed release notes name the published build's head: NOTES_FEED<build>.json, its "head"
# being the step's build_sha, signed with the content key (.json.sig, Ed25519). An entry whose notes verify takes
# that head (sha_source "signed_notes", confirmed_identity true); only such an entry proves coverage. A recovered
# build carries another run's build number, so a run's own number has no notes and stays unconfirmed.
FEED_KEYS = ("sha", "feed_at", "build", "sign_run", "confirmed", "sha_source", "confirmed_identity")
SHA_SOURCES = ("run_head", "signed_notes")
NOTES_FEED = "https://files-next.cmux.com/nightly-next/notes/"
CONTENT_PUBLIC_KEY = "AnrDI4vqN4lFGX2IpzeWPZsa/Hk7yQMkVIKppFwAst4="
NOTES_TIMEOUT_S = 20
# Notes read per pass (two plain HTTPS reads each, no GitHub quota): newest unidentified entries first, so a seeded
# list is identified over a few passes.
NOTES_PER_PASS = 16


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


def pr_number(subject: str) -> Optional[int]:
    """The PR a first-parent commit landed: the trailing "(#N)" of a squash merge, else "Merge pull request #N"."""
    match = PR_TRAILING_RE.search(subject or "") or PR_MERGE_RE.match(subject or "")
    return int(match.group(1)) if match else None


def first_parent_pr_merges(git_dir: str, base_ref: str, since: float,
                           run: Callable = subprocess.run) -> List[Dict[str, Any]]:
    """Return the PR landings on ``base_ref``'s first-parent line committed at or after ``since``, newest first.

    ``--since-as-filter``, not ``--since``: ``--since`` stops the walk at the first commit older than the date, so one
    commit with an old committer date hides every landing behind it. A merge without a PR number on the first-parent
    line is kept as an unattributed row, and when it is a sync merge ("Merge origin/feat-cmux-next into
    feat-cmux-next", pushed from a local branch) the landings it brought in on its second parent are walked too: the
    first-parent line then runs down the local branch, and the PRs that landed meanwhile (#48675 under c3d5d5742ca0 on
    2026-11-21) sit only on the second parent.
    """
    rows: List[Dict[str, Any]] = []
    seen = set()
    walks: List[Tuple[str, Optional[str]]] = [(base_ref, None)]
    while walks:
        tip, stop = walks.pop(0)
        args = ["log", "--first-parent", "--format=%H%x09%P%x09%ct%x09%s%x00%ce", f"--since-as-filter={iso(since)}", tip]
        out = git(git_dir, args + ([f"^{stop}"] if stop else []), run) or ""
        for line in out.splitlines():
            parts = line.split("\t", 3)
            if len(parts) != 4 or not parts[2].isdigit():
                continue
            sha, parents, stamp, subject = parts
            subject, _, committer = subject.partition("\0")
            if sha in seen:
                continue
            seen.add(sha)
            number = pr_number(subject)
            parent_list = parents.split()
            if number is None and len(parent_list) >= 2 and len(walks) < 50:
                walks.append((parent_list[1], parent_list[0]))
            rows.append({"sha": sha, "merged_at": iso(float(stamp)), "merged_ts": float(stamp),
                         "pr": number, "subject": subject,
                         "github": committer.strip() in ("", GITHUB_COMMITTER)})
    rows.sort(key=lambda r: r["merged_ts"], reverse=True)
    return rows



def provider_pr_merges(repo: str, base_ref: str, since: float, token: Optional[str],
                       run: Callable = subprocess.run, max_pages: int = 40) -> Dict[str, Any]:
    """Read merge identities in pages, never one request per PR. Stop at the window or a bounded gap.

    Closed PRs are ordered by updated_at: a PR merged in the window cannot have an older update.
    Provider merged_at and merge_commit_sha are authoritative; commit messages and email are not.
    """
    base = re.sub(r"^(refs/remotes/)?origin/|^refs/heads/", "", base_ref)
    rows = {}
    for page in range(1, max_pages + 1):
        query = urlencode({"state": "closed", "base": base, "sort": "updated", "direction": "desc",
                           "per_page": 100, "page": page})
        try:
            prs = gh_api(f"repos/{repo}/pulls?{query}", token, run)
            if not isinstance(prs, list) or any(not isinstance(p, dict) for p in prs):
                raise SourceError("invalid closed-PR response")
        except SourceError as e:
            return {"rows": list(rows.values()), "complete": False, "reason": str(e)}
        for pr in prs:
            merged = ts(pr.get("merged_at"))
            sha = pr.get("merge_commit_sha")
            number = pr.get("number")
            if (merged is not None and merged >= since and type(number) is int and number > 0
                    and isinstance(sha, str) and SHA_RE.fullmatch(sha)
                    and (pr.get("base") or {}).get("ref") == base):
                rows[(number, sha)] = {"pr": number, "sha": sha, "merged_at": pr["merged_at"]}
        updated = [ts(pr.get("updated_at")) for pr in prs]
        if len(prs) < 100 or (updated and all(t is not None for t in updated) and min(updated) < since):
            return {"rows": list(rows.values()), "complete": True, "reason": None}
    return {"rows": list(rows.values()), "complete": False, "reason": "closed-PR page limit reached"}

def _contains_commit(git_dir: str, commit: str, head: str,
                     run: Callable = subprocess.run) -> Optional[bool]:
    """Whether ``head`` contains ``commit``, or None when git cannot answer."""
    if not commit or not head:
        return False
    try:
        done = run(["git", "-C", git_dir, "merge-base", "--is-ancestor", commit, head],
                   capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError):
        return None
    if done.returncode == 0:
        return True
    if done.returncode == 1:
        return False
    return None


def _ancestors_since(git_dir: str, head: str, since: float, run: Callable = subprocess.run) -> Optional[set]:
    """One ancestry list per feed, without a date filter: provider merge time can differ from commit time.
    Missing git history returns None, never proof that a feed excludes a merge."""
    try:
        done = run(["git", "-C", git_dir, "rev-list", head],
                   capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError):
        return None
    return set(done.stdout.split()) if done.returncode == 0 else None


def feed_entry(r: Dict[str, Any]) -> Dict[str, Any]:
    """A record's (or entry's) compact feed entry; one without a receipt is unconfirmed, and one whose sha is not
    read from the published build is the run head's, identity unconfirmed."""
    identity = r.get("sha_source") == "signed_notes" and r.get("confirmed_identity") is True
    return {**{k: r.get(k) for k in FEED_KEYS}, "confirmed": r.get("confirmed") is True,
            "sha_source": "signed_notes" if identity else "run_head", "confirmed_identity": identity}


def feed_list(old: List[Dict[str, Any]], records: List[Dict[str, Any]], now: Optional[float] = None,
              window_days: int = PR_WINDOW_DAYS) -> List[Dict[str, Any]]:
    """The feed list kept in the history: the stored entries plus one per record (records are verified publications,
    so the first run seeds the list from them; nothing else adds an entry), one per build, oldest first, cut to the
    newest ``window_days`` days plus the one feed just before them."""
    end = time.time() if now is None else now
    since = end - window_days * 86400
    by_build: Dict[str, Dict[str, Any]] = {}
    for e in list(old) + [feed_entry(r) for r in records]:
        if sound_feed(e):
            seen = by_build.get(e["build"])
            new = feed_entry(e)
            keep = seen if seen and seen["confirmed_identity"] and not new["confirmed_identity"] else new
            by_build[e["build"]] = {**keep, "confirmed": new["confirmed"] or bool(seen and seen["confirmed"])}
    feeds = sorted(by_build.values(), key=lambda e: ts(e["feed_at"]) or 0)
    before = [i for i, e in enumerate(feeds) if (ts(e["feed_at"]) or 0) < since]
    return feeds[before[-1]:] if before else feeds


def signed_head(build: str, fetch: Optional[Callable[[str], bytes]] = None,
                key: str = CONTENT_PUBLIC_KEY) -> Optional[str]:
    """The head commit the publisher's signed release notes name for ``build``, or None: no notes, a bad signature,
    notes of another build or no sha. ``fetch`` reads a URL (tests pass one); the signature is checked by openssl."""
    import tempfile
    import urllib.request

    def get(url: str) -> bytes:
        req = urllib.request.Request(url, headers={"User-Agent": "cmux-nightly-speed/1"})
        with urllib.request.urlopen(req, timeout=NOTES_TIMEOUT_S) as resp:
            return resp.read(1 << 20)

    if not re.fullmatch(r"[0-9]{1,24}", build or ""):
        return None
    try:
        body, sig = ((fetch or get)(f"{NOTES_FEED}{build}{ext}") for ext in (".json", ".json.sig"))
        with tempfile.TemporaryDirectory() as tmp:
            paths = [os.path.join(tmp, n) for n in ("notes.json", "sig.bin", "pub.der", "pub.pem")]
            for path, data in zip(paths[:3], (body, base64.b64decode(sig.strip()),
                                              bytes.fromhex("302a300506032b6570032100") + base64.b64decode(key))):
                with open(path, "wb") as f:
                    f.write(data)
            subprocess.run(["openssl", "pkey", "-pubin", "-inform", "DER", "-in", paths[2], "-out", paths[3]],
                           check=True, capture_output=True, timeout=NOTES_TIMEOUT_S)
            if subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", paths[3], "-rawin", "-in",
                               paths[0], "-sigfile", paths[1]], capture_output=True,
                              timeout=NOTES_TIMEOUT_S).returncode != 0:
                return None
        notes = json.loads(body)
    except Exception:  # unreachable, unsigned or malformed notes: the identity stays unconfirmed
        return None
    head = notes.get("head") if isinstance(notes, dict) and notes.get("build") == build else None
    return head if isinstance(head, str) and SHA_RE.fullmatch(head) and len(head) == 40 else None


def identify(feeds: List[Dict[str, Any]], notes: Callable[[str], Optional[str]],
             limit: int = NOTES_PER_PASS) -> List[Dict[str, Any]]:
    """The feed list with up to ``limit`` unidentified entries, newest first, checked against their signed notes:
    one whose notes verify takes the notes' head as its sha and is identity-confirmed."""
    out = list(feeds)
    todo = [i for i, e in enumerate(out) if not e.get("confirmed_identity")][::-1][:limit]
    for i in todo:
        head = notes(out[i]["build"])
        if head:
            out[i] = {**out[i], "sha": head, "sha_source": "signed_notes", "confirmed_identity": True}
    return out


def pr_attribution(records: List[Dict[str, Any]], git_dir: str, base_ref: str = BASE_REF,
                   run: Callable = subprocess.run, now: Optional[float] = None,
                   window_days: int = PR_WINDOW_DAYS, feeds: Optional[List[Dict[str, Any]]] = None,
                   classified: Optional[Dict[str, str]] = None,
                   provider_merges: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """Join integration history to provider merge identities and the first verified feed containing each SHA.

    Only the provider merged_at starts a PR wait; subjects and committer dates supply candidates, not proof.
    Unverified feeds never contribute a duration. The head-level speed budget remains independent.
    Missing provider pages, publication receipts, identity, or run classification mark coverage partial.
    """
    end = time.time() if now is None else now
    since = end - window_days * 86400
    merges = first_parent_pr_merges(git_dir, base_ref, since, run)
    feeds = [(ts(e["feed_at"]), e) for e in feed_list(feeds or [], records, end, window_days)]
    feeds = [(t, e) for t, e in feeds if t is not None and t <= end]
    feeds.sort(key=lambda item: (item[0], item[1]["sha"], item[1]["build"]))
    held: Dict[str, Optional[set]] = {}

    def contains(commit: str, head: str) -> Optional[bool]:
        if head not in held:
            held[head] = _ancestors_since(git_dir, head, since, run)
        if held[head] is None:
            return _contains_commit(git_dir, commit, head, run)
        return commit in held[head]

    rows: List[Dict[str, Any]] = []
    provider = provider_merges or {"rows": [], "complete": False, "reason": "no provider merge records"}
    identities = {(r["pr"], r["sha"]): r for r in provider.get("rows", [])
                  if isinstance(r, dict) and type(r.get("pr")) is int and r.get("sha")
                  and ts(r.get("merged_at")) is not None and since <= ts(r["merged_at"]) <= end}
    canonical = {number: sha for number, sha in identities}
    by_sha = {sha: r for (_, sha), r in identities.items()}
    seen = {m["sha"] for m in merges}
    # Include provider merges even if the subject has no PR number or its commit date is outside the window.
    for sha, identity in by_sha.items():
        if sha not in seen:
            merges.append({**identity, "subject": "", "merged_ts": ts(identity["merged_at"]),
                           "integration_verified": _contains_commit(git_dir, sha, base_ref, run) is True})
    for merge in merges:
        identity = by_sha.get(merge["sha"])
        if identity:
            merge.update(identity, merged_ts=ts(identity["merged_at"]))
    for merge in merges:
        row: Dict[str, Any] = {"sha": merge["sha"], "pr": merge["pr"], "subject": merge["subject"],
                               "merged_at": merge["merged_at"] if merge["sha"] in by_sha else None, "feed_at": None, "feed_sha": None, "build": None,
                               "merge_to_nightly": None, "status": "unattributed", "reason": None}
        if merge["pr"] is None:
            row["reason"] = "no PR number in merge metadata"
        elif canonical.get(merge["pr"], merge["sha"]) != merge["sha"]:
            row.update({"reason": DUPLICATE_PR, "canonical_sha": canonical[merge["pr"]]})
        elif (merge["pr"], merge["sha"]) not in identities:
            row["reason"] = DIRECT_PR if provider.get("complete") else "provider merge identity unavailable"
        elif merge.get("integration_verified") is False:
            row["reason"] = "could not verify integration ancestry"
        elif feeds and merge["merged_ts"] < feeds[0][0]:
            row["reason"] = BEFORE_FEEDS
        else:
            for feed_ts, record in feeds:
                if (feed_ts < merge["merged_ts"] or not record.get("confirmed")
                        or not record.get("confirmed_identity")):
                    continue
                holds = contains(merge["sha"], record.get("sha"))
                if holds:
                    row.update({"feed_at": record.get("feed_at"), "feed_sha": record.get("sha"),
                                "build": record.get("build"),
                                "merge_to_nightly": minutes(merge["merged_ts"], feed_ts),
                                "status": "attributed"})
                    break
                if holds is None:
                    row["reason"] = "could not verify nightly head ancestry"
                    break
            if row["status"] != "attributed" and row["reason"] is None:
                row["reason"] = "no later published nightly contains merge"
        rows.append(row)
    rows.sort(key=lambda r: (r.get("merged_at") or "", r["sha"]), reverse=True)
    durations = [r["merge_to_nightly"] for r in rows if r["status"] == "attributed"
                 and isinstance(r["merge_to_nightly"], (int, float))]
    reasons: Dict[str, int] = {}
    for r in rows:
        if r["status"] != "attributed":
            reasons[r["reason"] or "unattributed"] = reasons.get(r["reason"] or "unattributed", 0) + 1
    return {"window": window_days, "window_days": window_days, "since": iso(since), "until": iso(end), "count": len(rows),
            "attributed": len(durations), "p50": quantile(durations, 0.5), "p90": quantile(durations, 0.9),
            "oldest_feed": iso(feeds[0][0]) if feeds else None, "feeds": len(feeds),
            "unconfirmed": sum(1 for _, e in feeds if not e.get("confirmed")),
            "unidentified": sum(1 for _, e in feeds if not e.get("confirmed_identity")),
            "classified": {"from": classified["from"], "to": classified["to"]} if sound_span(classified) else None,
            "partial": not provider.get("complete") or not covered(rows, feeds, since, end, classified)
            or any(r["reason"] == "could not verify integration ancestry" for r in rows),
            "provider_complete": bool(provider.get("complete")), "provider_reason": provider.get("reason"),
            "matched_prs": len(durations),
            "unmatched_prs": sum(r["sha"] in by_sha and r["status"] != "attributed" for r in rows),
            "excluded_commits": sum(r["sha"] not in by_sha for r in rows),
            "unverified_feeds": sum(not e.get("confirmed") or not e.get("confirmed_identity") for _, e in feeds),
            "reasons": reasons, "rows": rows}


def covered(rows: List[Dict[str, Any]], feeds: List[Tuple[float, Dict[str, Any]]], since: float, until: float,
            classified: Optional[Dict[str, str]]) -> bool:
    """pr_attribution's coverage proof (see there): the classified span holds the whole window, its start and its end
    (a span that ends before the report's end leaves the runs after it unread, so a merge after it may sit in one)."""
    if not sound_span(classified) or not feeds or feeds[0][0] >= since or (ts(classified["from"]) or 0) > since:
        return False
    end = ts(classified["to"]) or 0
    if end < int(until):  # the span is stored to the second
        return False
    return all(e.get("confirmed") and e.get("confirmed_identity") for _, e in feeds) and all(
        (ts(r["feed_at"]) or 0) <= end for r in rows if r["status"] == "attributed")


def pr_stream(data: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """The PR-only document `check --pr-json` writes and nightly-speed.yml uploads (this repository is public): the
    window, its coverage and per merge only its PR, sha, merge time, first feed head and time, minutes and reason. No
    host, runner, job, diff or subject."""
    data = data or {}
    keys = ("window", "since", "until", "oldest_feed", "partial", "feeds", "unconfirmed", "unidentified", "classified", "count",
            "attributed", "p50", "p90", "reasons", "provider_complete", "provider_reason",
            "matched_prs", "unmatched_prs", "excluded_commits", "unverified_feeds")
    out: Dict[str, Any] = {"schema": 2, **{k: data.get(k) for k in keys}, "coverage_partial": data.get("partial", True)}
    out["observed_window"] = {"from": data.get("oldest_feed"), "to": data.get("until")}
    out["rows"] = [{"pr": r.get("pr"), "sha": r.get("sha"), "merged_at": r.get("merged_at"),
                    "feed_sha": r.get("feed_sha"), "feed_at": r.get("feed_at"),
                    "merge_to_nightly": r.get("merge_to_nightly"), "reason": r.get("reason"),
                    "pr_number": r.get("pr"), "merge_sha": r.get("sha"),
                    "feed_source_sha": r.get("feed_sha"), "feed_uploaded_at": r.get("feed_at"),
                    "pr_merge_to_feed_min": r.get("merge_to_nightly")}
                   for r in data.get("rows") or [] if isinstance(r, dict)]
    return out


def pr_summary(data: Optional[Dict[str, Any]], shown: int = PR_SUMMARY_ROWS) -> Dict[str, Any]:
    """The compact attribution the issue shows: the counts, p50/p90, counts per unattributed reason and at most
    ``shown`` rows, half the slowest attributed merges and the rest the newest unattributed ones (BEFORE_FEEDS last,
    it is expected at the window's old end). ``shown=0`` is the history's copy, no rows at all."""
    data = data or {}
    keys = ("window", "window_days", "since", "until", "count", "attributed", "p50", "p90", "oldest_feed",
            "partial", "feeds", "unconfirmed", "unidentified", "classified", "provider_complete", "provider_reason",
            "matched_prs", "unmatched_prs", "excluded_commits", "unverified_feeds")
    out: Dict[str, Any] = {k: data.get(k) for k in keys if k in data}
    out.setdefault("window", PR_WINDOW_DAYS)
    out.setdefault("count", 0)
    out.setdefault("attributed", 0)
    rows = [r for r in data.get("rows") or [] if isinstance(r, dict)]
    reasons = data.get("reasons")
    if not isinstance(reasons, dict):
        reasons = {}
        for r in rows:
            if r.get("status") != "attributed":
                reasons[r.get("reason") or "unattributed"] = reasons.get(r.get("reason") or "unattributed", 0) + 1
    out["reasons"] = reasons
    if shown <= 0:
        return out
    slow = sorted((r for r in rows if r.get("status") == "attributed" and is_num(r.get("merge_to_nightly"))),
                  key=lambda r: -r["merge_to_nightly"])
    newest = lambda rs: sorted(rs, key=lambda r: r.get("merged_at") or "", reverse=True)
    odd = newest(r for r in rows if r.get("status") != "attributed" and r.get("reason") != BEFORE_FEEDS)
    early = newest(r for r in rows if r.get("status") != "attributed" and r.get("reason") == BEFORE_FEEDS)
    pick = slow[:shown // 2] + odd[:shown - min(len(slow), shown // 2)]
    for rest in (slow[shown // 2:], odd, early):
        pick += [r for r in rest if r not in pick][:shown - len(pick)]
    out["rows"] = [{**{k: r.get(k) for k in ("sha", "pr", "merged_at", "feed_at", "build", "merge_to_nightly",
                                               "status", "reason")},
                    "subject": (r.get("subject") or "")[:PR_SUBJECT_SHOWN]} for r in pick[:shown]]
    return out


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


def write_receipt(jobs: List[Dict[str, Any]]) -> bool:
    """A job of the run uploaded the feed and its write-gated read-back passed: the feed was written, whatever the
    run's own conclusion (a job after the publisher may fail it, as attest-nightly-remote-daemon failed run
    44087850352 after it published build 4408785035201)."""
    return any((find_step(j, FEED_STEP) or {}).get("conclusion") == "success"
               and (find_step(j, READBACK_STEP) or {}).get("conclusion") == "success" for j in jobs)


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
    # Published only when the write-gated read-back ran and passed. Skipped: the upload wrote nothing (a superseded
    # build refused, or a replay of the live one). A pipeline with no read-back step keeps its record, unconfirmed.
    readback = find_step(pub, READBACK_STEP)
    if readback and readback.get("conclusion") == "skipped":
        return None, NO_FRESH_WRITE
    if readback and readback.get("conclusion") != "success":
        return None, "read-back failed"
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
        "landed_at": iso(landed), "feed_at": iso(feed), "confirmed": bool(readback),
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
            and opt("confirmed", lambda v: type(v) is bool)
            and opt("stages", lambda v: isinstance(v, dict) and all(is_num(x) for x in v.values()))
            and opt("runners", lambda v: isinstance(v, dict) and all(x is None or text(x) for x in v.values()))
            and opt("hosts", lambda v: isinstance(v, dict) and all(
                isinstance(x, list) and len(x) == 4 and all(is_num(n) for n in x) for x in v.values()))
            and opt("jobs", lambda v: isinstance(v, list) and all(
                isinstance(j, list) and len(j) == 4 and text(j[0]) and text(j[1])
                and all(n is None or is_num(n) for n in j[2:]) for j in v)))


def sound_feed(e: Any) -> bool:
    """A stored feed-list entry in the shape feed_entry writes: a sha git may take, a feed time, a build."""
    return (isinstance(e, dict) and isinstance(e.get("sha"), str) and bool(SHA_RE.match(e["sha"]))
            and isinstance(e.get("feed_at"), str) and ts(e["feed_at"]) is not None
            and isinstance(e.get("build"), str) and bool(e["build"])
            and (e.get("sign_run") is None or (type(e["sign_run"]) is int and e["sign_run"] > 0))
            and e.get("confirmed") in (None, True, False) and e.get("sha_source") in (None,) + SHA_SOURCES
            and e.get("confirmed_identity") in (None, True, False))


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

    out = {"records": rows("records", sound_record), "unpublished": rows("unpublished", sound_unpublished)}
    feeds = rows("feeds", sound_feed)
    if feeds:
        out["feeds"] = feeds
    span = doc.get("classified") if isinstance(doc, dict) else None
    if sound_span(span):
        out["classified"] = {"from": span["from"], "to": span["to"]}
        complete = span.get("complete")
        if isinstance(complete, list):
            out["classified"]["complete"] = [c for c in complete if sound_attempt(c)]
    attribution = doc.get("pr_attribution") if isinstance(doc, dict) else None
    if isinstance(attribution, dict):
        out["pr_attribution"] = pr_summary(attribution, 0)
    return out


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

# The earlier attempts of a newly listed run read for a publication, past its newest one (the list's).
EARLIER_ATTEMPTS = 2


def nightly_run(r: Dict[str, Any], signed: set) -> bool:
    """A run of the list that may publish: any but one a sign run names (that sign run publishes it)."""
    return bool(SIGN_RE.match(r.get("display_title") or "")) or r.get("id") not in signed


def attempts_known(hist: Dict[str, Any]) -> set:
    """(run id, attempt) of every record and unpublished line held."""
    return ({(r["sign_run"], r.get("sign_attempt") or 1) for r in hist["records"]}
            | {(u["sign_run"], u.get("attempt") or 1) for u in hist["unpublished"]})


def sound_attempt(c: Any) -> bool:
    """A stored [run id, attempt] pair."""
    return (isinstance(c, list) and len(c) == 2 and all(type(x) is int and x > 0 for x in c))


def attempts_complete(prev: Optional[Dict[str, Any]]) -> set:
    """(run id, attempt) of every run whose earlier attempts were all examined (the span's ``complete``)."""
    v = prev.get("complete") if isinstance(prev, dict) else None
    return {(c[0], c[1]) for c in v if sound_attempt(c)} if isinstance(v, list) else set()


def superseded_line(u: Dict[str, Any], records: List[Dict[str, Any]]) -> bool:
    """An unpublished line of a run a record holds at that attempt or a later one."""
    return any(r["sign_run"] == u["sign_run"] and (r.get("sign_attempt") or 1) >= (u.get("attempt") or 1)
               for r in records)


def classified_span(prev: Optional[Dict[str, Any]], runs: List[Dict[str, Any]], signed: set, state: Dict[str, Any],
                    oldest: str, now: str, complete: Optional[set] = None) -> Dict[str, Any]:
    """The span {from, to} in which every nightly run (nightly_run: any run but one a sign run names) is classified,
    recorded or unpublished with its reason. The run list covers back to its oldest run (everything, when it is not a
    full page); it extends the stored span when it reaches back to that span's end, and otherwise starts a new one (at
    the newest of its start and the oldest record's, before which nothing is read). The span ends at the start of the
    oldest run left unclassified (in progress, past --newest, or unreadable), or now. A run past its first attempt is
    classified only when each earlier attempt is known or was read (``complete``, this pass's, and the stored span's):
    the list shows the newest attempt only, and an earlier one may have published. ``complete`` is kept with the span,
    for the listed runs only (the list is all a later pass sees)."""
    seen = attempts_known(state)
    done = attempts_complete(prev) | (complete or set())

    def classified(r: Dict[str, Any]) -> bool:
        key = (r.get("id"), r.get("run_attempt") or 1)
        return key in seen and (key[1] == 1 or key in done)
    listed = "" if len(runs) < LIST_PAGE else min((started(r) for r in runs), default="")
    if sound_span(prev) and prev["to"] >= listed:
        start, floor = prev["from"], prev["to"]
    else:
        start = floor = max(listed, oldest)
    pending = [started(r) for r in runs if nightly_run(r, signed) and started(r) >= floor and not classified(r)]
    listed_keys = {(r.get("id"), r.get("run_attempt") or 1) for r in runs}
    out: Dict[str, Any] = {"from": start, "to": min(pending, default=now)}
    kept = sorted([k[0], k[1]] for k in done & listed_keys if k[1] > 1)
    if kept:
        out["complete"] = kept
    return out


def sound_span(v: Any) -> bool:
    return (isinstance(v, dict) and isinstance(v.get("from"), str) and isinstance(v.get("to"), str)
            and (v["from"] == "" or ts(v["from"]) is not None) and ts(v["to"]) is not None and v["from"] <= v["to"])


def record(repo: str, hq_repo: str, newest: int, git_dir: str, base_ref: str, token: Optional[str],
           hq_token: Optional[str], run: Callable = subprocess.run,
           notes: Optional[Callable[[str], Optional[str]]] = None) -> Dict[str, Any]:
    """``notes`` names a build's published head from its signed release notes (signed_head; the CLI passes it):
    feed entries it confirms prove their identity. Without it no entry is identity-confirmed."""
    history_why = None
    try:
        issue = find_issue(hq_repo, hq_token, run)
        hist = parse_history(issue["body"]) if issue else {"records": [], "unpublished": []}
    except SourceError as e:
        history_why, hist = str(e), {"records": [], "unpublished": []}
    # GitHub keeps a run's id when it is re-run, so a run is known only at the attempt it was seen at (a line or record
    # from before attempts were kept saw attempt 1): a rerun of a published run may publish again.
    seen = attempts_known(hist)

    def known(r: Dict[str, Any]) -> bool:
        return (r.get("id"), r.get("run_attempt") or 1) in seen

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
    # Every completed run of the list may have published, whatever its event (push, a sign run's workflow_dispatch, a
    # "Retry nightly-next" or manual dispatch), title or conclusion: each is judged by its write-gated steps alone
    # (write_receipt). Only a run a sign run names is left out: its sign run publishes it, and a two-run push run
    # that succeeded has dispatched its sign run before it ends; one listed before that is forgotten once it is.
    signed = {int(SIGN_RE.match(r["display_title"]).group(1)) for r in runs if SIGN_RE.match(r.get("display_title") or "")}
    signs = [r for r in runs if nightly_run(r, signed) and r.get("status") == "completed"
             and not known(r) and started(r) >= oldest]
    signs.sort(key=started, reverse=True)
    landed = landing_times(git_dir, base_ref, run) if signs else {}
    new_recs, new_unp, whys, extra_feeds, complete = [], [], [], [], set()

    def jobs_of(run_id: Any, attempt: Any) -> List[Dict[str, Any]]:
        return gh_api(f"repos/{repo}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100",
                      token, run).get("jobs") or []

    for sign in signs[:newest]:
        ok = sign.get("conclusion") == "success"
        m = SIGN_RE.match(sign.get("display_title") or "")
        push_id, push_attempt = m.groups() if m else (sign["id"], sign.get("run_attempt") or 1)
        try:
            sign_jobs = jobs_of(sign["id"], sign.get("run_attempt") or 1) if m else []
            if m and not ok and not write_receipt(sign_jobs):  # a failed sign run that wrote no feed: one read
                new_unp.append(unpublished_line(sign))
                continue
            push = by_id.get(int(push_id)) or gh_api(f"repos/{repo}/actions/runs/{push_id}", token, run)
            push_jobs = jobs_of(push_id, push_attempt)
        except (SourceError, AttributeError) as e:
            whys.append(f"sign run {sign.get('id')}: {e}")
            continue
        rec, why = build_record(sign, push, sign_jobs, push_jobs, landed.get(push.get("head_sha") or ""))
        if rec and (ok or rec["confirmed"]):
            new_recs.append(rec)
        elif ok:
            new_unp.append(unpublished_line(sign, f"success, {why}"))
        else:
            new_unp.append(unpublished_line(sign))
        # The list shows a run's newest attempt only: an earlier one no pass saw may have published. Its feed (not a
        # record: a run keeps one) joins the feed list; at most EARLIER_ATTEMPTS more reads per run. A run whose every
        # earlier attempt is known or read is complete; one with more is left unclassified (classified_span).
        attempt = sign.get("run_attempt") or 1
        reads, whole = 0, True
        for k in range(attempt - 1, 0, -1):
            if (sign.get("id"), k) in seen:
                continue
            if reads >= EARLIER_ATTEMPTS:
                whole = False
                break
            reads += 1
            try:
                earlier = {**sign, "run_attempt": k}
                e_sign_jobs = jobs_of(sign["id"], k) if m else []
                e_push = push if m else earlier
                e_push_jobs = push_jobs if m else jobs_of(sign["id"], k)
            except (SourceError, AttributeError) as e:
                whys.append(f"run {sign.get('id')} attempt {k}: {e}")
                whole = False
                break
            e_rec, _ = build_record(earlier, e_push, e_sign_jobs, e_push_jobs, landed.get(push.get("head_sha") or ""))
            if e_rec and e_rec["confirmed"]:
                extra_feeds.append(feed_entry(e_rec))
        if whole and attempt > 1:
            complete.add((sign.get("id"), attempt))
    state["records"] = merge(state["records"], new_recs, "feed_at", HISTORY_KEEP)
    # A rerun that published is no longer an unpublished run (a later attempt's line stays: it is how it is known).
    state["unpublished"] = [u for u in merge(state["unpublished"], new_unp, "created_at", UNPUBLISHED_KEEP)
                            if u["sign_run"] not in signed and not superseded_line(u, state["records"])]
    state["new"] = [r["build"] for r in sorted(new_recs, key=lambda r: r["feed_at"])]
    state["new_unpublished"] = [u["sign_run"] for u in new_unp]
    # Whole seconds: the span's end is stored as iso(now), so a fractional now would read past it (covered).
    now = float(int(time.time()))
    state["classified"] = classified_span(hist.get("classified"), runs, signed, state, oldest, iso(now), complete)
    state["feeds"] = feed_list((hist.get("feeds") or []) + extra_feeds, state["records"], now)
    if notes:
        state["feeds"] = identify(state["feeds"], notes)
    state["pr_attribution"] = pr_attribution(state["records"], git_dir, base_ref, run=run, now=now,
                                             feeds=state["feeds"], classified=state["classified"],
                                             provider_merges=provider_pr_merges(
                                                 repo, base_ref, now - PR_WINDOW_DAYS * 86400, token, run))
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


def check(records: List[Dict[str, Any]], git_dir: str, run: Callable = subprocess.run,
          base_ref: str = BASE_REF, pr_now: Optional[float] = None,
          pr_data: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """The verdict of the newest record. ``pr_data`` is an attribution already made (record's), else one is made."""
    if not records:
        return {"build": None, "verdict": "no record", "over": None, "slow": {}, "diff": None, "bisect": [],
                "rows": [], "pr_attribution": pr_data if pr_data is not None
                else pr_attribution([], git_dir, base_ref, run=run, now=pr_now)}
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
    prs = pr_data if pr_data is not None else pr_attribution(records, git_dir, base_ref, run=run, now=pr_now)
    return {"build": cur["build"], "sha": cur.get("sha"), "feed_at": cur.get("feed_at"), "verdict": verdict,
            "merge_to_feed": cur.get("merge_to_feed"), "budget_min": BUDGET_MIN, "over": v["over"], "slow": v["slow"],
            "ref_kind": ref_kind if ref_i is not None else None,
            "diff": diff(records[ref_i], cur, v["medians"], git_dir, run) if ref_i is not None else None,
            "bisect": bisects, "rows": rows,
            "p50": quantile(over_now, 0.5), "p95": quantile(over_now, 0.95), "window": len(over_now),
            "pr_attribution": prs}


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
    head = (f"## Nightly speed: build {c['build']} ({short(c['sha'])}), head landing to feed {num(c['merge_to_feed'], ' min')}, "
            f"{c['verdict']}")
    out = [head, "", f"Budget: head landing to feed p95 under {c['budget_min']:.0f} min. Over the newest {c['window']} nightlies: "
                     f"p50 {num(c['p50'], ' min')}, p95 {num(c['p95'], ' min')}. Feed upload at {c['feed_at']}."]
    if c["over"]:
        out += ["", f"Over budget by {c['merge_to_feed'] - c['budget_min']:.1f} min."]
    if c["slow"]:
        out += ["", "Slow stages (over 1.5x their trailing median and 1 min over it): " + ", ".join(
            f"`{STAGE_LABEL.get(k, k)}` {val:.1f} min (median {m:.1f})" for k, (val, m) in sorted(c["slow"].items()))]
    if c["verdict"] == "in budget":
        out += ["", "In budget, no slow stage."]
    prs = c.get("pr_attribution")
    if prs:
        prs = pr_summary(prs)
        reasons = "; ".join(f"{why}: {n}" for why, n in sorted(prs["reasons"].items(), key=lambda kv: -kv[1]))
        window = prs.get("window") or PR_WINDOW_DAYS
        oldest, since = prs.get("oldest_feed"), prs.get("since")
        partial, span = prs.get("partial"), prs.get("classified")
        if partial is None:
            partial = not oldest or not since or (ts(oldest) or 0) >= (ts(since) or 0)
        out += ["", f"## PR merge to NIGHTLY ({'partial: ' if partial else ''}"
                    f"{'observed window' if partial else f'newest {window} days'})"]
        if oldest:
            out.append(f"Observed window: {oldest if partial else since} to {prs.get('until') or 'now'}; "
                       f"{prs['reasons'].get(BEFORE_FEEDS, 0)} merges before it unattributed (no feed observed)."
                       + (f" Coverage is partial: {window} days were asked for, from {since}; "
                          + (f"runs are classified from {span['from'] or 'the first run'} to {span['to']}"
                             if isinstance(span, dict) else "no run classification is recorded")
                          + f"; the oldest feed is {oldest}." if partial else "")
                       + (f" {prs['unconfirmed']} of {prs.get('feeds')} feeds are unconfirmed (no read-back receipt)."
                          if prs.get("unconfirmed") else "")
                       + (f" {prs['unidentified']} of {prs.get('feeds')} feeds name the run's head commit, not the "
                          "published build_sha (identity unconfirmed)." if prs.get("unidentified") else ""))
        else:
            out.append("Observed window: none, no published nightly is recorded; coverage is partial.")
        out += [f"Attributed {prs.get('attributed', 0)} of {prs.get('count', 0)} first-parent merges. "
                f"p50 {num(prs.get('p50'), ' min')}, p90 {num(prs.get('p90'), ' min')}."
                + (f" Unattributed: {reasons}." if reasons else "")]
        if prs.get("rows"):
            out += ["", f"Slowest and unattributed {len(prs['rows'])} of {prs.get('count', 0)} (every row: "
                        "`nightly_speed.py check --json`).", "",
                    "| Merge (UTC) | PR | Nightly | Merge to NIGHTLY | Status |", "| --- | --- | --- | --- | --- |"]
            for row in prs["rows"]:
                label = f"#{row['pr']}" if row.get("pr") is not None else f"`{short(row.get('sha'))}`"
                nightly = row.get("build") or "—"
                duration = num(row.get("merge_to_nightly"), " min")
                status = row.get("status") if row.get("status") == "attributed" else row.get("reason") or "unattributed"
                out.append(f"| {(row.get('merged_at') or '')[:16].replace('T', ' ')} | {label} | {nightly} | {duration} | {status} |")
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


def history_doc(records: List[Dict[str, Any]], unpublished: List[Dict[str, Any]], jobs_keep: int = JOBS_KEEP,
                pr_data: Optional[Dict[str, Any]] = None, feeds: Optional[List[Dict[str, Any]]] = None,
                classified: Optional[Dict[str, str]] = None) -> str:
    keep_jobs = {r["sign_run"] for r in records[-jobs_keep:]} if jobs_keep else set()
    recs = [r if r["sign_run"] in keep_jobs else {k: v for k, v in r.items() if k != "jobs"} for r in records]
    doc = {"schema": SCHEMA, "budget_min": BUDGET_MIN, "top_stages": TOP_STAGES, "records": recs,
           "unpublished": unpublished, "feeds": [feed_entry(e) for e in feeds or []],
           "pr_attribution": pr_summary(pr_data, 0)}
    if sound_span(classified):
        doc["classified"] = classified
    return json.dumps(doc, separators=(",", ":"))


def history_comment(records: List[Dict[str, Any]], unpublished: List[Dict[str, Any]],
                    jobs_keep: int = JOBS_KEEP, pr_data: Optional[Dict[str, Any]] = None,
                    feeds: Optional[List[Dict[str, Any]]] = None, classified: Optional[Dict[str, str]] = None) -> str:
    """The hidden comment as written: base64 holds no "-->", so a job name cannot end it early."""
    doc = history_doc(records, unpublished, jobs_keep, pr_data, feeds, classified)
    z = base64.b64encode(zlib.compress(doc.encode("utf-8"), 9)).decode("ascii")
    return f"<!-- nightly-speed-history-z: {z} -->"


def issue_body(records: List[Dict[str, Any]], unpublished: List[Dict[str, Any]], git_dir: str,
               run: Callable = subprocess.run, pr_data: Optional[Dict[str, Any]] = None,
               feeds: Optional[List[Dict[str, Any]]] = None, classified: Optional[Dict[str, str]] = None) -> str:
    """The issue body, the oldest records dropped until it fits BODY_LIMIT, down to TRAILING + BISECT_AFTER; past that
    floor every record's per-job detail goes, then the oldest records again, and only with no record left the oldest
    unpublished lines (a line is 150 bytes; it is never dropped to make room for a record), and only after all of that
    the oldest feed-list entries (about 120 bytes each), so it is never over."""
    feeds = list(feeds) if feeds is not None else feed_list([], records)
    floor = TRAILING + BISECT_AFTER
    if pr_data is None:
        pr_data = pr_attribution(records, git_dir, run=run, feeds=feeds, classified=classified)
    while len(records) > floor and len(history_comment(records, unpublished, feeds=feeds)) > BODY_LIMIT - VISIBLE_RESERVE:
        records = records[1:]
    jobs_keep = JOBS_KEEP
    while True:
        c = check(records, git_dir, run, pr_data=pr_data)
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
        body = "\n".join(lines) + f"\n{history_comment(records, unpublished, jobs_keep, pr_data, feeds, classified)}\n"
        if len(body) <= BODY_LIMIT or not (records or unpublished or feeds):
            return body
        if len(records) <= floor and jobs_keep:
            jobs_keep = 0
        elif records:
            records = records[1:]
        elif unpublished:
            unpublished = unpublished[1:]
        else:
            feeds = feeds[1:]


def write_issue(state: Dict[str, Any], hq_repo: str, token: Optional[str], git_dir: str,
                run: Callable = subprocess.run) -> str:
    issue = find_issue(hq_repo, token, run)
    if issue and not state.get("new") and not state.get("new_unpublished"):
        return f"#{issue['number']} (nothing new, not written)"
    old = parse_history(issue["body"]) if issue else {"records": [], "unpublished": []}
    records = merge(old["records"], state.get("records") or [], "feed_at", HISTORY_KEEP)
    unpublished = [u for u in merge(old["unpublished"], state.get("unpublished") or [], "created_at", UNPUBLISHED_KEEP)
                   if not superseded_line(u, records)]
    feeds = feed_list((old.get("feeds") or []) + (state.get("feeds") or []), records)
    span = state.get("classified") if sound_span(state.get("classified")) else old.get("classified")
    body = issue_body(records, unpublished, git_dir, run, state.get("pr_attribution"), feeds, span)
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
    chk.add_argument("--pr-json", help="the PR-only attribution (pr_stream; no hosts or diffs), for the artifact")
    chk.add_argument("--git-dir", default=".")
    iss = sub.add_parser("issue", help="open or update the one cmuxterm-hq speed issue")
    iss.add_argument("--state", required=True)
    iss.add_argument("--hq-repo", default=HQ_REPO)
    iss.add_argument("--git-dir", default=".")
    args = ap.parse_args(argv)
    if args.cmd == "record":
        state = record(args.repo, args.hq_repo, args.newest, args.git_dir, args.base_ref,
                       os.environ.get("GH_TOKEN") or None, os.environ.get("HQ_GH_TOKEN") or None, notes=signed_head)
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(state, f, separators=(",", ":"))
        print(f"nightly-speed: {len(state['new'])} new published, {len(state['new_unpublished'])} new unpublished, "
              f"{len(state['records'])} in history" + "".join(f"; {w}" for w in (state["history_why"], state["why"]) if w))
        return 0
    with open(args.state, encoding="utf-8") as f:
        state = json.load(f)
    if args.cmd == "check":
        c = check(state.get("records") or [], args.git_dir, pr_data=state.get("pr_attribution"))
        md = render_verdict(c)
        pr_doc = json.dumps(pr_stream(c.get("pr_attribution")), indent=1, sort_keys=True) + "\n"
        for path, text in ((args.json, json.dumps(c, indent=1, sort_keys=True) + "\n"), (args.md, md),
                           (args.pr_json, pr_doc)):
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
