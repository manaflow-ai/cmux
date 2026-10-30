#!/usr/bin/env python3
"""List one web test's failures across recent CI runs: main vs PRs, with job
links and whether a re-run of the same SHA passed.

    python3 scripts/ci/web_test_failure_census.py --file vm-route-deadlines.test.ts
    python3 scripts/ci/web_test_failure_census.py --test "answer deadlines" --days 14 --json

Two sources, cheapest first:

  junit  each `web / Web tests (N/4)` shard that fails uploads its bun JUnit
         report as `web-test-junit-shard<N>-attempt<A>` (ci-web.yml). One
         repository-wide artifact listing per name covers every run in the
         window, so the census costs about a dozen calls plus one download per
         new report.
  logs   for runs before those artifacts existed (or with --source logs): list
         ci.yml runs, read each failed or re-run run's jobs, and download the
         failed web shards' logs. One call per run inspected; --max-runs caps it.

Downloads are cached under $XDG_CACHE_HOME/cmux-ci/web-test-census-v2 (reports
and logs by ID, forever; job lists only once their run completed), so a second
census over the same window costs only the listings. The script reads the core
REST rate limit first (that read is free) and refuses to start when the
estimate does not fit. It never uses GraphQL, whose separate budget runs out
first on a busy day.

Re-run evidence: a failure counts as "passed on re-run" when a later attempt
of the same run passed that shard, or another ci.yml run of the same head SHA
succeeded.
"""

from __future__ import annotations

import argparse
import http.client
import io
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from collections.abc import Iterable, Mapping
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from guard_attribution import ANSI, TIMESTAMP, GitHub  # noqa: E402

REPO = "manaflow-ai/cmux"
WORKFLOW = "ci.yml"
SHARDS = 4
MAX_ATTEMPTS = 3
ARTIFACT = "web-test-junit-shard{shard}-attempt{attempt}"
WEB_JOB = re.compile(r"(?:^|/ )Web tests \((?P<shard>\d+)/(?P<total>\d+)\)$")
RED = {"failure", "timed_out"}
# A bun file header: `##[group]tests/foo.test.ts:` in Actions, `tests/foo.test.ts:` locally.
FILE_HEADER = re.compile(r"^(?:##\[group\])?(?P<file>\S+\.(?:test|spec)\.[cm]?[jt]sx?):$")
FAIL_LINE = re.compile(r"^\(fail\) (?P<name>.+?)(?: \[[\d.]+m?s\])?$")
TIMEOUT_LINE = re.compile(r"^\^ this test timed out after (?P<ms>\d+)ms")
SUMMARY_LINE = re.compile(r"^\d+ tests? failed:$")
DEFAULT_BUDGET = 400
CALL_RESERVE = 25
# GitHub's rate limits answer 403 or 429. They cover the whole token, so one means every later
# call fails too: the census stops rather than report the history it happened to read.
RATE_LIMITED = re.compile(r"HTTP (?:403|429)\b")


def stop_if_rate_limited(error: Exception) -> None:
    if RATE_LIMITED.search(str(error)):
        raise SystemExit(f"GitHub rate limit hit partway through the census ({error}); no partial "
                         "history is reported. Retry once the limit resets.") from error


# ---------------------------------------------------------------- parsing


def web_path(path: str) -> str:
    """A test path as `tests/foo.test.ts`, relative to web/, from any absolute or ./ form."""
    path = path.replace("\\", "/")
    if "/web/" in path:
        path = path.rsplit("/web/", 1)[1]
    while path.startswith("./"):
        path = path[2:]
    return path


