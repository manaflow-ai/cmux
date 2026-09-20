#!/usr/bin/env python3
"""Find an earlier run of this pull request that compiled the same build inputs.

Every pull request run publishes an artifact named after its build-input
fingerprint. A later run with the same fingerprint has nothing new to compile,
so it may skip compile admission if an earlier run with that artifact passed it.
Only runs from this repository's own branches count: a fork's run can rewrite
its workflow and report anything. Any API error means "not found".
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from typing import Callable

ADMISSION_JOB = "macOS compile admission"
ARTIFACT_PREFIX = "build-inputs-"
RUNS_TO_CHECK = 6

Api = Callable[[str], dict]


def gh_api(path: str) -> dict:
    return json.loads(subprocess.check_output(["gh", "api", path], text=True))


def admitted_run(api: Api, repository: str, branch: str, fingerprint: str, current_run_id: int) -> str | None:
    """URL of the run that admitted `fingerprint`, or None."""
    try:
        runs = api(
            f"repos/{repository}/actions/workflows/ci.yml/runs"
            f"?event=pull_request&branch={branch}&per_page={RUNS_TO_CHECK + 1}"
        ).get("workflow_runs", [])
        for run in runs:
            if run["id"] == current_run_id or run["head_repository"]["full_name"] != repository:
                continue
            artifacts = api(
                f"repos/{repository}/actions/runs/{run['id']}/artifacts?name={ARTIFACT_PREFIX}{fingerprint}"
            )
            if not artifacts.get("total_count"):
                continue
            jobs = api(f"repos/{repository}/actions/runs/{run['id']}/jobs?filter=all&per_page=100").get("jobs", [])
            if any(job["name"] == ADMISSION_JOB and job["conclusion"] == "success" for job in jobs):
                return run["html_url"]
    except (subprocess.CalledProcessError, json.JSONDecodeError, KeyError, TypeError) as error:
        print(f"lookup failed, compiling: {error}", file=sys.stderr)
    return None


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repository", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--fingerprint", required=True)
    parser.add_argument("--current-run-id", type=int, required=True)
    parser.add_argument("--github-output")
    args = parser.parse_args(argv)

    url = admitted_run(gh_api, args.repository, args.branch, args.fingerprint, args.current_run_id)
    print(f"Same build inputs already passed compile admission in {url}" if url else "No earlier run compiled these build inputs.")
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as handle:
            handle.write(f"compile_admitted={'true' if url else 'false'}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
