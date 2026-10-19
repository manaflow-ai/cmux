#!/usr/bin/env python3
"""Excuse a red check that fails the same way on the base branch.

Run via scripts/gh-merge-green before it refuses a red cmux-next run or a red
required check. A failed job on the PR head is excused only when the same job
also failed on the base, and the head's failed steps and failing test names
are all among the base's. Error lines are compared only when no test failed (a
compile error, say), and warnings never are: they vary run to run (SwiftPM's
cache warnings refused #18147 on 2026-10-07). Names are compared, not counts:
the base may fail more. A runner refusal (no steps, a failed setup step, or the glaeda
hook's refusal), a cancelled or timed-out job, and a failure with no test or
error line to compare are never excused. One base red then no longer freezes
every pull request into that base (2026-10-07: four base reds, and the PRs
fixing them deadlocked on each other's reds).

Where the base verdict comes from, in order (2026-10-19: #21729 and #21807
were refused over "no base verdict" for reds the base had too):
1. The check runs on the base tip and on the merge-base of the base and the
   head. When one has no verdict for the job (a path filter skipped it, or the
   push run was cancelled), up to LOOKBACK commits before it are tried. Any
   workflow and event counts, so a job that runs in a different workflow on
   push (`web / ...` in cmux-next web) is still found. The job is red on the
   base when either line's nearest verdict fails the same way.
2. The newest completed non-pull_request runs of the head job's workflow on the
   base branch.
A job the base never runs (the cmux-next checks job before it ran on
feat-cmux-next pushes) has no base verdict; the refusal says so and lists each
commit and run it read.
Names match exactly first; failing that, ignoring a matrix suffix (`(1)`,
`(Xcode 26)`) and a reusable-workflow caller prefix (`web / `).

Every refusal names the job, the head SHA, and each base commit, run or pull
request it was compared with, so a missing base verdict never blocks silently.

God-file, localization and concurrency lint is held to more: every line its
failed steps printed, numbers masked, must be on the base's too. Their findings
are lines such as `Localizable.xcstrings:key: missing uk`, not error lines, so a
pull request adding one more missing translation to a base already red there
would otherwise pass as the base's (2026-10-19: base reds in the cmux-next
checks job refused every feat-cmux-next PR, and --override cannot waive lint).

A test helper that dies on a signal names different in-flight tests and
crashed-thread frames each run, so its crash lines are not compared: the
base's job must have died on the same signal, which makes the crash the
base's (2026-10-09: a base SIGTRAP refused every feat-cmux-next PR). Failed
steps and any test red before the crash are still compared.
"""
from __future__ import annotations

import argparse
import importlib.util
import re
import sys
from collections import Counter
from pathlib import Path

_spec = importlib.util.spec_from_file_location("main_fix_evidence", Path(__file__).with_name("main_fix_evidence.py"))
_evidence = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_evidence)
GitHub, Refused, job_for, latest_checks = _evidence.GitHub, _evidence.Refused, _evidence.job_for, _evidence.latest_checks

SETUP_STEPS = frozenset({"Set up job", "Set up runner"})
# Jobs that only report the run's other jobs: judged by those jobs, never by themselves.
AGGREGATES = frozenset({"ci-status"})
HOOK_REFUSAL = "glaeda-cmux-runner-hook: refused"
VERDICTS = frozenset({"success", "failure"})
# Base commits tried before the tip and before the merge-base when they have no verdict.
LOOKBACK = 5
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
STAMP = re.compile(r"^﻿?\d{4}-\d\d-\d\dT[\d:.]+Z ?")
# SwiftPM's line for a killed test helper, and the hang sampler's ::error lines for it.
CRASH = re.compile(r"exited with unexpected signal code (\d+)|the test helper died on signal (\d+)")
# Checks whose every finding must be the base's (gh-merge-green never waives them).
LINT = re.compile(r"god[ -]?files?|l10n|locali[sz]ation|concurrency", re.IGNORECASE)
# Per-run noise in what a step prints: mktemp names and commit or object hashes.
RUN_NOISE = re.compile(r"\btmp\.[A-Za-z0-9]{6,}|\b[0-9a-f]{7,40}\b")
# check-l10n.sh prints its first 200 errors, then this.
CUT_SHORT = re.compile(r"^\.\.\. \d+ more$")
ANSI = re.compile(r"\x1b\[[0-9;]*m|\^\[\[[0-9;]*m")
CRASH_LINE = re.compile(r"exited with unexpected signal code|the test helper died on signal|"
                        r"no \"Test run with\" summary line")