def parse_junit(text: str) -> list[dict]:
    """Failed test cases in a bun JUnit report: [{file, test, kind, message}].

    bun nests one <testsuite> per file and one per describe block; the test's
    full name joins the describe names and the case name with " > ", as bun's
    console output prints it."""
    # Fork runs upload these too. ElementTree expands internal entities, so a
    # report that declares any (a DOCTYPE) is refused rather than parsed.
    if re.search(r"<!(?:DOCTYPE|ENTITY)", text[:4096], re.IGNORECASE):
        raise ValueError("JUnit report declares a DOCTYPE; refusing to parse it")
    root = ET.fromstring(text)
    found: list[dict] = []

    def walk(node: ET.Element, file: str, names: list[str], depth: int) -> None:
        for child in node:
            if child.tag == "testsuite":
                child_file = child.get("file") or file
                # The outermost suite is the file itself, not a describe block.
                is_file_suite = depth == 0
                walk(child, child_file, names if is_file_suite else [*names, child.get("name", "")], depth + 1)
            elif child.tag == "testcase":
                problem = child.find("failure")
                if problem is None:
                    problem = child.find("error")
                if problem is None:
                    continue
                kind = "timeout" if "Timeout" in (problem.get("type") or "") else "failure"
                message = (problem.get("message") or problem.text or problem.get("type") or "").strip()
                found.append({
                    "file": web_path(child.get("file") or file),
                    "test": " > ".join([*names, child.get("name", "")]),
                    "kind": kind,
                    "message": " ".join(message.split())[:200],
                })

    suites = [root] if root.tag == "testsuites" else [ET.Element("testsuites")]
    if root.tag == "testsuite":
        suites[0].append(root)
    walk(suites[0], "", [], 0)
    return found


def parse_log(text: str) -> list[dict]:
    """Failed tests in a `bun test` job log: [{file, test, kind, message}].

    The file comes from the last file header before the `(fail)` line. bun
    repeats every failure in a closing summary without headers; those repeats
    are skipped, and a summary-only failure keeps an empty file."""
    found: dict[tuple[str, str], dict] = {}
    current = ""
    in_summary = False
    last: dict | None = None
    for raw in text.splitlines():
        line = ANSI.sub("", TIMESTAMP.sub("", raw)).strip()
        if not line:
            continue
        if SUMMARY_LINE.match(line):
            in_summary = True
            last = None
            continue
        if header := FILE_HEADER.match(line):
            current = web_path(header["file"])
            in_summary = False
            continue
        if fail := FAIL_LINE.match(line):
            name = fail["name"]
            if in_summary and any(test == name for _, test in found):
                last = None
                continue
            key = ("" if in_summary else current, name)
            last = found.setdefault(key, {"file": key[0], "test": name, "kind": "failure", "message": ""})
            continue
        if last is not None and (timeout := TIMEOUT_LINE.match(line)):
            last["kind"] = "timeout"
            last["message"] = f"timed out after {timeout['ms']}ms"
            last = None
    return list(found.values())


def matches(item: Mapping, test: str | None, file: str | None) -> bool:
    if test and test.lower() not in str(item.get("test", "")).lower():
        return False
    if file:
        want = web_path(file)
        have = str(item.get("file") or "")
        if not have or not (have == want or have.endswith("/" + want) or want.endswith("/" + have)):
            return False
    return True


# ---------------------------------------------------------------- GitHub with a cache


def token() -> str:
    for name in ("GITHUB_TOKEN", "GH_TOKEN"):
        if os.environ.get(name):
            return os.environ[name]
    try:
        return subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise SystemExit("set GITHUB_TOKEN or log in with `gh auth login`") from error


def cache_dir() -> Path:
    base = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache")
    # v2: cached runs carry their repository IDs (a fork's main is not main).
    return base / "cmux-ci" / "web-test-census-v2"


