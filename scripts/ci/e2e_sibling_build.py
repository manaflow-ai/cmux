#!/usr/bin/env python3
"""Wait for an earlier test-e2e.yml run that is compiling the same revision.

Dispatches of one commit with different selectors fall in different
concurrency groups, so each compiled the same product. Of the 25 dispatches
between 2026-09-23 and 2026-09-24 that repeated a commit and pool, at least 12
compiled while an identical compile was still running in an earlier run.

`wait` runs in test-e2e.yml's Linux `sibling` job, before the build job asks
for a macOS runner. It finds the oldest unfinished earlier dispatch of this
revision on the same macOS and polls that run's build job. Exit status 0 means
the job published its product, so the build job's reuse step restores it; 1
means there is nothing to wait for, the other compile failed, or the budget ran
out, and the build job compiles as before. Only a later run waits on an earlier one,
so two runs never wait on each other.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from typing import Callable

WORKFLOW = "test-e2e.yml"
BUILD_JOB = "build"
# The build job uploads its product with this step and then runs the tests on
# the same runner, so the product is adoptable once the step succeeds, however
# long the tests take and whether or not they pass.
PUBLISH_STEP = "Upload the compiled test product"
UNFINISHED = frozenset({"queued", "in_progress", "waiting", "requested", "pending"})
# "<selectors> on <runner> @ <ref> [<dispatch id>]"; run-e2e.sh passes a full SHA.
TITLE = re.compile(r" on (\S+) @ ([0-9a-f]{40})(?: \[[^\]]*\])?$")
MACOS = re.compile(r"macos-(\d+)")
# Only a running run can be compiling. Filter on status: on 2026-09-24 this
# listing filtered on event=workflow_dispatch alone returned a page whose
# newest run was nine hours old, so it never saw a running sibling.
RUNNING = f"actions/workflows/{WORKFLOW}/runs?status=in_progress&per_page=100"


def gh_api(path: str) -> dict:
    repository = os.environ["GITHUB_REPOSITORY"]
    return json.loads(subprocess.check_output(["gh", "api", f"repos/{repository}/{path}"], text=True, timeout=60))


def same_macos(a: str, b: str) -> bool:
    """A product depends on the image's Xcode and SDK, not on the pool's size."""
    left, right = MACOS.search(a), MACOS.search(b)
    if left and right:
        return left.group(1) == right.group(1)
    return a == b


def earlier_sibling(runs: list[dict], run_id: str, revision: str, runner: str) -> dict | None:
    """The oldest unfinished earlier dispatch compiling `revision` on the same macOS."""
    matches = []
    for run in runs:
        match = TITLE.search(str(run.get("display_title", "")))
        if (match and match.group(2) == revision and same_macos(match.group(1), runner)
                and run.get("status") in UNFINISHED and int(run["id"]) < int(run_id)):
            matches.append(run)
    return min(matches, key=lambda run: int(run["id"])) if matches else None


def build_state(jobs: list[dict]) -> str:
    job = next((job for job in jobs if job.get("name") == BUILD_JOB), None)
    if job is None:
        return "running"
    steps = job.get("steps")
    if isinstance(steps, list) and any(
        isinstance(step, dict) and step.get("name") == PUBLISH_STEP and step.get("conclusion") == "success"
        for step in steps
    ):
        return "success"
    if job.get("status") != "completed":
        return "running"
    return "success" if job.get("conclusion") == "success" else "failed"


def wait(
    run_id: str,
    revision: str,
    runner: str,
    budget: float,
    poll: float = 30.0,
    get: Callable[[str], dict] = gh_api,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> bool:
    listing = get(RUNNING)
    sibling = earlier_sibling(listing.get("workflow_runs", []), run_id, revision, runner)
    if sibling is None:
        print("No earlier run is compiling this revision.")
        return False
    if budget <= 0:
        print(f"Run {sibling['id']} is compiling {revision}, but this job has no time to wait for it.")
        return False
    jobs = f"actions/runs/{sibling['id']}/jobs?filter=latest&per_page=100"
    print(
        f"Run {sibling['id']} is already compiling {revision} on {runner}; waiting up to "
        f"{int(budget // 60)} min for its product instead of compiling it a second time."
    )
    deadline = clock() + budget
    while True:
        state = build_state(get(jobs).get("jobs", []))
        if state == "success":
            print(f"Run {sibling['id']} published its product of {revision}.")
            return True
        if state == "failed":
            print(f"Run {sibling['id']} did not compile {revision}; compiling here.")
            return False
        if get(f"actions/runs/{sibling['id']}").get("status") not in UNFINISHED:
            print(f"Run {sibling['id']} finished without compiling {revision}; compiling here.")
            return False
        if clock() >= deadline:
            print(f"Run {sibling['id']} is still compiling {revision}; compiling here too.")
            return False
        sleep(poll)


def main(argv: list[str]) -> int:
    if argv[1:2] != ["wait"]:
        raise SystemExit("usage: e2e_sibling_build.py wait")
    # Show the wait in the job log while it happens, not when it ends.
    sys.stdout.reconfigure(line_buffering=True)
    try:
        found = wait(
            os.environ["GITHUB_RUN_ID"],
            os.environ["TEST_REF"],
            os.environ["CMUX_PRODUCT_RUNNER"],
            float(os.environ.get("CMUX_E2E_SIBLING_WAIT_SECONDS", "0")),
        )
    except (KeyError, ValueError, OSError, subprocess.SubprocessError) as error:
        # Waiting is an economy, never a gate.
        print(f"Could not look for an earlier compile ({error}); compiling here.")
        return 1
    return 0 if found else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