# A trailing matrix value: `(1)`, `(Xcode 26)`, `(${{ matrix.shard }})`.
MATRIX = re.compile(r"\s*\((?:[^()]|\([^()]*\))*\)\s*$")
UNKNOWN_STEP = "UNKNOWN STEP"


def short(sha: str | None) -> str:
    return (sha or "?")[:10]


def lines_of(log: str) -> list[str]:
    """The text of each `job<TAB>step<TAB>stamp text` line of `gh run view --log`."""
    found = []
    for line in log.splitlines():
        parts = line.split("\t", 2)
        found.append(STAMP.sub("", parts[-1]).strip())
    return found


def soft_failed_steps(job: dict, log: str) -> set[str]:
    """Steps that logged an ##[error] although the API does not call them failed (continue-on-error).

    The cmux-next checks job runs each lint as such a step and fails only in its last
    step, so these name which lints are red.
    """
    failed = {step["name"] for step in job.get("steps") or []
              if step.get("conclusion") not in (None, "success", "skipped")}
    found = set()
    for line in log.splitlines():
        parts = line.split("\t", 2)
        if len(parts) == 3 and parts[1] not in failed and parts[1] != UNKNOWN_STEP and "##[error]" in parts[2]:
            found.add(parts[1])
    return found


def signature(job: dict, log: str) -> tuple[set[str], set[str], set[str]]:
    """(failed step names, failing test names, error lines with numbers masked)."""
    steps = {step["name"] for step in job.get("steps") or []
             if step.get("conclusion") not in (None, "success", "skipped")}
    steps |= soft_failed_steps(job, log)
    tests: set[str] = set()
    errors: set[str] = set()
    for text in lines_of(log):
        for pattern in TESTS:
            if match := pattern.search(text):
                tests.add(match.group(1))
        if ERROR.search(text) and not GENERIC.search(text) and not WARNING.search(text) and not CRASH_LINE.search(text):
            errors.add(re.sub(r"\d+", "#", text.replace("##[error]", "").strip()))
    return steps, tests, errors


def printed(job: dict, log: str) -> Counter[str]:
    """What the job's failed steps printed, each line counted, with numbers masked
    unless a letter leads them (a line number, total or duration; never `step2`): each
    step's output after the `##[group]` echo of its script and environment, without
    warnings or the exit-code line. A step that continues on error reports success but
    logs its `##[error]`; it counts. Output a checker cut short refuses: what it hid
    cannot be compared."""
    failed = {step["name"] for step in job.get("steps") or []
              if step.get("conclusion") not in (None, "success", "skipped")}
    for line in log.splitlines():
        parts = line.split("\t", 2)
        if len(parts) == 3 and "##[error]" in parts[2]:
            failed.add(parts[1])
    found: Counter[str] = Counter()
    echo: set[str] = set()
    for line in log.splitlines():
        parts = line.split("\t", 2)
        if len(parts) < 3 or parts[1] not in failed:
            continue
        step, text = parts[1], ANSI.sub("", STAMP.sub("", parts[2].lstrip("\ufeff"))).strip()
        if text.startswith("##[group]"):
            echo.add(step)
            continue
        if text.startswith("##[endgroup]"):
            echo.discard(step)
            continue
        if step in echo or not text or WARNING.search(text) or GENERIC.search(text):
            continue
        if CUT_SHORT.match(text):
            raise Refused(f"'{job.get('name')}': step '{step}' printed output cut short ({text}); "
                          "the findings it hid cannot be compared with the base")
        found[re.sub(r"(?<![A-Za-z0-9_])\d+", "#", RUN_NOISE.sub("…", text.replace("##[error]", "").strip()))] += 1
    return found