class Source:
    """The REST calls the census makes, each cached where its answer cannot change."""

    def __init__(self, gh: GitHub, cache: Path | None):
        self.gh, self.cache = gh, cache

    def _call(self, fetch, path: str):
        """One GET, retried once when GitHub cuts the body short (http.client.IncompleteRead is
        neither an HTTPError nor an OSError, so the client's own retry misses it)."""
        for attempt in range(2):
            try:
                return fetch(path)
            except http.client.HTTPException as error:
                if attempt:
                    raise RuntimeError(f"GET {path}: {error!r}") from error
        return None

    def _get(self, path: str):
        return self._call(self.gh.get, path)

    def _text(self, path: str, text: bool = True) -> str:
        return str(self._call(lambda p: self.gh.request("GET", p, text=True), path))

    def _cached(self, name: str) -> str | None:
        if self.cache is None:
            return None
        path = self.cache / name
        return path.read_text(errors="replace") if path.exists() else None

    def _store(self, name: str, text: str) -> None:
        if self.cache is None:
            return
        path = self.cache / name
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(text)
        tmp.replace(path)

    def core_remaining(self) -> tuple[int, int]:
        body = self._get("rate_limit") or {}
        core = body.get("resources", {}).get("core", {})  # type: ignore[union-attr]
        return int(core.get("remaining", 0)), int(core.get("reset", 0))

    def artifacts(self, name: str, since: datetime) -> list[dict]:
        found: list[dict] = []
        for page in range(1, 20):
            body = self._get(f"repos/{self.gh.repo}/actions/artifacts?name={name}&per_page=100&page={page}") or {}
            batch = list(body.get("artifacts", []))  # type: ignore[union-attr]
            fresh = [a for a in batch if parse_time(a.get("created_at")) >= since]
            found += fresh
            if len(batch) < 100 or len(fresh) < len(batch):
                break
        return found

    def junit(self, artifact: Mapping) -> str:
        name = f"junit/{artifact['id']}.xml"
        if (text := self._cached(name)) is not None:
            return text
        raw = self._call(lambda p: fetch_bytes(self.gh, p), f"repos/{self.gh.repo}/actions/artifacts/{artifact['id']}/zip")
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            xml = next((n for n in archive.namelist() if n.endswith(".xml")), None)
            text = archive.read(xml).decode("utf-8", "replace") if xml else "<testsuites/>"
        self._store(name, text)
        return text

    def log(self, job_id: int) -> str:
        name = f"logs/{job_id}.log"
        if (text := self._cached(name)) is not None:
            return text
        text = str(self._text(f"repos/{self.gh.repo}/actions/jobs/{job_id}/logs", text=True))
        self._store(name, text)
        return text

    def runs(self, since: datetime, max_runs: int, branch: str | None = None) -> list[dict]:
        """ci.yml runs created since `since` (on one branch, if given), newest first, at most
        `max_runs` of those worth inspecting."""
        found: list[dict] = []
        day = since.strftime("%Y-%m-%d")
        scope = f"&branch={urllib_quote(branch)}" if branch else ""
        for page in range(1, 50):
            if len(found) >= max_runs:
                break
            body = self._get(f"repos/{self.gh.repo}/actions/workflows/{WORKFLOW}/runs"
                               f"?created=%3E%3D{day}{scope}&per_page=100&page={page}") or {}
            batch = list(body.get("workflow_runs", []))  # type: ignore[union-attr]
            found += [slim_run(r) for r in batch if worth_inspecting(r) and parse_time(r.get("created_at")) >= since]
            if len(batch) < 100:
                break
        return found[:max_runs]

    def jobs(self, run: Mapping, attempt: int | None = None) -> list[dict]:
        """Jobs of every attempt of `run` (or of one attempt), cached once the run completed."""
        run_id = run["id"]
        latest = int(run.get("run_attempt") or 1)
        name = f"jobs/{run_id}-{attempt or 'all'}-{latest}.json"
        if (text := self._cached(name)) is not None:
            return json.loads(text)
        prefix = (f"repos/{self.gh.repo}/actions/runs/{run_id}/attempts/{attempt}/jobs?"
                  if attempt else f"repos/{self.gh.repo}/actions/runs/{run_id}/jobs?filter=all&")
        jobs: list[dict] = []
        for page in range(1, 10):
            body = self._get(f"{prefix}per_page=100&page={page}") or {}
            batch = list(body.get("jobs", []))  # type: ignore[union-attr]
            jobs += [slim_job(j) for j in batch]
            if len(batch) < 100:
                break
        if run.get("status") == "completed":
            self._store(name, json.dumps(jobs))
        return jobs

    def sha_runs(self, sha: str) -> list[dict]:
        """ci.yml runs of one head SHA (other pushes, re-runs), cached once all completed."""
        name = f"sha/{sha}.json"
        if (text := self._cached(name)) is not None:
            return json.loads(text)
        body = self._get(f"repos/{self.gh.repo}/actions/runs?head_sha={sha}&per_page=100") or {}
        runs = [slim_run(r) for r in body.get("workflow_runs", [])  # type: ignore[union-attr]
                if str(r.get("path", "")).endswith(f"/{WORKFLOW}")]
        if runs and all(r.get("status") == "completed" for r in runs):
            self._store(name, json.dumps(runs))
        return runs

    def pr_for_branch(self, branch: str) -> int | None:
        if not branch or branch == "main":
            return None
        name = f"prs/{re.sub(r'[^A-Za-z0-9._-]', '_', branch)}.json"
        if (text := self._cached(name)) is not None:
            return json.loads(text)
        owner = self.gh.repo.split("/")[0]
        body = self._get(f"repos/{self.gh.repo}/pulls?head={owner}:{urllib_quote(branch)}&state=all&per_page=1") or []
        number = int(body[0]["number"]) if body else None  # type: ignore[index]
        if number is not None:
            self._store(name, json.dumps(number))
        return number


