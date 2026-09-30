#!/usr/bin/env python3
"""List the tests one CI run failed, as a markdown section for a tracking issue.

ci-macos-15.yml runs the full app-host suite and swift-package-tests on macOS 15
(Xcode 26.3) on a schedule, as a non-gating signal. main_full_suite.py report
--tracker macos-15 keeps one issue for it and adds this section, so the issue
names the failing tests, not only the failing jobs.

App-host shards are read the way main_regression_attribution.py reads main's:
the ratchet's RATCHET_NEW_FAILURE lines and xcodebuild's "Failing tests:"
block, less the known-failures catalog (the ratchet tolerates those, so they
do not fail a shard), and a shard whose app host restarted names the test it
was running. Failed swift-package-tests jobs are read for XCTest
`Test Case '-[...]' failed` lines and Swift Testing `✘ Test ... failed` lines.
A failed job this finds no test in is listed as such.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections.abc import Iterable, Mapping
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import main_regression_attribution as attribution  # noqa: E402

PACKAGE_JOB_RE = re.compile(r"(?:^|/ )swift-package-tests\b|Swift package tests", re.IGNORECASE)
XCTEST_FAILED_RE = re.compile(r"Test Case '-\[(?:[\w]+\.)?(\w+) (\w+)\]' failed")
SWIFT_TESTING_FAILED_RE = re.compile(r"✘ Test (.+?) failed after")
MAX_LISTED_TESTS = 60
# Roll-up jobs that fail because another job did; listing them adds nothing.
ROLLUP_JOB_RE = re.compile(r"(?:^|/ )macOS status$")


def package_failures(log_text: str) -> set[str]:
    """Failing test names in one swift-package-tests job log."""
    found = set()
    for raw in log_text.splitlines():
        line = attribution.clean(raw)
        xctest = XCTEST_FAILED_RE.search(line)
        if xctest:
            found.add(f"{xctest.group(1)}/{xctest.group(2)}")
            continue
        swift_testing = SWIFT_TESTING_FAILED_RE.search(line)
        if swift_testing:
            found.add(swift_testing.group(1).strip())
    return found


def section(
    app_host: Mapping[str, list[str]],
    crashes: Iterable[attribution.HostCrash],
    packages: Mapping[str, list[str]],
    silent_jobs: Iterable[Mapping[str, object]],
) -> str:
    """The markdown section: failing tests with the job each failed in."""
    lines = ["### Failing tests", ""]
    rows: list[str] = []
    for test in sorted(app_host):
        rows.append(f"- `{test}` (app-host, [log]({app_host[test][0]}))")
    for crash in crashes:
        where = f"[log]({crash.job_url})" if crash.job_url else crash.shard
        signature = f": `{crash.signatures[0]}`" if crash.signatures else ""
        for test in crash.tests:
            rows.append(f"- `{test}` (app-host, the app host crashed while running it{signature}, {where})")
    for test in sorted(packages):
        rows.append(f"- `{test}` (swift-package-tests, [log]({packages[test][0]}))")
    if rows:
        lines += rows[:MAX_LISTED_TESTS]
        if len(rows) > MAX_LISTED_TESTS:
            lines.append(f"- ...and {len(rows) - MAX_LISTED_TESTS} more")
    else:
        lines.append("No failing test was found in the failed jobs' logs.")
    silent = list(silent_jobs)
    if silent:
        lines += ["", "Failed jobs with no failing test in their log (a build, setup or infrastructure failure):"]
        lines += [f"- [{job.get('name')}]({job.get('html_url')})" for job in silent]
    return "\n".join(lines) + "\n"


def command_section(args: argparse.Namespace) -> int:
    jobs = attribution.run_jobs(args.repo, args.run_id)
    known = set(json.loads(attribution.CATALOG.read_text(encoding="utf-8")).get("tests") or {})
    app_host, _, _, crashes = attribution.job_failures(args.repo, jobs, known)
    crashes = [crash for crash in crashes if crash.tests]
    crashed = {test for crash in crashes for test in crash.tests}
    app_host = {test: urls for test, urls in app_host.items() if test not in crashed}

    from app_host_failure_census import _gh_api_escape_flag

    packages: dict[str, list[str]] = {}
    silent = []
    reported = {url for urls in app_host.values() for url in urls} | {crash.job_url for crash in crashes}
    for job in jobs:
        if job.get("conclusion") not in {"failure", "timed_out"} or ROLLUP_JOB_RE.search(str(job.get("name") or "")):
            continue
        url = str(job.get("html_url") or "")
        if PACKAGE_JOB_RE.search(str(job.get("name") or "")):
            log = attribution.gh(["api", *_gh_api_escape_flag(), f"repos/{args.repo}/actions/jobs/{job['id']}/logs"])
            found = package_failures(log)
            for test in found:
                packages.setdefault(test, []).append(url)
            if found:
                continue
        if url not in reported:
            silent.append(job)
    text = section(app_host, crashes, packages, silent)
    print(text)
    if args.output:
        Path(args.output).write_text(text, encoding="utf-8")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--output", help="write the markdown section here")
    args = parser.parse_args(argv)
    if not args.repo:
        parser.error("--repo or GITHUB_REPOSITORY is required")
    return command_section(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