def crash_signals(log: str) -> set[str]:
    """The signals a test helper died on, from SwiftPM's or the hang sampler's lines."""
    return {first or second for first, second in CRASH.findall(log)}


def refused_at_setup(job: dict, log: str | None = None) -> bool:
    steps = job.get("steps") or []
    if not steps or any(step.get("name") in SETUP_STEPS and step.get("conclusion") == "failure" for step in steps):
        return True
    return log is not None and HOOK_REFUSAL in log


def name_tiers(name: str) -> list[str]:
    """Keys from strictest to loosest: exact, no matrix suffix, no caller prefix, neither."""
    bare = MATRIX.sub("", name).strip()
    tail = name.rsplit(" / ", 1)[-1].strip()
    tail_bare = MATRIX.sub("", tail).strip()
    return [key.casefold() for key in (name, bare, tail, tail_bare)]


def matching(name: str, candidates: list[dict]) -> tuple[list[dict], str]:
    """The candidates (jobs or check runs) that are `name`, at the strictest tier any reaches."""
    wanted = name_tiers(name)
    labels = ("", " (matched without its matrix suffix)", " (matched without its caller prefix)",
              " (matched without its matrix suffix and caller prefix)")
    for tier, key in enumerate(wanted):
        if not key:
            continue
        found = [candidate for candidate in candidates
                 if (candidate_key := name_tiers(candidate.get("name") or "")[tier]) and candidate_key == key]
        if found:
            return found, labels[tier]
    return [], ""


def job_url(repo: str, job: dict) -> str:
    return job.get("html_url") or f"https://github.com/{repo}/actions/runs/{job.get('run_id')}/job/{job.get('id')}"


def head_jobs(repo: str, sha: str, runs: list[int], checks: list[str], github) -> list[dict]:
    jobs: dict[int, dict] = {}
    for run in runs:
        for page in github.json(f"repos/{repo}/actions/runs/{run}/jobs?filter=latest&per_page=100", paginate=True):
            for job in page.get("jobs") or []:
                if job.get("name") in AGGREGATES:
                    continue
                if job.get("status") == "completed" and job.get("conclusion") not in ("success", "skipped", "neutral"):
                    if job.get("head_sha") not in (None, sha):
                        raise Refused(f"{job.get('name')}: job is not for the exact SHA {sha}")
                    jobs[job["id"]] = job
    if checks:
        latest = latest_checks(repo, sha, github)
        aggregate_runs = []
        for name in checks:
            if name not in latest:
                raise Refused(f"{name}: has not run on exact head {sha}")
            job = job_for(repo, latest[name], sha, github)
            if name in AGGREGATES:
                aggregate_runs.append(job["run_id"])
            else:
                jobs[job["id"]] = job
        for run in aggregate_runs:
            found = head_jobs(repo, sha, [run], [], github)
            if not found:
                raise Refused(f"run {run}: its aggregate check failed with no failed job to compare with the base")
            jobs.update((job["id"], job) for job in found)
    return list(jobs.values())


