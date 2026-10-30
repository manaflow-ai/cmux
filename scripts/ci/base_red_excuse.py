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
error line to compare are never excused. One base red then no longer freezes
every pull request into that base (2026-10-07: four base reds, and the PRs
fixing them deadlocked on each other's reds).

A job that runs tests is judged per test by scripts/ci/test_reds.py, the one
classifier for "red on the base, so not ours" (2026-10-28: cmux#26346 landed
with its own test helper crash because the job was red on the base too). A
failing test the base's run does not fail is the head's; a crash (signal,
abort, EXC_*, Fatal error) is the head's whatever the base shows; and a run
whose per-test results are cut short (no summary, ended early, stuck) is the
head's, since nothing in it can be compared.

A compile check that gave no verdict (the build fleet's "no result", "No build-fleet verdict") is never a
base red, even with the base's identical line: nothing compiled the head. It is set aside only when the
same head has a real compile pass (a green Mac Release compile or a cmux-next/compile success). Error
lines are compared with commit shas masked, so a real red that names each run's own commit still matches.

A rollup job (ci-status, Guard status, macOS status: a job whose every step only reads its `needs` results)
has no test or error of its own: its red is the reds of the jobs under it. It is found in the run's workflow
files at the head, never from a list of names. It is excused only when it has a failed job under it in the same
run, every one of them is excused above, and the rollup itself is red the same way on the base: red there too, with
its failed steps and every line its own steps printed (their diagnostics: "workflow-guard-history: skipped (route
...)", "Generated cmux-next files are stale") among the base's. A rollup also fails on what no failed job shows: a
required job that was skipped, a bad route, a verdict read from a need's outputs; those reasons are only the base's
when the base printed them too. Its job definition must be the same in the base run's workflow: a workflow edited
at the head (a step that just fails, given a `needs` expression, or a changed default shell, env or caller input
above it) is never judged as a rollup. A rollup with nothing
failed under it, one whose own output cannot be found in its log, one changed at the head, and one whose workflow
cannot be read (then it is judged as an ordinary job, with nothing to compare), stays red.
"""
from __future__ import annotations

import argparse
import base64
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path

_spec = importlib.util.spec_from_file_location("main_fix_evidence", Path(__file__).with_name("main_fix_evidence.py"))
_evidence = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_evidence)
Refused, job_for, latest_checks = _evidence.Refused, _evidence.job_for, _evidence.latest_checks


class GitHub(_evidence.GitHub):
    """GitHub client for red attribution, including logs of finished jobs in live runs."""

    def log(self, repo: str, job: dict) -> str:
        # `gh run view --log` waits for every job in the run. The Actions job
        # endpoint serves a finished job while sibling jobs remain queued.
        # gh refuses to print a log holding escape sequences (ANSI colours) unless asked.
        return self.run(["api", "--allow-escape-sequences", f"repos/{repo}/actions/jobs/{job['id']}/logs"])
_spec = importlib.util.spec_from_file_location("test_reds", Path(__file__).with_name("test_reds.py"))
test_reds = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(test_reds)

SETUP_STEPS = frozenset({"Set up job", "Set up runner"})
# A rollup job reports the run's other jobs and runs nothing of its own: it has `needs`, no step that `uses:`
# an action (so nothing checked out, no repo code), and every step reads its needs' results through its `env:` or
# `run:`. It is judged by the failed jobs under it, never by itself (Graph and HeadJobs, below).
NEEDS_RESULT = re.compile(r"toJSON\(\s*needs\s*\)|\bneeds\.[\w-]+\.result\b|\bneeds\[[^\]]+\]\.result\b", re.I)
EXPRESSION = re.compile(r"\$\{\{.*?\}\}")
# A reusable workflow in the same repository, read at the same commit; any other `uses:` is opaque.
LOCAL_WORKFLOW = re.compile(r"\./(\.github/workflows/[^@\s]+\.ya?ml)")
# A red rollup's own output ends at its failing step's exit line; the runner's closing hooks follow it.
STEP_EXIT = re.compile(r"##\[error\]Process completed with exit code \d+\.?$")
ANSI = re.compile(r"\x1b\[[0-9;]*m")
# GitHub nests reusable workflows at most four deep.
MAX_WORKFLOW_DEPTH = 4
# Where the workflow files at a run's head are read from first: this git repository (a mirror or checkout that has the
# head commit; an agent host's gh broker refuses repository source reads through the API), then this script's own
# checkout, and only then the contents API (CI, where the API is the job's own token).
GIT_DIR_ENV = "BASE_RED_EXCUSE_GIT_DIR"
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
TESTS = (
    re.compile(r"✘ Test (.+?\)) (?:recorded an issue|failed)"),  # Swift Testing
    re.compile(r"Test Case '-\[(\S+ \S+)\]' failed"),  # XCTest
    re.compile(r"^test (\S+) \.\.\. FAILED$"),  # cargo test
    re.compile(r"^(?:FAIL|ERROR): (\S+ \([^)]+\))"),  # unittest
    re.compile(r"^FAILED (\S+::\S+)"),  # pytest
)
ERROR = re.compile(r"##\[error\]|\berror:")
WARNING = re.compile(r"##\[warning\]|\bwarning:")
# Summaries carry counts, and a test's own lines already name it.
GENERIC = re.compile(r"Process completed with exit code|red tests?:|✘ Test |Test Case '|\.\.\. FAILED$")
STAMP = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ?")
# SwiftPM's line for a killed test helper, and the hang sampler's ::error lines for it.
CRASH = re.compile(r"exited with unexpected signal code (\d+)|the test helper died on signal (\d+)")
CRASH_LINE = re.compile(r"exited with unexpected signal code|the test helper died on signal|"
                        r"no \"Test run with\" summary line")
# A commit sha inside an error line: a full 40-hex sha, or 7 to 39 hex digits right after a word that
# names a commit (commit, sha, tree, revision). The same red on the head and the base names each run's
# own commit; any other hex id (an artifact, a hash) is compared as it is.
SHA = re.compile(r"\b[0-9a-f]{40}\b|\b((?:commit|sha|tree|revision) `?)[0-9a-f]{7,39}\b")
# A compile check that gave no verdict (the build-fleet controller unreachable, timed out, or a result
# for another head): nothing compiled the head, so it is never a base red, whatever the base shows
# (2026-10-28: the fleet Release compile's "no result" was red on PRs and on the base alike while the
# controller was wedged). It is set aside only when another job compiled that same head: COMPILE_PASSES.
# Only the job's own ::error annotation counts (`##[error]` at the start of the line): the log also
# echoes the step's script, which spells these words out on every run, a real compile red included.
# Fail closed: of compile-status's own lines, only "(fail)" is a real compile red; every other state (no result,
# unavailable, mismatch, unreadable, pending, "last: ...", a pass it could not post) and a status it could not
# post at all are no verdict.
NO_VERDICT = re.compile(r"^##\[error\]\s*(?:cmux-next/compile is not a pass for \S+ \((?!fail\))|"
                        r"could not post the pending status|bad head sha |No build-fleet verdict for `)")
# The jobs that can end without a verdict: an unreadable log of one is never comparable either.
NO_VERDICT_JOBS = frozenset({"cmux-next fleet Release compile", "cmux-next app compile (build fleet)"})
# A real compile pass at the head: the Mac Release compile (a check run), or the fleet's cmux-next/compile
# commit status.
COMPILE_PASS_CHECKS = ("cmux-next Release compile (Xcode 26)",)
COMPILE_PASS_STATUS = "cmux-next/compile"
# The Mac Release compile's steps that compile (or reuse a pass for the same inputs).
COMPILE_STEPS = frozenset({"Release compile", "Reuse that pass"})


def mask_shas(text: str) -> str:
    return SHA.sub(lambda match: (match.group(1) or "") + "<sha>", text)


def lines_of(log: str) -> list[str]:
    """The text of each `job<TAB>step<TAB>stamp text` line of `gh run view --log`."""
    found = []
    for line in log.splitlines():
        parts = line.split("\t", 2)
        # `gh run view --log` prefixes each line with job and step columns.
        # The job-log API does not; preserve tabs in raw command output.
        text = parts[2] if len(parts) == 3 and STAMP.match(parts[2]) else line
        found.append(STAMP.sub("", text).strip())
    return found


def signature(job: dict, log: str) -> tuple[set[str], set[str], set[str]]:
    """(failed step names, failing test names, error lines with numbers masked)."""
    steps = {step["name"] for step in job.get("steps") or []
             if step.get("conclusion") not in (None, "success", "skipped")}
    tests: set[str] = set()
    errors: set[str] = set()
    for text in lines_of(log):
        for pattern in TESTS:
            if match := pattern.search(text):
                tests.add(match.group(1))
        if ERROR.search(text) and not GENERIC.search(text) and not WARNING.search(text) and not CRASH_LINE.search(text):
            errors.add(re.sub(r"\d+", "#", mask_shas(text.replace("##[error]", "").strip())))
    return steps, tests, errors


def no_verdict(log: str) -> str | None:
    """The line where a compile check says it gave no verdict, if it does."""
    return next((text for text in lines_of(log) if NO_VERDICT.match(text)), None)


def compile_pass_at(repo: str, sha: str, github) -> str | None:
    """What compiled SHA itself and passed: the newest Mac Release compile job at SHA that ran (its
    `Release compile` or `Reuse that pass` step succeeded), or a cmux-next/compile success."""
    candidates = []
    for page in github.json(f"repos/{repo}/commits/{sha}/check-runs?per_page=100", paginate=True):
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
        steps = {step.get("name"): step.get("conclusion") for step in job.get("steps") or []}
        if not COMPILE_STEPS & steps.keys():
            continue
        if job.get("conclusion") == "success" and any(steps.get(name) == "success" for name in COMPILE_STEPS):
            return f"'{check['name']}' (job {link[2]})"
        break
    status = github.json(f"repos/{repo}/commits/{sha}/status")
    for found in status.get("statuses") or []:
        if found.get("context") == COMPILE_PASS_STATUS:
            # The combined status lists the newest per context.
            if found.get("state") == "success":
                return f"the {COMPILE_PASS_STATUS} status"
            break
    return None


def crash_signals(log: str) -> set[str]:
    """The signals a test helper died on, from SwiftPM's or the hang sampler's lines."""
    return {first or second for first, second in CRASH.findall(log)}


def refused_at_setup(job: dict, log: str | None = None) -> bool:
    steps = job.get("steps") or []
    if not steps or any(step.get("name") in SETUP_STEPS and step.get("conclusion") == "failure" for step in steps):
        return True
    return log is not None and HOOK_REFUSAL in log


def is_rollup(job: dict) -> bool:
    """True when JOB (a workflow's job mapping) only rolls up the results of its `needs`."""
    steps = job.get("steps")
    return (bool(job.get("needs")) and "uses" not in job and isinstance(steps, list) and bool(steps)
            and all(isinstance(step, dict) and "uses" not in step
                    and NEEDS_RESULT.search(json.dumps([step.get("env"), step.get("run")]))
                    for step in steps))


def step_header(step: dict) -> tuple[str, re.Pattern]:
    """(the API's name for a `run:` step, its log's `##[group]Run ...` header): the header is the script's first line,
    an expression matching anything; an unnamed step is named after that line, as GitHub names it."""
    first = next((line.strip() for line in str(step.get("run") or "").splitlines() if line.strip()), "")
    return (str(step.get("name") or f"Run {first}"),
            re.compile(r"##\[group\]Run " + ".*".join(re.escape(part) for part in EXPRESSION.split(first))))


def step_output(job: dict, log: str, steps: list[tuple[str, re.Pattern]]) -> set[str] | None:
    """Every line the rollup's own steps printed in JOB's LOG (numbers and commit shas masked), or None when that
    cannot be read whole. The output runs from the end of the first step's echoed script (its `##[group]Run ...`
    header to the first `##[endgroup]`) to the log's last exit line, the failing step's end; only the later steps'
    own echoed scripts are cut out of it. Group titles, warnings and notices inside it are compared like any line.
    None when a step that ran is missing, in order, when a section has no end, or when no exit line follows."""
    listed = [step.get("name") for step in job.get("steps") or []]
    # A step is told from the API's list by its name, so a name that repeats there or among the rollup's steps cannot
    # say which ran: never read.
    if len(set(listed)) != len(listed) or len({name for name, _ in steps}) != len(steps):
        return None
    ran = {step.get("name"): step.get("conclusion") for step in job.get("steps") or []}
    lines = [ANSI.sub("", line) for line in lines_of(log)]
    echoed: list[tuple[int, int]] = []  # (header, endgroup) of each step that ran
    at = 0
    for name, header in steps:
        if name not in ran:
            return None
        if ran[name] == "skipped":
            continue
        start = next((index for index in range(at, len(lines)) if header.fullmatch(lines[index])), None)
        if start is None:
            return None
        end_group = next((index for index in range(start + 1, len(lines)) if lines[index].startswith("##[endgroup]")),
                         None)
        if end_group is None:
            return None
        echoed.append((start, end_group))
        at = end_group + 1
    if not echoed:
        return None
    end = next((index for index in range(len(lines) - 1, echoed[-1][1], -1) if STEP_EXIT.match(lines[index])), None)
    if end is None:
        return None
    found: set[str] = set()
    for index in range(echoed[0][1] + 1, end):
        if any(start <= index <= end_group for start, end_group in echoed):
            continue
        text = re.sub(r"^##\[(?:error|warning|notice|debug|group)\]", "", lines[index]).strip()
        if text and text != "##[endgroup]":
            found.add(re.sub(r"\d+", "#", mask_shas(text)))
    return found


def name_pattern(name: str, matrix: bool) -> tuple[str, bool]:
    """(regex, literal) for the run's display name of a job named NAME: an expression matches anything, and a
    matrix job's name may carry its values in parentheses."""
    regex = ".*".join(re.escape(part) for part in EXPRESSION.split(name))
    literal = EXPRESSION.search(name) is None and not matrix
    if matrix and EXPRESSION.search(name) is None:
        regex += r"(?: \(.+\))?"
    return regex, literal


class Graph:
    """The jobs of one workflow run as its workflow files at the run's head declare them (`needs:`, names and
    reusable workflow calls), so a rollup's jobs come from the workflow, never from a list of names."""

    def __init__(self, read):
        self.read = read
        self.nodes: dict[str, dict] = {}

    def add_file(self, path: str, prefix: str = "", scope: str = "", depth: int = 0, literal_prefix: bool = True,
                 context: tuple = ()) -> None:
        import yaml  # PyYAML; an ImportError leaves the graph unread, so every job is judged as itself.

        if depth > MAX_WORKFLOW_DEPTH:
            raise ValueError(f"{path}: reusable workflows nested past {MAX_WORKFLOW_DEPTH}")
        workflow = yaml.safe_load(self.read(path))
        jobs = workflow.get("jobs")
        if not isinstance(jobs, dict) or not jobs:
            raise ValueError(f"{path}: no jobs")
        # Everything else in the file (env, defaults, permissions, on, ...) shapes how its jobs run.
        context = context + ({str(key): value for key, value in workflow.items() if key != "jobs"},)
        for key, job in jobs.items():
            if not isinstance(job, dict):
                raise ValueError(f"{path}: job {key} is not a mapping")
            needs = job.get("needs") or []
            needs = [needs] if isinstance(needs, str) else list(needs)
            strategy = job.get("strategy")
            matrix = isinstance(strategy, dict) and bool(strategy.get("matrix"))
            regex, literal = name_pattern(str(job.get("name") or key), matrix)
            node = {"id": scope + str(key), "key": str(key), "needs": [scope + str(need) for need in needs],
                    "rollup": is_rollup(job), "caller": "uses" in job,
                    # The job as written, with every file and caller job above it, to tell a rollup the head changed
                    # from the base's.
                    "definition": json.dumps([context, job], sort_keys=True, default=str),
                    "headers": [step_header(step) for step in job.get("steps") or []] if is_rollup(job) else []}
            if node["caller"]:
                # Every job of a called workflow shows as "<caller> / <job>".
                node.update(pattern=re.compile(prefix + regex + " / .+"), literal=False)
                if match := LOCAL_WORKFLOW.fullmatch(str(job["uses"]).strip()):
                    self.add_file(match[1], prefix + regex + " / ", node["id"] + "/", depth + 1,
                                  literal_prefix and literal, context + (job,))
            else:
                node.update(pattern=re.compile(prefix + regex), literal=literal_prefix and literal)
            self.nodes[node["id"]] = node

    def resolve(self, name: str) -> dict | None:
        """The one job of the workflow that NAME is, or None when no job or more than one could be."""
        found = [node for node in self.nodes.values() if not node["caller"] and node["pattern"].fullmatch(name)]
        exact = [node for node in found if node["literal"]]
        found = exact or found
        return found[0] if len(found) == 1 else None

    def under(self, node: dict) -> list[re.Pattern]:
        """The display-name patterns of every job NODE depends on, directly or through other jobs; a called
        workflow brings all of its jobs."""
        patterns, seen, queue = [], {node["id"]}, list(node["needs"])
        while queue:
            need = queue.pop()
            if need in seen:
                continue
            seen.add(need)
            if need not in self.nodes:
                raise Refused(f"'{node['key']}' needs '{need}', which its workflow does not declare")
            found = self.nodes[need]
            patterns.append(found["pattern"])
            if found["caller"]:
                patterns.extend(inner["pattern"] for inner in self.nodes.values()
                                if inner["id"].startswith(need + "/"))
            queue.extend(found["needs"])
        return patterns


def git_file(sha: str, path: str) -> str | None:
    """PATH at commit SHA from a local git repository that has it (GIT_DIR_ENV, then this script's checkout)."""
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        return None
    for where in (os.environ.get(GIT_DIR_ENV), str(Path(__file__).resolve().parent)):
        if not where:
            continue
        try:
            # A partial clone would fetch a missing commit from its remote; only what is already here counts.
            found = subprocess.run(["git", "-C", where, "show", f"{sha}:{path}"], capture_output=True, timeout=30,
                                   stdin=subprocess.DEVNULL, env={**os.environ, "GIT_NO_LAZY_FETCH": "1"})
        except (OSError, subprocess.SubprocessError):
            continue
        if found.returncode == 0:
            return found.stdout.decode()
    return None


def workflow_graph(repo: str, run: dict, github) -> Graph | None:
    """RUN's job graph from its workflow file at its head commit, or None when that cannot be read."""
    path, sha = run.get("path"), run.get("head_sha")
    if not isinstance(path, str) or not isinstance(sha, str) or not path.startswith(".github/workflows/"):
        return None
    files: dict[str, str] = {}

    def read(name: str) -> str:
        if name not in files:
            text = git_file(sha, name)
            if text is None:
                found = github.json(f"repos/{repo}/contents/{name}?ref={sha}")
                if found.get("encoding") != "base64" or not isinstance(found.get("content"), str):
                    raise ValueError(f"{name}: no file content at {sha}")
                text = base64.b64decode(found["content"]).decode()
            files[name] = text
        return files[name]

    graph = Graph(read)
    try:
        graph.add_file(path.split("@", 1)[0])
    except Exception:  # noqa: BLE001 - any unreadable workflow leaves every job judged as itself (fail closed)
        return None
    return graph


def failed(job: dict) -> bool:
    return job.get("status") == "completed" and job.get("conclusion") not in ("success", "skipped", "neutral")


class HeadJobs:
    """The head's failed jobs to compare with the base, with every rollup replaced by the failed jobs under it."""

    def __init__(self, repo: str, sha: str, github):
        self.repo, self.sha, self.github = repo, sha, github
        self.jobs: dict[int, dict] = {}
        self.notes: list[str] = []
        self.runs: dict[int, dict] = {}
        self.run_jobs: dict[int, list[dict]] = {}
        self.graphs: dict[int, Graph | None] = {}
        # Rollups found among the head's reds: compared with the base as well, minus the need for a test line.
        self.rollups: dict[int, dict] = {}
        self.rollup_nodes: dict[int, dict] = {}
        # A job brought in by a rollup: the rollup's name, so a refusal says which red it stands for.
        self.parents: dict[int, str] = {}
        self.current: int | None = None  # the job judge_jobs is comparing now

    def run(self, run_id: int) -> dict:
        if run_id not in self.runs:
            self.runs[run_id] = self.github.json(f"repos/{self.repo}/actions/runs/{run_id}")
        return self.runs[run_id]

    def jobs_of(self, run_id: int) -> list[dict]:
        if run_id not in self.run_jobs:
            self.run_jobs[run_id] = [job for page in self.github.json(
                f"repos/{self.repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=100", paginate=True)
                for job in page.get("jobs") or []]
        return self.run_jobs[run_id]

    def graph(self, run_id: int, run: dict | None = None) -> Graph | None:
        if run_id not in self.graphs:
            self.graphs[run_id] = workflow_graph(self.repo, run or self.run(run_id), self.github)
        return self.graphs[run_id]

    def add(self, job: dict) -> None:
        if job.get("head_sha") not in (None, self.sha):
            raise Refused(f"{job.get('name')}: job is not for the exact SHA {self.sha}")
        if job["id"] in self.jobs or job["id"] in self.rollups:
            return
        graph = self.graph(job["run_id"])
        node = graph.resolve(job.get("name", "")) if graph is not None else None
        if node is None or not node["rollup"]:
            self.jobs[job["id"]] = job
            return
        self.rollups[job["id"]] = job
        self.rollup_nodes[job["id"]] = node
        patterns = graph.under(node)
        under = [found for found in self.jobs_of(job["run_id"])
                 if found["id"] != job["id"] and failed(found)
                 and any(pattern.fullmatch(found.get("name", "")) for pattern in patterns)]
        if not under:
            raise Refused(f"'{job.get('name')}' rolls up {', '.join(sorted(need.rsplit('/', 1)[-1] for need in node['needs']))} "
                          f"and no job under it failed in run {job['run_id']}: nothing to compare with the base")
        self.notes.append(f"'{job.get('name')}' rolls up run {job['run_id']}'s jobs; judged by the failed ones under it: "
                          + "; ".join(sorted(found.get("name", "") for found in under))[:600])
        for found in under:
            self.parents.setdefault(found["id"], self.parents.get(job["id"], job.get("name", "")))
            self.add(found)


def head_jobs(repo: str, sha: str, runs: list[int], checks: list[str], github, notes: list[str] | None = None,
              head: HeadJobs | None = None) -> list[dict]:
    head = head or HeadJobs(repo, sha, github)
    for run in runs:
        for job in head.jobs_of(run):
            if failed(job):
                head.add(job)
    if checks:
        latest = latest_checks(repo, sha, github)
        for name in checks:
            if name not in latest:
                raise Refused(f"{name}: has not run on exact head {sha}")
            head.add(job_for(repo, latest[name], sha, github))
    if notes is not None:
        notes.extend(head.notes)
    # A rollup only gets here with failed jobs under it (add refuses one without), so it is never alone. It is judged
    # after them, so a refusal names the job under it that is not the base's before the rollup's own lines.
    return list(head.jobs.values()) + list(head.rollups.values())


def judge(repo: str, base: str, sha: str, runs: list[int], github, *, checks: list[str] = ()) -> list[str]:
    """Audit lines for every excused failure; raises Refused on the first that is not."""
    reds = HeadJobs(repo, sha, github)
    try:
        return judge_jobs(repo, base, sha, runs, github, list(checks), reds)
    except Refused as error:
        if reds.current in reds.parents:
            raise Refused(f"'{reds.parents[reds.current]}' rolls up a red that is not excused: {error}") from None
        raise


def judge_jobs(repo: str, base: str, sha: str, runs: list[int], github, checks: list[str], reds: HeadJobs) -> list[str]:
    audit: list[str] = []
    base_runs: dict[int, list[dict]] = {}
    base_jobs: dict[int, list[dict]] = {}
    job_reads: dict[int, int] = {}
    jobs = head_jobs(repo, sha, runs, checks, github, audit, reds)
    if not jobs:
        # A red run or check with no failed job to show has nothing the base can excuse.
        raise Refused("no failed job found on the head to compare with the base")
    for job in jobs:
        reds.current = job["id"]
        name = job.get("name", "")
        if job.get("conclusion") != "failure":
            raise Refused(f"'{name}' is {job.get('conclusion')}: it has no verdict to compare with the base; re-run it")
        if refused_at_setup(job):
            raise Refused(f"'{name}' was refused at setup by its runner; it gets re-run, never excused")
        head_log = github.log(repo, job)
        if refused_at_setup(job, head_log):
            raise Refused(f"'{name}' was refused at setup by its runner; it gets re-run, never excused")
        if name in NO_VERDICT_JOBS and (said := no_verdict(head_log)) is not None:
            proof = compile_pass_at(repo, sha, github)
            if proof is None:
                raise Refused(f"'{name}' gave no compile verdict ({said[:300]}) and nothing else compiled {sha}: "
                              "a no-verdict compile is never a base red; re-run it once the fleet answers")
            audit.append(f"ignored '{name}': it gave no compile verdict, but {proof} compiled {sha} and passed")
            continue
        own = test_reds.read(head_log)
        if test_reds.is_test_red(own, name) and (own.crashes or own.truncated):
            raise Refused(f"'{name}': " + "; ".join(own.crashes + own.truncated[:1])[:800]
                          + " (a crash or a cut-short run is never a base red)")
        workflow = reds.run(job["run_id"]).get("workflow_id")
        if workflow not in base_runs:
            listed = github.json(f"repos/{repo}/actions/workflows/{workflow}/runs?branch={base}&status=completed"
                                 f"&per_page={BASE_RUNS_PAGE}")
            base_runs[workflow] = [run for run in listed.get("workflow_runs") or []
                                   if run.get("event") != "pull_request" and run.get("conclusion") != "skipped"]
        # The newest base run where this job has a verdict decides: a base push
        # run's Mac job is often cancelled by the next push, or refused by a mini.
        base_run = base_job = None
        for candidate_run in base_runs[workflow]:
            if candidate_run["id"] not in base_jobs:
                if job_reads.get(workflow, 0) >= BASE_JOB_READS:
                    break
                job_reads[workflow] = job_reads.get(workflow, 0) + 1
                base_jobs[candidate_run["id"]] = [found for page in github.json(
                    f"repos/{repo}/actions/runs/{candidate_run['id']}/jobs?filter=latest&per_page=100", paginate=True)
                    for found in page.get("jobs") or []]
            found = next((found for found in base_jobs[candidate_run["id"]] if found.get("name") == name), None)
            if found is not None and found.get("conclusion") in VERDICTS and not refused_at_setup(found):
                base_run, base_job = candidate_run, found
                break
        if base_run is None:
            raise Refused(f"'{name}': no completed {base} run of its workflow has a verdict for it to compare with "
                          f"(read the {BASE_RUNS_PAGE} newest, up to {BASE_JOB_READS} job lists)")
        if base_job.get("conclusion") != "failure":
            raise Refused(f"'{name}' is not red on {base} run {base_run['id']} ({base_job.get('conclusion')}); "
                          "fix it on this head")
        head_steps, head_tests, head_errors = signature(job, head_log)
        head_crash = crash_signals(head_log)
        # A rollup's red is the jobs under it, each compared on its own; its own lines, if any, are compared below.
        if not head_tests and not head_errors and not head_crash and job["id"] not in reds.rollups:
            raise Refused(f"'{name}': no failing test or error line to match; nothing to compare with the base")
        base_log = github.log(repo, base_job)
        base_steps, base_tests, base_errors = signature(base_job, base_log)
        verdict = test_reds.classify(head_log, base_log, name, f"{base} run {base_run['id']}")
        if verdict is not None and verdict.own:
            raise Refused(f"'{name}': " + "; ".join(verdict.reasons)[:800])
        # Not a test job (a compile or tool that died on a signal): the base must have died the same way.
        if missing := sorted(head_crash - crash_signals(base_log)):
            raise Refused(f"'{name}': the process died on signal {', '.join(missing)}, "
                          f"and {base} run {base_run['id']} did not")
        compared = [("failed steps", head_steps, base_steps), ("failing tests", head_tests, base_tests)]
        if not head_tests:
            compared.append(("errors", head_errors, base_errors))
        if job["id"] in reds.rollup_nodes:
            base_graph = reds.graph(base_run["id"], base_run)
            base_node = base_graph.resolve(name) if base_graph is not None else None
            if base_node is None or base_node["definition"] != reds.rollup_nodes[job["id"]]["definition"]:
                raise Refused(f"'{name}': its job in the workflow at the head is not the one {base} run {base_run['id']} "
                              "ran (or that workflow cannot be read); a changed rollup is never judged by its jobs")
            steps = reds.rollup_nodes[job["id"]]["headers"]
            said = step_output(job, head_log, steps)
            if said is None:
                raise Refused(f"'{name}': its own steps' output is not in its log whole; nothing to compare with the base")
            base_said = step_output(base_job, base_log, steps)
            if base_said is None:
                raise Refused(f"'{name}': its own steps' output is not in {base} run {base_run['id']}'s log whole; "
                              "nothing to compare with")
            compared.append(("lines it printed", said, base_said))
        for kind, head, seen in compared:
            if missing := sorted(head - seen):
                raise Refused(f"'{name}': {kind} not on {base} run {base_run['id']}: {'; '.join(missing)[:600]}")
        what = "; ".join(sorted(head_tests)) or "; ".join(sorted(head_errors))
        if job["id"] in reds.rollups:
            what = what or "the failed steps " + "; ".join(sorted(head_steps))
            what += " (and the jobs under it, each excused here)"
        url = base_run.get("html_url") or f"https://github.com/{repo}/actions/runs/{base_run['id']}"
        audit.append(f"excused '{name}': {base} run {base_run['id']} fails the same way ({url}): {what[:400]}")
    return audit


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--run", type=int, action="append", default=[], help="a failed workflow run on the head")
    parser.add_argument("--check", action="append", default=[], help="a red required check on the head")
    args = parser.parse_args(argv)
    try:
        audit = judge(args.repo, args.base, args.sha, args.run, GitHub(), checks=args.check)
    except (Refused, KeyError, ValueError) as error:
        print(f"not excused: {error}", file=sys.stderr)
        return 1
    print("\n".join(audit))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
