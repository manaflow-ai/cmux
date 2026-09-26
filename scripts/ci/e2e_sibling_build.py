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
out, and the build job compiles as before.

A run waits only on a run whose current attempt started before its own
(run_started_at, then id), so two runs never wait on each other. The id alone
is not that order: a full re-run keeps its id but starts again, after runs
with higher ids may have begun compiling. A run re-run while another waits on
it has started after the waiter, so the waiter stops and compiles.

A re-run of failed jobs, as the owned-pool rescue does, does not re-run this
job, so that attempt never waits. Run 36168890047's attempt 2 compiled product
8c48a10e of 4f0ac55 at 17:47Z beside run 36168944875 that way.
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
# On an owned Mac the build job tests first and uploads after, under this name.
PUBLISH_AFTER_TESTS_STEP = "Upload the compiled test product after the tests"
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
    """A product depends on the image's Xcode and SDK, not on the pool's size.

    An owned pool's label names no macOS, so it matches only itself: the
    contract also hashes the node, go and bun versions, and no run has yet
    shown an owned Mac's product key to equal Blacksmith's.
    """
    left, right = MACOS.search(a), MACOS.search(b)
    if left and right:
        return left.group(1) == right.group(1)
    return a == b


def started(run: dict) -> tuple[str, int]:
    """When the run's current attempt started, then its id: the order runs wait in.

    GitHub writes run_started_at as UTC "YYYY-MM-DDTHH:MM:SSZ", so the strings
    order as times. A run without one sorts first.
    """
    return str(run.get("run_started_at") or ""), int(run["id"])


def title_pool(run: dict) -> str:
    """The pool a dispatch asked for, from its title."""
    match = TITLE.search(str(run.get("display_title", "")))
    return match.group(1) if match else ""


def routed_pool(get: Callable[[str], dict], run: dict) -> str:
    """The pool a run's build job was routed to, or the one its title asked for.

    The runner job may route a dispatch to another pool than its title names:
    with CI_PR_POOL_OWNED set, a `blacksmith-6vcpu-macos-26` dispatch builds on
    an owned Mac. Matching titles against the routed label found no sibling for
    any such run, so on 2026-09-25 runs 36175110586, 36175263632 and
    36176202852 each compiled 2a40caa on an owned Mac within 11 minutes.
    Once the build job exists its runs-on label is the routed pool; before
    that the run is still choosing, and its title is the best guess.
    """
    jobs = get(f"actions/runs/{run['id']}/jobs?filter=latest&per_page=100").get("jobs", [])
    build = next((job for job in jobs if job.get("name") == BUILD_JOB), None)
    labels = build.get("labels") if isinstance(build, dict) else None
    if isinstance(labels, list) and labels and isinstance(labels[0], str):
        return labels[0]
    return title_pool(run)


def earlier_sibling(runs: list[dict], this: dict, revision: str, runner: str,
                    pool: Callable[[dict], str] = title_pool) -> dict | None:
    """The unfinished dispatch compiling `revision` on the same macOS that started first, before `this`."""
    matches = []
    for run in runs:
        match = TITLE.search(str(run.get("display_title", "")))
        if (match and match.group(2) == revision
                and run.get("status") in UNFINISHED and started(run) < started(this)
                and same_macos(pool(run), runner)):
            matches.append(run)
    return min(matches, key=started) if matches else None


def build_state(jobs: list[dict]) -> str:
    job = next((job for job in jobs if job.get("name") == BUILD_JOB), None)
    if job is None:
        return "running"
    steps = job.get("steps")
    if isinstance(steps, list) and any(
        isinstance(step, dict) and step.get("name") in (PUBLISH_STEP, PUBLISH_AFTER_TESTS_STEP)
        and step.get("conclusion") == "success"
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
    pool: Callable[[dict], str] | None = None,
) -> bool:
    runs = get(RUNNING).get("workflow_runs", [])
    this = next((run for run in runs if str(run.get("id")) == run_id), None) or get(f"actions/runs/{run_id}")
    sibling = earlier_sibling(runs, this, revision, runner, pool or (lambda run: routed_pool(get, run)))
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
        current = get(f"actions/runs/{sibling['id']}")
        if current.get("status") not in UNFINISHED:
            print(f"Run {sibling['id']} finished without compiling {revision}; compiling here.")
            return False
        if started(current) > started(this):
            print(f"Run {sibling['id']} was re-run after this run started; compiling here.")
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
