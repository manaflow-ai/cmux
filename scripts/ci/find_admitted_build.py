#!/usr/bin/env python3
"""Find an earlier run of this pull request that compiled the same build inputs.

Every pull request run attempt publishes an artifact named after its
build-input fingerprint and its attempt number. A later run with the same
fingerprint has nothing new to compile, so it may skip compile admission if an
earlier run passed it in the same attempt that published that fingerprint. A
rerun can fingerprint different inputs (the selected Xcode is a repository
variable), so a pass from one attempt says nothing about another's fingerprint.
Only runs from this repository's own branches count: a fork's run can rewrite
its workflow and report anything. Any API error means "not found".

With --require-unit-tests the same lookup also requires every
`app-host unit tests` shard of that attempt to have passed. The fingerprint
covers everything those tests execute (product source, cmuxTests/, the
compile recipe and the Xcode), so a later push that leaves it unchanged, such
as a docs edit, has nothing new for them to observe. A failed or cancelled
shard never qualifies, so a red verdict is never skipped past.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from functools import partial
from typing import Callable
from urllib.parse import urlencode

ADMISSION_JOB = "macOS compile admission"


def admission_job_name(name: object) -> bool:
    """Whether a GitHub job name refers to the macOS compile admission job.

    A reusable workflow's jobs are reported as "<caller job> / <job name>", so
    the admission job is "macos / macOS compile admission" whenever ci.yml
    reaches it through ci-macos.yml. Matching the whole string silently stopped
    finding any producer when that indirection was introduced, so match the
    final segment instead.
    """
    text = name if isinstance(name, str) else ""
    return text.rsplit(" / ", 1)[-1] == ADMISSION_JOB
UNIT_TEST_JOB_PREFIX = "app-host unit tests ("


def unit_test_job_name(name: object) -> bool:
    """Whether a job name is one `app-host unit tests (N/M)` shard."""
    text = name if isinstance(name, str) else ""
    return text.rsplit(" / ", 1)[-1].startswith(UNIT_TEST_JOB_PREFIX)


def unit_tests_passed(jobs: list[dict], attempt: int) -> bool:
    """Every unit-test shard of this attempt ran and passed, and there was one."""
    shards = [
        job for job in jobs
        if job.get("run_attempt") == attempt and unit_test_job_name(job.get("name"))
    ]
    return bool(shards) and all(job.get("conclusion") == "success" for job in shards)


ARTIFACT_PREFIX = "build-inputs-"
RUNS_TO_CHECK = 6
JOB_PAGES_TO_CHECK = 3
JOBS_PER_PAGE = 100
REQUEST_TIMEOUT_SECONDS = 10
LOOKUP_TIMEOUT_SECONDS = 30

Api = Callable[[str], dict]


def gh_api(path: str, *, deadline: float) -> dict:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("admission lookup deadline reached")
    result = json.loads(subprocess.check_output(
        ["gh", "api", path], text=True, timeout=min(REQUEST_TIMEOUT_SECONDS, remaining)
    ))
    if time.monotonic() >= deadline:
        raise TimeoutError("admission lookup deadline reached")
    return result


def artifact_name(fingerprint: str, run_attempt: int) -> str:
    return f"{ARTIFACT_PREFIX}{fingerprint}-{run_attempt}"


def admitted_run(
    api: Api,
    repository: str,
    branch: str,
    fingerprint: str,
    current_run_id: int,
    require_unit_tests: bool = False,
) -> str | None:
    """URL of the run that admitted `fingerprint`, or None.

    With `require_unit_tests`, the admitting attempt must also have passed
    every app-host unit-test shard.
    """
    try:
        runs_query = urlencode({"event": "pull_request", "branch": branch, "per_page": RUNS_TO_CHECK + 1})
        runs = api(f"repos/{repository}/actions/workflows/ci.yml/runs?{runs_query}").get("workflow_runs", [])
        for run in runs:
            if run["id"] == current_run_id or run["head_repository"]["full_name"] != repository:
                continue
            # filter=all includes reruns, whose jobs can fill more than one
            # page. Bound this optional lookup; a miss just compiles again.
            for page in range(1, JOB_PAGES_TO_CHECK + 1):
                jobs_query = urlencode({"filter": "all", "per_page": JOBS_PER_PAGE, "page": page})
                jobs = api(f"repos/{repository}/actions/runs/{run['id']}/jobs?{jobs_query}").get("jobs", [])
                admitted_attempts = {
                    job["run_attempt"]
                    for job in jobs
                    if admission_job_name(job.get("name")) and job["conclusion"] == "success"
                }
                for attempt in sorted(admitted_attempts):
                    if require_unit_tests and not unit_tests_passed(jobs, attempt):
                        continue
                    artifact_query = urlencode({"name": artifact_name(fingerprint, attempt)})
                    if api(f"repos/{repository}/actions/runs/{run['id']}/artifacts?{artifact_query}").get("total_count"):
                        return run["html_url"]
                if len(jobs) < JOBS_PER_PAGE:
                    break
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError,
            json.JSONDecodeError, KeyError, TypeError, AttributeError) as error:
        print(f"lookup failed, compiling: {error}", file=sys.stderr)
    return None


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repository", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--fingerprint", required=True)
    parser.add_argument("--current-run-id", type=int, required=True)
    parser.add_argument(
        "--require-unit-tests",
        action="store_true",
        help="also require every app-host unit-test shard of that attempt to have passed",
    )
    parser.add_argument("--github-output")
    args = parser.parse_args(argv)

    # Reuse is optional: a slow API must not consume the changes job's entire
    # timeout and prevent the normal compile fallback. Share one deadline
    # across every run, jobs page and artifact request in this lookup.
    api = partial(gh_api, deadline=time.monotonic() + LOOKUP_TIMEOUT_SECONDS)
    url = admitted_run(
        api, args.repository, args.branch, args.fingerprint, args.current_run_id,
        require_unit_tests=args.require_unit_tests,
    )
    if args.require_unit_tests:
        print(f"Same build inputs already passed compile admission and every app-host unit-test shard in {url}"
              if url else "No earlier run passed the app-host unit tests on these build inputs.")
    else:
        print(f"Same build inputs already passed compile admission in {url}" if url else "No earlier run compiled these build inputs.")
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as handle:
            handle.write(f"compile_admitted={'true' if url else 'false'}\n")
            if args.require_unit_tests:
                handle.write(f"unit_tested={'true' if url else 'false'}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
