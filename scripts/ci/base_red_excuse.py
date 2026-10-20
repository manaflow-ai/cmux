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

A test helper that dies on a signal names different in-flight tests and
crashed-thread frames each run, so its crash lines are not compared: the
base's job must have died on the same signal, which makes the crash the
base's (2026-10-09: a base SIGTRAP refused every feat-cmux-next PR). Failed
steps and any test red before the crash are still compared.

God-file, localization and concurrency lint is held to more: every line its
failed steps printed, numbers masked, must be on the base's too. Their findings
are lines such as `Localizable.xcstrings:key: missing uk`, not error lines, so a
pull request adding one more missing translation to a base already red there
would otherwise pass as the base's (2026-10-19: base reds in the cmux-next
checks job refused every feat-cmux-next PR, and --override cannot waive lint).
A red step that prints no test name and no error line (defaults-snapshot's
`... is stale`) is compared the same way, by what its failed steps printed.

Only a base run whose commit contains the merge-base of the head and the base
counts: an older one predates the base reds the head inherited. feat-cmux-next's
CI workflow runs only when dispatched, and on 2026-10-20 its newest run, from
02:29Z, refused every red that landed after it. With no such run the refusal
names the merge-base and base tip, the newest stale run and the command that
dispatches one. It does not dispatch it itself: that is a write that starts a
full CI run, and every lane asking at once would start one each.

Exit 0: excused (audit lines on stdout); 1: not excused; 3: GitHub rate-limited
the reads (the reset time on stderr).
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
RateLimited = _evidence.RateLimited

SETUP_STEPS = frozenset({"Set up job", "Set up runner"})
# Jobs that only report the run's other jobs: judged by those jobs, never by themselves.
AGGREGATES = frozenset({"ci-status"})
HOOK_REFUSAL = "glaeda-cmux-runner-hook: refused"
VERDICTS = frozenset({"success", "failure"})
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
# Checks whose every finding must be the base's (gh-merge-green never waives them).
LINT = re.compile(r"god[ -]?files?|l10n|locali[sz]ation|concurrency", re.IGNORECASE)
# Per-run noise in what a step prints: mktemp names and commit or object hashes.
RUN_NOISE = re.compile(r"\btmp\.[A-Za-z0-9]{6,}|\b[0-9a-f]{7,40}\b")
# check-l10n.sh prints its first 200 errors, then this.
CUT_SHORT = re.compile(r"^\.\.\. \d+ more$")
ANSI = re.compile(r"\x1b\[[0-9;]*m|\^\[\[[0-9;]*m")
# A log GitHub served without step names, and the lines that end a job's last step there.
UNKNOWN_STEP = "UNKNOWN STEP"
POST_STEPS = re.compile(r"^(Post job cleanup\.|A job completed hook has been configured|Cleaning up orphan processes)")
STARTED_HOOK = re.compile(r"^A job started hook has been configured")
RUNNER_STEPS = re.compile(r"^(Set up job|Set up runner|Complete job|Complete runner|Post )")
CRASH_LINE = re.compile(r"exited with unexpected signal code|the test helper died on signal|"
                        r"no \"Test run with\" summary line")


def lines_of(log: str) -> list[str]:
    """The text of each `job<TAB>step<TAB>stamp text` line of `gh run view --log`."""
    found = []
    for line in log.splitlines():
        parts = line.split("\t", 2)
        found.append(STAMP.sub("", parts[-1]).strip())
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
            errors.add(re.sub(r"\d+", "#", text.replace("##[error]", "").strip()))
    return steps, tests, errors


def step_lines(log: str) -> list[tuple[str, str]]:
    """(step, text) for each `job<TAB>step<TAB>stamp text` line of `gh run view --log`.
    GitHub sometimes serves a job's log with no step names, every line under `UNKNOWN STEP`
    (2026-10-20: the checks job of #22200 on a Blacksmith runner, while the base's had them).
    Then each step is told by the `##[group]Run ...` echo that opens it and ends at the next one
    or at the job's post steps; the runner's own setup, hooks and cleanup belong to no step, and
    printed() refuses when the blocks do not match the steps that ran one for one:
    otherwise the whole job, its runner banner and fetched tags, counted as one failed step's
    findings that no base run could have."""
    parsed = [(parts[1], parts[2]) for parts in (line.split("\t", 2) for line in log.splitlines())
              if len(parts) == 3]
    if not parsed or any(step != UNKNOWN_STEP for step, _ in parsed):
        return parsed
    found, step, blocks, hook, post = [], None, 0, False, False
    for _, raw in parsed:
        text = ANSI.sub("", STAMP.sub("", raw.lstrip("\ufeff"))).strip()
        if post:
            continue
        if STARTED_HOOK.match(text):
            # The runner's own job-started hook echoes a `Run` group of its own before the first step.
            hook, step = True, None
        elif POST_STEPS.match(text):
            post, step = True, None
            continue
        elif text.startswith("##[group]Run "):
            if hook:
                hook = False
                continue
            blocks += 1
            step = f"{UNKNOWN_STEP} {blocks}"
        if step is not None:
            found.append((step, raw))
    return found