def urllib_quote(value: str) -> str:
    import urllib.parse

    return urllib.parse.quote(value, safe="")


def fetch_bytes(gh: GitHub, path: str) -> bytes:
    """GET raw bytes (an artifact zip). The token is not sent on the redirect to blob storage."""
    url = f"{gh.api}/{path.lstrip('/')}"
    req = urllib.request.Request(url)
    req.add_unredirected_header("Authorization", f"Bearer {gh.token}")
    req.add_header("Accept", "application/vnd.github+json")
    gh.calls += 1
    try:
        with urllib.request.urlopen(req, timeout=120) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"GET {path}: HTTP {error.code}") from error


def slim_job(job: Mapping) -> dict:
    return {k: job.get(k) for k in ("id", "name", "run_id", "run_attempt", "conclusion", "status", "html_url",
                                    "head_sha", "head_branch", "started_at")}


def slim_run(run: Mapping) -> dict:
    slim = {k: run.get(k) for k in ("id", "run_attempt", "conclusion", "status", "event", "head_sha",
                                    "head_branch", "created_at", "html_url")}
    slim["head_repository_id"] = (run.get("head_repository") or {}).get("id", run.get("head_repository_id"))
    slim["repository_id"] = (run.get("repository") or {}).get("id", run.get("repository_id"))
    return slim


def is_fork(run: Mapping) -> bool:
    """A run of a fork's branch: its `main` is not this repository's main."""
    head, base = run.get("head_repository_id"), run.get("repository_id")
    return head is not None and base is not None and head != base


def parse_time(value: object) -> datetime:
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return datetime.min.replace(tzinfo=timezone.utc)


def worth_inspecting(run: Mapping) -> bool:
    """A run whose jobs could hold a failed web shard: it failed, or a re-run hid an earlier failure."""
    return run.get("status") == "completed" and (
        run.get("conclusion") not in ("success", "skipped", "cancelled") or int(run.get("run_attempt") or 1) > 1)


def shard_of(job_name: str) -> int | None:
    found = WEB_JOB.search(job_name or "")
    return int(found["shard"]) if found else None


# ---------------------------------------------------------------- collection


def from_junit(src: Source, since: datetime, test: str | None, file: str | None,
               max_reports: int = 300) -> tuple[list[dict], int]:
    """Matching failures from the shards' JUnit artifacts, and how many reports were read."""
    failures: list[dict] = []
    reports = 0
    for attempt in range(1, MAX_ATTEMPTS + 1):
        any_found = False
        for shard in range(1, SHARDS + 1):
            for artifact in src.artifacts(ARTIFACT.format(shard=shard, attempt=attempt), since):
                any_found = True
                if artifact.get("expired") or reports >= max_reports:
                    continue
                reports += 1
                run = artifact.get("workflow_run") or {}
                try:
                    items = parse_junit(src.junit(artifact))
                except (ValueError, ET.ParseError, RuntimeError, zipfile.BadZipFile) as error:
                    stop_if_rate_limited(error)
                    print(f"warning: artifact {artifact['id']}: {error}", file=sys.stderr)
                    continue
                for item in items:
                    if matches(item, test, file):
                        failures.append({**item, "source": "junit", "run_id": run.get("id"), "attempt": attempt,
                                         "shard": shard, "sha": run.get("head_sha"),
                                         "branch": run.get("head_branch"), "fork": is_fork(run),
                                         "head_repository_id": run.get("head_repository_id"),
                                         "at": artifact.get("created_at")})
        if not any_found:
            break  # no shard reached this attempt in the window, so none reached a later one
    return failures, reports


