#!/usr/bin/env python3
"""Move a run's post-admission jobs onto owned root runners that are idle now.

pr_runner_pool.py places every macOS job of a run when the run starts. The
jobs after compile admission (the app-host shards, tests-build-and-lag and
cli-product-tests) only start once admission finishes, often ten minutes
later. If the owned pool was full at the start, they are committed to
Blacksmith (admission's pool, or pr_retry_runner) and wait in its queue even
when root runners have drained in the meantime.

ci-macos.yml's late-placement job runs this after admission succeeds, on
attempt 1 of a same-repository pull request.
It reads the idle root runners live through the org route App and gives
each job that is not already owned the root label, in owned priority order,
up to that many idle runners. The shards and friends then run
test-without-building on the mini against admission's uploaded products, as
they do after an owned admission; they never compile.

Output `runners` is a JSON object from job key (shard-N, lag, cli-product)
to label. Any failure prints a warning and outputs {} (no change).
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence


def _picker():
    path = Path(__file__).with_name("pr_runner_pool.py")
    spec = importlib.util.spec_from_file_location("pr_runner_pool", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("pr_runner_pool", module)
    spec.loader.exec_module(module)
    return module


pool = _picker()


def late_jobs(*, macos: str | None, cli: str | None, full_suite: str | None, unit_suite: str | None,
              unit_in_admission: str | None, unit_selectors: str | None) -> tuple[str, ...]:
    """The jobs that run after compile admission in this run (pr_runner_pool.run_plan)."""
    plan = pool.run_plan(macos=macos, full_suite=full_suite, unit_suite=unit_suite,
                         unit_in_admission=unit_in_admission, claude_wrapper=None, cli=cli,
                         remote_daemon=None, unit_selectors=unit_selectors)
    return plan.after


def root_for(xcode_app: str | None) -> str:
    """The std root label for admission's Xcode; "" when no owned pool pins it."""
    std = [label for label in pool.owned_pools(xcode_app) if label.startswith("glaeda-std-")]
    return pool.root_label(std[0]) if std else ""


def place(jobs: Sequence[str], *, owned_jobs: str, idle: int, root: str, gui: bool = True) -> dict[str, str]:
    """Give the not-yet-owned jobs the root label, highest priority first, one per idle runner."""
    if not root or idle <= 0:
        return {}
    owned = f" {owned_jobs.strip()} " if owned_jobs.strip() else " "
    waiting = [key for key in jobs if f" {key} " not in owned and (gui or not pool.gui_job(key))]
    return {key: root for key in sorted(waiting, key=pool.priority)[:idle]}


def decide(env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None) -> tuple[dict[str, str], str]:
    jobs = late_jobs(macos=env.get("MACOS"), cli=env.get("CLI"), full_suite=env.get("FULL_SUITE"),
                     unit_suite=env.get("UNIT_SUITE"), unit_in_admission=env.get("UNIT_IN_ADMISSION"),
                     unit_selectors=env.get("UNIT_SELECTORS"))
    if not jobs:
        return {}, "no job runs after compile admission"
    root = root_for(env.get("ADMISSION_XCODE_APP"))
    if not root:
        return {}, f"no owned pool runs admission's Xcode ({env.get('ADMISSION_XCODE_APP') or 'unknown'})"
    if runners is None:
        return {}, "owned runners could not be read live"
    idle = pool.live_owned_free(runners, [root])[root]
    placed = place(jobs, owned_jobs=env.get("OWNED_JOBS", ""), idle=idle, root=root,
                   gui=env.get("POOL_OWNED_GUI", "").strip() != "0")
    if not placed:
        return {}, f"{idle} idle `{root}` runner(s); nothing to move"
    return placed, (f"{idle} idle `{root}` runner(s) now; moved {', '.join(placed)} there "
                    f"(admission ran on `{env.get('ADMISSION_RUNNER') or 'unknown'}`)")


def main(env: Mapping[str, str] = os.environ) -> int:
    runners = None
    token, repo = env.get("ROUTE_TOKEN", ""), env.get("GITHUB_REPOSITORY", "")
    if token and repo:
        try:
            runners = pool.GitHub(token, repo).runners()
        except Exception as error:  # noqa: BLE001 - fail open: keep the run-start placement
            print(f"::warning title=late placement::could not list runners ({error})")
    placed, why = decide(env, runners)
    print(f"late placement: {why}")
    output = env.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"runners={json.dumps(placed, sort_keys=True)}\n")
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"### Late placement\n\n{why}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