def ran_steps(job: dict) -> int:
    """How many of the job's own steps ran: not the runner's set-up, completion or post steps."""
    return sum(1 for step in job.get("steps") or []
               if step.get("conclusion") not in (None, "skipped")
               and not RUNNER_STEPS.match(step.get("name") or ""))


def printed(job: dict, log: str) -> Counter[str]:
    """What the job's failed steps printed, each line counted, with numbers masked
    unless a letter leads them (a line number, total or duration; never `step2`): each
    step's output after the `##[group]` echo of its script and environment, without
    warnings or the exit-code line. A step that continues on error reports success but
    logs its `##[error]`; it counts. Output a checker cut short refuses: what it hid
    cannot be compared."""
    failed = {step["name"] for step in job.get("steps") or []
              if step.get("conclusion") not in (None, "success", "skipped")}
    lines = step_lines(log)
    blocks = {step for step, _ in lines if step.startswith(f"{UNKNOWN_STEP} ")}
    if blocks and len(blocks) != ran_steps(job):
        # A composite action or a script's own `Run` group adds a block: a step's findings could
        # then fall outside the block that logged its error, unseen. Refuse rather than guess.
        raise Refused(f"'{job.get('name')}': its log names no steps and has {len(blocks)} `Run` groups for "
                      f"{ran_steps(job)} steps; its findings cannot be told apart to compare with the base")
    for step, raw in lines:
        if "##[error]" in raw:
            failed.add(step)
    found: Counter[str] = Counter()
    echo: set[str] = set()
    for step, raw in lines:
        if step not in failed:
            continue
        text = ANSI.sub("", STAMP.sub("", raw.lstrip("\ufeff"))).strip()
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


def base_window(repo: str, base: str, sha: str, github) -> tuple[str, str]:
    """(base tip, merge-base of the head and the base), from one compare."""
    compare = github.json(f"repos/{repo}/compare/{base}...{sha}")
    tip = (compare.get("base_commit") or {}).get("sha")
    merge_base = (compare.get("merge_base_commit") or {}).get("sha")
    if not tip or not merge_base:
        raise Refused(f"cannot find the merge-base of {sha} with {base} to tell a current base run from a stale one")
    return tip, merge_base


def contains(repo: str, ancestor: str, sha: str | None, tip: str, github, known: dict[str, bool]) -> bool:
    """Whether commit SHA has ANCESTOR in its history: a base run there saw every base change the head has."""
    if not sha:
        return False
    if sha in (ancestor, tip):
        return True
    if sha not in known:
        status = github.json(f"repos/{repo}/compare/{ancestor}...{sha}?per_page=1").get("status")
        known[sha] = status in ("ahead", "identical")
    return known[sha]


def missing_base_run(repo: str, base: str, name: str, workflow, path: str, tip: str, merge_base: str,
                     stale: dict | None, github) -> str:
    """Why no base run can judge NAME, which run is missing, and how to get one."""
    file = path.rsplit("/", 1)[-1] if path else str(workflow)
    what = (f"'{name}': no completed {base} run of {file} with a verdict for it contains the merge-base "
            f"{merge_base[:12]} (base tip {tip[:12]})")
    if stale is not None:
        what += (f"; the newest with one, run {stale['id']} at {(stale.get('head_sha') or '?')[:12]}"
                 f" ({stale.get('created_at') or stale.get('updated_at') or 'time unknown'}), predates it, so it "
                 "cannot say whether this red came from the base")
    pending = [run for run in github.json(
        f"repos/{repo}/actions/workflows/{workflow}/runs?branch={base}&head_sha={tip}&per_page=5").get("workflow_runs") or []
        if run.get("status") != "completed"]
    if pending:
        return what + f"; run {pending[0]['id']} at the base tip is {pending[0].get('status')}: retry when it finishes"
    return what + f"; dispatch one, then retry when it finishes: gh workflow run {file} --repo {repo} --ref {base}"


