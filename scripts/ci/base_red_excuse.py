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
"""
from __future__ import annotations

import argparse
import importlib.util
import re
import sys
from pathlib import Path

_spec = importlib.util.spec_from_file_location("main_fix_evidence", Path(__file__).with_name("main_fix_evidence.py"))
_evidence = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_evidence)
GitHub, Refused, job_for, latest_checks = _evidence.GitHub, _evidence.Refused, _evidence.job_for, _evidence.latest_checks
_spec = importlib.util.spec_from_file_location("test_reds", Path(__file__).with_name("test_reds.py"))
test_reds = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(test_reds)

SETUP_STEPS = frozenset({"Set up job", "Set up runner"})
# Jobs that only report the run's other jobs: judged by those jobs, never by themselves.
AGGREGATES = frozenset({"ci-status"})
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
NO_VERDICT = re.compile(r"^##\[error\](?:cmux-next/compile is not a pass for \S+ \((?!fail\))|"
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


def judge(repo: str, base: str, sha: str, runs: list[int], github, *, checks: list[str] = ()) -> list[str]:
    """Audit lines for every excused failure; raises Refused on the first that is not."""
    audit: list[str] = []
    base_runs: dict[int, list[dict]] = {}
    base_jobs: dict[int, list[dict]] = {}
    job_reads: dict[int, int] = {}
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
        workflow = github.json(f"repos/{repo}/actions/runs/{job['run_id']}").get("workflow_id")
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
        if not head_tests and not head_errors and not head_crash:
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
        for kind, head, seen in compared:
            if missing := sorted(head - seen):
                raise Refused(f"'{name}': {kind} not on {base} run {base_run['id']}: {'; '.join(missing)[:600]}")
        what = "; ".join(sorted(head_tests)) or "; ".join(sorted(head_errors))
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