class Head:
    """One failed head job and the signature every base candidate is compared with."""

    def __init__(self, repo: str, job: dict, log: str):
        self.job, self.name, self.url = job, job.get("name", ""), job_url(repo, job)
        self.steps, self.tests, self.errors = signature(job, log)
        self.crash = crash_signals(log)
        self.soft = soft_failed_steps(job, log)
        self.lint = bool(LINT.search(self.name))
        self.printed = printed(job, log) if self.lint else Counter()

    def mismatch(self, base_job: dict, base_log: str, where: str) -> str | None:
        """Why `base_job` does not fail the way this head job does, or None when it does."""
        base_steps, base_tests, base_errors = signature(base_job, base_log)
        if missing := sorted(self.crash - crash_signals(base_log)):
            return f"the test helper died on signal {', '.join(missing)}, and {where} did not"
        compared = [("failed steps", self.steps, base_steps), ("failing tests", self.tests, base_tests)]
        if self.lint:
            try:
                base_printed = printed(base_job, base_log)
            except Refused as cut_short:
                return f"{where}: {cut_short}"
            # By count: one more copy of a base finding (a second blocking call) is the head's.
            compared.append(("findings", set(self.printed - base_printed), set()))
        elif not self.tests:
            compared.append(("errors", self.errors, base_errors))
        for kind, head, seen in compared:
            if missing := sorted(head - seen):
                return f"{kind} not on {where}: {'; '.join(missing)[:600]}"
        return None

    def what(self) -> str:
        crash = [f"the test helper died on signal {signal}" for signal in sorted(self.crash)]
        found = "; ".join(crash + sorted(self.tests)) or "; ".join(sorted(self.printed or self.errors)) or \
            "red steps " + "; ".join(sorted(self.soft))
        return found[:400]


class Base:
    """Base-branch evidence, fetched lazily and shared by every failed head job."""

    def __init__(self, repo: str, base: str, sha: str, github, lookback: int = LOOKBACK):
        self.repo, self.base, self.sha, self.github, self.lookback = repo, base, sha, github, lookback
        self._lines: list[tuple[str, list[tuple[str, str]]]] | None = None
        self._checks: dict[str, dict] = {}
        self._jobs: dict[int, dict] = {}
        self._run_jobs: dict[int, list[dict]] = {}
        self._workflow_runs: dict[int, list[dict]] = {}
        self._logs: dict[int, str] = {}
        self.notes: list[str] = []
        self.tip_is_merge_base = False

    def history(self, ref: str) -> list[str]:
        listed = self.github.json(f"repos/{self.repo}/commits?sha={ref}&per_page={self.lookback + 1}")
        return [commit["sha"] for commit in listed if isinstance(commit, dict) and isinstance(commit.get("sha"), str)]

    def lines(self) -> list[tuple[str, list[tuple[str, str]]]]:
        """[(line name, [(commit, label), ...])] for the base tip and the merge-base."""
        if self._lines is not None:
            return self._lines
        self._lines = []
        try:
            tip_history = self.history(self.base)
        except Refused as error:
            self.notes.append(f"could not list {self.base} commits ({error})")
            return self._lines
        if not tip_history:
            self.notes.append(f"GitHub listed no {self.base} commits")
            return self._lines
        tip = tip_history[0]
        self._lines.append(("base tip", [(commit, "base tip" if index == 0 else f"base tip~{index}")
                                         for index, commit in enumerate(tip_history)]))
        try:
            compared = self.github.json(f"repos/{self.repo}/compare/{tip}...{self.sha}?per_page=1")
            merge_base = ((compared or {}).get("merge_base_commit") or {}).get("sha")
        except Refused as error:
            merge_base = None
            self.notes.append(f"could not read the merge-base of {short(tip)} and {short(self.sha)} ({error})")
        if merge_base and merge_base != tip:
            try:
                history = self.history(merge_base) if merge_base not in tip_history else \
                    tip_history[tip_history.index(merge_base):]
            except Refused as error:
                history = [merge_base]
                self.notes.append(f"could not list commits before merge-base {short(merge_base)} ({error})")
            self._lines.append(("merge-base", [(commit, "merge-base" if index == 0 else f"merge-base~{index}")
                                               for index, commit in enumerate(history)]))
        elif merge_base == tip:
            self.tip_is_merge_base = True
        return self._lines

    def checks(self, commit: str) -> dict:
        if commit not in self._checks:
            try:
                self._checks[commit] = latest_checks(self.repo, commit, self.github)
            except Refused as error:
                self.notes.append(f"could not read check runs on {short(commit)} ({error})")
                self._checks[commit] = {}
        return self._checks[commit]

    def job(self, check: dict, commit: str) -> dict | None:
        url = check.get("details_url", "")
        match = re.fullmatch(r"https://github\.com/" + re.escape(self.repo) + r"/actions/runs/(\d+)/job/(\d+)", url)
        if not match:
            return None
        job_id = int(match[2])
        if job_id not in self._jobs:
            try:
                self._jobs[job_id] = self.github.json(f"repos/{self.repo}/actions/jobs/{job_id}")
            except Refused as error:
                self.notes.append(f"could not read base job {job_id} ({error})")
                self._jobs[job_id] = {}
        job = self._jobs[job_id]
        if job.get("head_sha") not in (None, commit) or job.get("status") != "completed":
            return None
        return job

    def log(self, job: dict) -> str:
        if job["id"] not in self._logs:
            self._logs[job["id"]] = self.github.log(self.repo, job)
        return self._logs[job["id"]]

    def run_jobs(self, run: int) -> list[dict]:
        if run not in self._run_jobs:
            self._run_jobs[run] = [found for page in self.github.json(
                f"repos/{self.repo}/actions/runs/{run}/jobs?filter=latest&per_page=100", paginate=True)
                for found in page.get("jobs") or []]
        return self._run_jobs[run]

    def workflow_runs(self, workflow) -> list[dict]:
        if workflow not in self._workflow_runs:
            listed = self.github.json(
                f"repos/{self.repo}/actions/workflows/{workflow}/runs?branch={self.base}&status=completed&per_page=20")
            self._workflow_runs[workflow] = [run for run in listed.get("workflow_runs") or []
                                             if run.get("event") != "pull_request" and run.get("conclusion") != "skipped"]
        return self._workflow_runs[workflow]


