#!/usr/bin/env python3
"""Place a side-lane workflow's macOS jobs on an owned runner only when one is idle now.

Side-lane workflows (owned_pool_rescue.SIDE_WORKFLOW_PATHS) have no picker.
On attempt 1 of a trusted run their macOS jobs took vars.CI_SIDE_LANE_RUNNER,
the std minis' glaeda-side-* label, whatever the fleet's load. When every side
runner was busy, the jobs sat queued until ci-owned-pool-rescue.yml's budget
(90 s) ran out, and the rescue cancelled the run and re-ran it; attempt 2 took
Blacksmith. Of 60 cmux-next.yml runs on 2026-10-02 (UTC), 49 needed attempt 2,
and in each attempt 1 sampled the Mac jobs never got a runner.

A workflow's placement job runs this before its macOS jobs, on attempt 1 of a
trusted run. It lists the runners through the org route App
(pr_runner_pool.GitHub.runners(), as admission_placement.py does) and places
JOBS, in priority order, with pr_runner_pool.idle_placement(), the rule the
main picker places the light side lanes with: one job per runner carrying
SIDE_LABEL that is online and idle now. The minis stay first; a job no idle
runner takes keeps the job's fallback (vars.MACOS_RUNNER_26 or Blacksmith, the
label attempt 2 takes) instead of a queue the rescue would cancel. A runner
taken between this read and the job's queueing still leaves the job queued
on the owned label, which the rescue moves as before.

Anything uncertain decides nothing and keeps today's route (the owned label,
watched by the rescue): an attempt after 1 (its own expression sends it to the
fallback), a SIDE_LABEL that is not a glaeda-side-* label (a fork, owned pools
off, the variable unset), or runners that cannot be read.

Outputs, each job key delimited by spaces with one at each end so a runs-on's
contains(' <key> ') matches whole keys only:
- `owned_jobs`: the jobs an idle owned runner takes;
- `fallback_jobs`: the jobs that take their fallback; the runs-on reads this,
  so an empty value (no decision, or this job failed) keeps the owned label;
- `watch`: "false" when every job took its fallback, so the run uploads no
  owned-pool-watch marker; "true" otherwise.
"""
from __future__ import annotations

import importlib.util
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


def decide(env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None,
           ) -> tuple[tuple[str, ...], tuple[str, ...], str]:
    """(owned jobs, fallback jobs, why); ((), (), why) decides nothing and keeps today's route."""
    label = (env.get("SIDE_LABEL") or "").strip()
    jobs = tuple((env.get("JOBS") or "").split())
    attempt = (env.get("GITHUB_RUN_ATTEMPT") or "").strip()
    if attempt not in ("", "1"):
        return (), (), f"attempt {attempt} keeps its own route"
    if not label.startswith(pool.SIDE_PREFIX) or not pool.persistent(label):
        return (), (), f"`{label or 'no label'}` is not an owned side label"
    if runners is None:
        return (), (), f"owned runners could not be read live; the jobs keep `{label}`"
    owned = pool.idle_placement(runners, label, jobs)
    fallback = jobs[len(owned):]
    if not owned:
        return owned, fallback, f"no idle `{label}` runner now; every job takes its fallback"
    return owned, fallback, (f"{len(owned)} idle `{label}` runner(s) now take {', '.join(owned)}"
                             + (f"; {', '.join(fallback)} take their fallback" if fallback else ""))


def delimited(jobs: Sequence[str]) -> str:
    return f" {' '.join(jobs)} " if jobs else ""


def main(env: Mapping[str, str] = os.environ) -> int:
    runners = None
    token, repo = env.get("ROUTE_TOKEN", ""), env.get("GITHUB_REPOSITORY", "")
    if token and repo:
        try:
            runners = pool.GitHub(token, repo).runners()
        except Exception as error:  # noqa: BLE001 - fail open: keep today's route
            print(f"::warning title=side-lane placement::could not list runners ({error})")
    owned, fallback, why = decide(env, runners)
    print(f"side-lane placement: {why}")
    watch = "false" if fallback and not owned else "true"
    output = env.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"owned_jobs={delimited(owned)}\nfallback_jobs={delimited(fallback)}\nwatch={watch}\n")
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"### macOS placement\n\n{why}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