def from_logs(src: Source, since: datetime, max_main_runs: int, max_runs: int, test: str | None,
              file: str | None, branches: Iterable[str] = (), max_branch_runs: int = 100
              ) -> tuple[list[dict], dict, dict[int, list[dict]]]:
    """Matching failures from failed web shards' job logs, coverage counts, and the jobs read.

    ci.yml fails a few hundred times a day, nearly all outside the web shards, and the jobs API
    has no name filter, so every inspected run costs a call. The logs source therefore reads all
    of main's failed runs (up to max_main_runs), every run of the named branches, and the newest
    max_runs other failed runs, and reports how many it read."""
    failures: list[dict] = []
    picked: dict[int, dict] = {}
    if max_main_runs:
        for run in src.runs(since, max_main_runs, "main"):
            picked.setdefault(int(run["id"]), run)
    for branch in branches:
        for run in src.runs(since, max_branch_runs, branch):
            picked.setdefault(int(run["id"]), run)
    others = 0
    if max_runs:
        for run in src.runs(since, max_runs + len(picked)):
            if others >= max_runs:
                break
            if int(run["id"]) not in picked:
                picked[int(run["id"])] = run
                others += 1
    jobs_by_run: dict[int, list[dict]] = {}
    unreadable = 0
    for run_id, run in picked.items():
        try:
            jobs = src.jobs(run)
        except RuntimeError as error:  # one run's 502 should not lose the rest of the census
            stop_if_rate_limited(error)
            print(f"warning: run {run_id}: {error}", file=sys.stderr)
            unreadable += 1
            continue
        jobs_by_run[run_id] = jobs
        for job in jobs:
            shard = shard_of(str(job.get("name")))
            if shard is None or job.get("conclusion") not in RED:
                continue
            try:
                text = src.log(int(job["id"]))
            except RuntimeError as error:  # logs expire after 90 days
                stop_if_rate_limited(error)
                print(f"warning: job {job['id']}: {error}", file=sys.stderr)
                continue
            for item in parse_log(text):
                if matches(item, test, file):
                    failures.append({**item, "source": "log", "run_id": run_id,
                                     "attempt": job.get("run_attempt"), "shard": shard,
                                     "sha": run.get("head_sha"), "branch": run.get("head_branch"),
                                     "fork": is_fork(run), "head_repository_id": run.get("head_repository_id"),
                                     "at": job.get("started_at"), "job_url": job.get("html_url")})
    coverage = {"runs_inspected": len(picked) - unreadable, "runs_unreadable": unreadable,
                "main_runs_inspected": sum(1 for r in picked.values() if r.get("head_branch") == "main")}
    return failures, coverage, jobs_by_run


def rerun_outcome(failure: Mapping, sha_runs: Iterable[Mapping], later_jobs: Iterable[Mapping]) -> str:
    """"passed" when a later attempt passed this shard or another run of the SHA succeeded,
    "failed" when a later attempt failed it again, else "none"."""
    attempt = int(failure.get("attempt") or 1)
    outcome = "none"
    for job in later_jobs:
        if shard_of(str(job.get("name"))) != failure.get("shard") or int(job.get("run_attempt") or 1) <= attempt:
            continue
        if job.get("conclusion") == "success":
            return "passed"
        if job.get("conclusion") in RED:
            outcome = "failed"
    for run in sha_runs:
        same = run.get("id") == failure.get("run_id")
        if same and int(run.get("run_attempt") or 1) <= attempt:
            continue
        if run.get("conclusion") == "success":
            return "passed"
    return outcome