def verdict_at(head: Head, base: Base, commit: str) -> tuple[list[dict], str]:
    """The base jobs at `commit` with a verdict for the head job, and how the name matched."""
    checks = list(base.checks(commit).values())
    found, how = matching(head.name, checks)
    jobs = []
    for check in found:
        job = base.job(check, commit)
        if job and job.get("conclusion") in VERDICTS and not refused_at_setup(job):
            jobs.append(job)
    return jobs, how


def judge_on_commits(head: Head, base: Base) -> tuple[str | None, list[str], bool]:
    """(audit line or None, reasons it did not excuse, whether any base commit had a verdict)."""
    reasons, had_verdict = [], False
    for line, commits in base.lines():
        for commit, label in commits:
            jobs, how = verdict_at(head, base, commit)
            if not jobs:
                continue
            had_verdict = True
            where = f"{label} {short(commit)}"
            for job in jobs:
                if job.get("conclusion") != "failure":
                    reasons.append(f"green on {where} ({job.get('name')}{how}: {job_url(base.repo, job)})")
                    continue
                if why := head.mismatch(job, base.log(job), f"{where} ({job_url(base.repo, job)})"):
                    reasons.append(why)
                    continue
                return (f"excused '{head.name}': {base.base} {where} fails the same way "
                        f"({job.get('name')}{how}: {job_url(base.repo, job)}): {head.what()}"), reasons, True
            break
        else:
            before = ", ".join(short(commit) for commit, _ in commits[1:])
            also = ", also the merge-base" if line == "base tip" and base.tip_is_merge_base else ""
            reasons.append(f"no verdict at the {line} ({short(commits[0][0])}{also})"
                           + (f" or the {len(commits) - 1} commits before it ({before})" if before else ""))
    if not base.lines():
        reasons.append(f"no {base.base} commits to compare with ({'; '.join(base.notes) or 'none listed'})")
    return None, reasons, had_verdict