def judge(repo: str, base: str, sha: str, runs: list[int], github, *, checks: list[str] = ()) -> list[str]:
    """Audit lines for every excused failure; raises Refused on the first that is not."""
    audit: list[str] = []
    window: tuple[str, str] | None = None
    known: dict[str, bool] = {}
    base_runs: dict[int, list[dict]] = {}
    base_jobs: dict[int, list[dict]] = {}
    jobs = head_jobs(repo, sha, runs, list(checks), github)
    if not jobs:
        # A red run or check with no failed job to show has nothing the base can excuse.
        raise Refused("no failed job found on the head to compare with the base")
    for job in jobs:
        name = job.get("name", "")
        if job.get("conclusion") != "failure":
            raise Refused(f"'{name}' is {job.get('conclusion')}: it has no verdict to compare with the base; re-run it")
        if refused_at_setup(job):
            raise Refused(f"'{name}' was refused at setup by its runner; it gets re-run, never excused")
        head_log = github.log(repo, job)
        if refused_at_setup(job, head_log):
            raise Refused(f"'{name}' was refused at setup by its runner; it gets re-run, never excused")
        head_run = github.json(f"repos/{repo}/actions/runs/{job['run_id']}")
        workflow = head_run.get("workflow_id")
        if window is None:
            window = base_window(repo, base, sha, github)
        tip, merge_base = window
        if workflow not in base_runs:
            listed = github.json(f"repos/{repo}/actions/workflows/{workflow}/runs?branch={base}&status=completed&per_page=20")
            base_runs[workflow] = [run for run in listed.get("workflow_runs") or []
                                   if run.get("event") != "pull_request" and run.get("conclusion") != "skipped"]
        # The newest base run where this job has a verdict decides: a base push
        # run's Mac job is often cancelled by the next push, or refused by a mini.
        base_run = base_job = stale = None
        for candidate_run in base_runs[workflow]:
            if candidate_run["id"] not in base_jobs:
                base_jobs[candidate_run["id"]] = [found for page in github.json(
                    f"repos/{repo}/actions/runs/{candidate_run['id']}/jobs?filter=latest&per_page=100", paginate=True)
                    for found in page.get("jobs") or []]
            found = next((found for found in base_jobs[candidate_run["id"]] if found.get("name") == name), None)
            if found is not None and found.get("conclusion") in VERDICTS and not refused_at_setup(found):
                # Runs come newest first: once one predates the merge-base, every older one does too.
                if not contains(repo, merge_base, candidate_run.get("head_sha"), tip, github, known):
                    stale = candidate_run
                    break
                base_run, base_job = candidate_run, found
                break
        if base_run is None:
            raise Refused(missing_base_run(repo, base, name, workflow, head_run.get("path") or "", tip, merge_base,
                                           stale, github))
        if base_job.get("conclusion") != "failure":
            raise Refused(f"'{name}' is not red on {base} run {base_run['id']} ({base_job.get('conclusion')}); "
                          "fix it on this head")
        head_steps, head_tests, head_errors = signature(job, head_log)
        head_crash = crash_signals(head_log)
        lint = bool(LINT.search(name))
        # A red step with no test name and no error line (defaults-snapshot's `... is stale`) is
        # compared like lint: by what its failed steps printed, numbers and hashes masked.
        by_output = lint or not (head_tests or head_errors or head_crash)
        head_printed = printed(job, head_log) if by_output else Counter()
        if by_output and not head_printed:
            raise Refused(f"'{name}': its failed steps printed nothing to compare with the base")
        base_log = github.log(repo, base_job)
        base_steps, base_tests, base_errors = signature(base_job, base_log)
        if missing := sorted(head_crash - crash_signals(base_log)):
            raise Refused(f"'{name}': the test helper died on signal {', '.join(missing)}, "
                          f"and {base} run {base_run['id']} did not")
        compared = [("failed steps", head_steps, base_steps), ("failing tests", head_tests, base_tests)]
        if by_output:
            # By count: one more copy of a base finding (a second blocking call) is the head's.
            compared.append(("findings" if lint else "output", set(head_printed - printed(base_job, base_log)), set()))
        elif not head_tests:
            compared.append(("errors", head_errors, base_errors))
        for kind, head, seen in compared:
            if missing := sorted(head - seen):
                raise Refused(f"'{name}': {kind} not on {base} run {base_run['id']}: {'; '.join(missing)[:600]}")
        crash = [f"the test helper died on signal {signal}" for signal in sorted(head_crash)]
        what = "; ".join(crash + sorted(head_tests)) or "; ".join(sorted(head_printed or head_errors))
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
    except RateLimited as error:
        print(f"rate-limited: {error}", file=sys.stderr)
        return 3
    except (Refused, KeyError, ValueError) as error:
        print(f"not excused: {error}", file=sys.stderr)
        return 1
    print("\n".join(audit))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