def enrich(src: Source, failures: list[dict], jobs_by_run: Mapping[int, list[dict]], lookup_prs: bool) -> None:
    """Add job links, re-run outcomes, main/PR labels and PR numbers."""
    for item in failures:
        run_id = int(item["run_id"])
        try:
            sha_runs = src.sha_runs(str(item["sha"])) if item.get("sha") else []
        except RuntimeError as error:  # the failure stays listed; only its re-run evidence is lost
            stop_if_rate_limited(error)
            print(f"warning: runs of {item.get('sha')}: {error}", file=sys.stderr)
            sha_runs = []
        run = next((r for r in sha_runs if r.get("id") == run_id), {"id": run_id, "status": "completed"})
        jobs = jobs_by_run.get(run_id)
        if jobs is None and (not item.get("job_url") or int(run.get("run_attempt") or 1) > int(item["attempt"])):
            try:
                jobs = src.jobs(run)
            except RuntimeError as error:
                stop_if_rate_limited(error)
                print(f"warning: run {run_id}: {error}", file=sys.stderr)
        jobs = jobs or []
        if not item.get("job_url"):
            job = next((j for j in jobs if shard_of(str(j.get("name"))) == item["shard"]
                        and int(j.get("run_attempt") or 1) == int(item["attempt"])), None)
            item["job_url"] = (job or {}).get("html_url") or \
                f"https://github.com/{src.gh.repo}/actions/runs/{run_id}/attempts/{item['attempt']}"
        item["rerun"] = rerun_outcome(item, sha_runs, jobs)
        item["where"] = "main" if item.get("branch") == "main" and not item.get("fork") else "pr"
        # A fork's branch name says nothing about this repository's pull requests.
        if lookup_prs and item["where"] == "pr" and not item.get("fork"):
            item["pr"] = src.pr_for_branch(str(item.get("branch") or ""))


def estimate_calls(source: str, max_main_runs: int, max_runs: int, max_reports: int) -> int:
    """An upper bound on fresh calls (cached downloads and job lists cost nothing)."""
    junit = SHARDS * MAX_ATTEMPTS * 2 + max_reports
    logs = (max_main_runs + max_runs) // 100 * 2 + 4 + (max_main_runs + max_runs) * 2
    return {"junit": junit, "logs": logs, "auto": junit + logs}[source]


def census(src: Source, *, test: str | None, file: str | None, days: int, source: str = "auto",
           max_main_runs: int = 150, max_runs: int = 60, max_reports: int = 300, branches: Iterable[str] = (),
           lookup_prs: bool = True, now: datetime | None = None) -> dict:
    since = (now or datetime.now(timezone.utc)) - timedelta(days=days)
    failures: list[dict] = []
    jobs_by_run: dict[int, list[dict]] = {}
    reports = 0
    coverage: dict = {}
    if source in ("junit", "auto"):
        failures, reports = from_junit(src, since, test, file, max_reports)
    if source == "logs" or (source == "auto" and not reports):
        failures, coverage, jobs_by_run = from_logs(src, since, max_main_runs, max_runs, test, file, branches)
    # One failure per test, run and attempt (a report and a log can both name it).
    unique: dict[tuple, dict] = {}
    for item in failures:
        unique.setdefault((item["test"], item["run_id"], item["attempt"]), item)
    failures = sorted(unique.values(), key=lambda f: str(f.get("at") or ""), reverse=True)
    enrich(src, failures, jobs_by_run, lookup_prs)
    return {
        "query": {"test": test, "file": file, "days": days},
        "since": since.isoformat(timespec="seconds"),
        "source": "junit" if reports else "logs",
        "junit_reports_read": reports,
        **coverage,
        "failures": failures,
        "summary": summarize(failures),
    }


def summarize(failures: Iterable[Mapping]) -> dict:
    failures = list(failures)
    return {
        "failures": len(failures),
        "main": sum(1 for f in failures if f.get("where") == "main"),
        "prs": sorted({str(f.get("pr") or f.get("branch")) for f in failures if f.get("where") == "pr"}),
        "passed_on_rerun": sum(1 for f in failures if f.get("rerun") == "passed"),
        "tests": sorted({f"{f.get('file')}: {f.get('test')}" for f in failures}),
    }