def judge_on_base_runs(head: Head, base: Base, workflow) -> tuple[str | None, str | None, bool]:
    """The newest base run of the head job's workflow that has a verdict for it decides."""
    for candidate_run in base.workflow_runs(workflow):
        found, how = matching(head.name, base.run_jobs(candidate_run["id"]))
        found = [job for job in found if job.get("conclusion") in VERDICTS and not refused_at_setup(job)]
        if not found:
            continue
        where = f"{base.base} run {candidate_run['id']}"
        reasons = []
        for job in found:
            if job.get("conclusion") != "failure":
                reasons.append(f"'{head.name}' is not red on {where} ({job.get('conclusion')}{how}); fix it on this head")
                continue
            if why := head.mismatch(job, base.log(job), where):
                reasons.append(f"'{head.name}': {why}")
                continue
            url = candidate_run.get("html_url") or f"https://github.com/{base.repo}/actions/runs/{candidate_run['id']}"
            return f"excused '{head.name}': {where} fails the same way{how} ({url}): {head.what()}", None, True
        return None, "; ".join(reasons), True
    runs = base.workflow_runs(workflow)
    return None, (f"no completed {base.base} run of its workflow has a verdict for it "
                  f"({len(runs)} non-pull_request {base.base} runs of workflow {workflow} read)"), False


def judge(repo: str, base: str, sha: str, runs: list[int], github, *, checks: list[str] = (),
          lookback: int = LOOKBACK) -> list[str]:
    """Audit lines for every excused failure; raises Refused naming every one that is not."""
    audit: list[str] = []
    refusals: list[str] = []
    evidence = Base(repo, base, sha, github, lookback)
    jobs = head_jobs(repo, sha, runs, list(checks), github)
    if not jobs:
        # A red run or check with no failed job to show has nothing the base can excuse.
        raise Refused(f"no failed job found on the head {short(sha)} to compare with the base")
    for job in jobs:
        name = job.get("name", "")
        if job.get("conclusion") != "failure":
            refusals.append(f"'{name}' is {job.get('conclusion')} at {short(sha)}: it has no verdict to compare "
                            "with the base; re-run it")
            continue
        if refused_at_setup(job):
            refusals.append(f"'{name}' was refused at setup by its runner at {short(sha)}; it gets re-run, never excused")
            continue
        head_log = github.log(repo, job)
        if refused_at_setup(job, head_log):
            refusals.append(f"'{name}' was refused at setup by its runner at {short(sha)}; it gets re-run, never excused")
            continue
        try:
            head = Head(repo, job, head_log)
        except Refused as cut_short:
            refusals.append(f"{cut_short} (at {short(sha)}, {job_url(repo, job)})")
            continue
        if head.lint and not head.printed:
            refusals.append(f"'{name}' at {short(sha)} ({head.url}): its failed steps printed nothing to compare "
                            "with the base")
            continue
        if not head.lint and not head.tests and not head.errors and not head.crash and not head.soft:
            refusals.append(f"'{name}' at {short(sha)} ({head.url}): no failing test or error line to match; "
                            "nothing to compare with the base")
            continue
        excused, commit_reasons, had_verdict = judge_on_commits(head, evidence)
        if excused:
            audit.append(excused)
            continue
        workflow = github.json(f"repos/{repo}/actions/runs/{job['run_id']}").get("workflow_id")
        excused, run_reason, run_verdict = judge_on_base_runs(head, evidence, workflow)
        if excused:
            audit.append(excused)
            continue
        tried = [f"{base} commits: {'; '.join(commit_reasons)}"] if commit_reasons else []
        if run_reason:
            tried.append(run_reason)
        if not had_verdict and not run_verdict:
            tried.append(f"dispatch its workflow on {base} for a base verdict "
                         f"(gh workflow run <workflow> --repo {repo} --ref {base}), or fix it on this head")
            refusals.append(f"'{name}' at {short(sha)} ({head.url}): no {base} verdict to compare with: "
                            + " | ".join(tried))
        else:
            refusals.append(f"'{name}' at {short(sha)} ({head.url}) is not red the same way on {base}: "
                            + " | ".join(tried))
    if refusals:
        notes = f" [{'; '.join(dict.fromkeys(evidence.notes))}]" if evidence.notes else ""
        raise Refused("\n".join(refusals) + notes)
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