def render(report: Mapping) -> str:
    s = report["summary"]
    query = " ".join(f"{k}={v!r}" for k, v in report["query"].items() if v not in (None, ""))
    lines = [f"Web test failures since {report['since'][:10]} ({query}), source: {report['source']}",
             f"{s['failures']} failure(s): {s['main']} on main, {s['failures'] - s['main']} on "
             f"{len(s['prs'])} PR branch(es); {s['passed_on_rerun']} passed on a re-run of the same SHA"]
    if report["source"] == "logs":
        lines.append(f"(logs: read {report.get('runs_inspected', 0)} failed or re-run ci.yml runs, "
                     f"{report.get('main_runs_inspected', 0)} of them on main; PR runs are a newest-first "
                     "sample, raise --max-runs to read more)")
        if report.get("runs_unreadable"):
            lines.append(f"({report['runs_unreadable']} run(s) unreadable, so this history may be incomplete)")
    else:
        lines.append(f"(junit: read {report['junit_reports_read']} failed-shard reports)")
    for item in report["failures"]:
        who = "main" if item["where"] == "main" else (f"PR #{item['pr']}" if item.get("pr") else item.get("branch"))
        rerun = {"passed": "re-run passed", "failed": "re-run failed", "none": "no re-run"}[item["rerun"]]
        lines.append(f"- {str(item.get('at'))[:16]}  {who:<10}  {item['kind']:<7}  {rerun:<13}  {item['job_url']}")
        lines.append(f"    {item['file']}: {item['test']}")
    return "\n".join(lines)


def make_source(repo: str, use_cache: bool) -> Source:
    return Source(GitHub(repo, token()), cache_dir() if use_cache else None)


def check_budget(src: Source, needed: int) -> None:
    remaining, reset = src.core_remaining()
    if remaining < needed + CALL_RESERVE:
        when = datetime.fromtimestamp(reset, timezone.utc).strftime("%H:%M UTC") if reset else "later"
        raise SystemExit(f"REST rate limit: {remaining} calls left, this census may need {needed}; "
                         f"resets at {when}. Lower --max-runs or --days, or wait.")
    print(f"REST rate limit: {remaining} calls left; this census needs at most ~{needed}.", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--test", help="substring of the test's full name (describe > test), case-insensitive")
    parser.add_argument("--file", help="test file, e.g. tests/vm-route-deadlines.test.ts or its basename")
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--source", choices=("auto", "junit", "logs"), default="auto",
                        help="auto reads JUnit artifacts and falls back to logs when the window has none")
    parser.add_argument("--max-main-runs", type=int, default=150, help="logs source: main's failed runs to read")
    parser.add_argument("--max-runs", type=int, default=60,
                        help="logs source: newest other failed or re-run runs to read")
    parser.add_argument("--branch", action="append", default=[],
                        help="logs source: also read every failed run of this branch (repeatable)")
    parser.add_argument("--max-reports", type=int, default=300, help="junit source: reports to download")
    parser.add_argument("--repo", default=REPO)
    parser.add_argument("--no-cache", action="store_true")
    parser.add_argument("--no-pr-lookup", action="store_true", help="show branches instead of PR numbers")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if not (args.test or args.file):
        parser.error("give --test, --file, or both")
    src = make_source(args.repo, not args.no_cache)
    check_budget(src, estimate_calls(args.source, args.max_main_runs, args.max_runs, args.max_reports))
    started = time.monotonic()
    report = census(src, test=args.test, file=args.file, days=args.days, source=args.source,
                    max_main_runs=args.max_main_runs, max_runs=args.max_runs, max_reports=args.max_reports,
                    branches=args.branch, lookup_prs=not args.no_pr_lookup)
    report["api_calls"] = src.gh.calls
    print(json.dumps(report, indent=2) if args.json else render(report))
    print(f"{src.gh.calls} REST calls in {time.monotonic() - started:.0f}s", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
