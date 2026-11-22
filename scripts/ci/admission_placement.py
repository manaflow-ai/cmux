#!/usr/bin/env python3
"""Pin compile admission to an idle root runner on a mini running no root job.

pr_runner_pool.py places a run's jobs in `changes`, before admission
queues. A std mini has two root runners and a compile takes either free
root, so two compiles can share a mini while another mini's root runners sit
idle. ci-macos.yml's admission-placement job runs this just before
admission with `vars.CI_OWNED_SPREAD == '1'`, when the picker put admission
on a pool with a root count: on attempt 1, and on a re-run that runs it again
(a full re-run). It lists the runners through the org route App (as
late_placement.py does) and picks, in order:

- spread: an idle root runner on a mini none of whose root runners is busy
  (pr_runner_pool.spread_admission_runner()), a warm mini first;
- warm: an idle root runner warm for the run's merge base, then for its pull
  request (ADMISSION_WARM, the picker's `admission_warm` tiers), when every
  mini runs a root job;
- root: the root label alone.

On a re-run it first drops the minis that ran a job that failed in the
previous attempt (failed_members(): a failed job, or one whose runner lost
communication), read in one request, so a pin never names the mini that just
failed. An unreadable list drops none.

Output `runner` is admission's runs-on as a JSON array (`["<root label>",
"glaeda-runner-<name>"]`, or `["<root label>"]`), and `placement` says which
(spread, spread-warm, warm, root). When the runners cannot be read both are
empty, and admission keeps the picker's `admission_runner`. ci-macos.yml takes
the pin only in the attempt that made it (output `attempt`): a re-run of
failed jobs keeps this job's outputs from the attempt before.
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
from pathlib import Path
from typing import Any, Collection, Mapping, Sequence


def _picker():
    path = Path(__file__).with_name("pr_runner_pool.py")
    spec = importlib.util.spec_from_file_location("pr_runner_pool", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("pr_runner_pool", module)
    spec.loader.exec_module(module)
    return module


pool = _picker()


def warm_tiers(raw: str | None) -> list[list[str]]:
    """ADMISSION_WARM: a JSON array of tiers, each an array of runner names, best first.

    The picker's `admission_warm` (pr_runner_pool.warm_tiers()): runners warm
    for the merge base, then for this pull request. A flat array of names is
    one tier. Anything else names none.
    """
    try:
        data = json.loads((raw or "").strip() or "[]")
    except ValueError:
        return []
    if not isinstance(data, list):
        return []
    if all(isinstance(name, str) for name in data):
        data = [data] if data else []
    return [[name for name in tier if isinstance(name, str)] for tier in data if isinstance(tier, list)]


def failed_members(jobs: Sequence[Mapping[str, Any]]) -> set[str]:
    """The minis (pool.runner_member()) whose runner failed a job in `jobs`, one attempt's job listing.

    A runner that lost communication fails its job too, with its name kept."""
    return {member for job in jobs if isinstance(job, Mapping) and job.get("conclusion") == "failure"
            for member in [pool.runner_member(str(job.get("runner_name") or ""))] if member}


def decide(env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None,
           failed: Collection[str] = ()) -> tuple[str, str, str]:
    """(runs-on JSON, placement, why); ("", "", why) keeps the picker's choice. `failed` names minis to skip."""
    root = (env.get("ROOT_RUNNER") or "").strip()
    if not pool.persistent(root) or not root.startswith(pool.ROOT_PREFIX):
        return "", "", f"admission has no root label ({root or 'none'})"
    if runners is None:
        return "", "", "owned runners could not be read live"
    if failed:
        runners = [runner for runner in runners if pool.runner_member(str(runner.get("name") or "")) not in failed]
    tiers = warm_tiers(env.get("ADMISSION_WARM"))
    labels, hit = pool.spread_admission_runner(runners, root, tiers, seed=(env.get("GITHUB_RUN_ID") or "").strip())
    if labels:
        name = json.loads(labels)[1]
        return labels, "spread-warm" if hit else "spread", (
            f"`{name}` is idle on a mini with no root job running" + (", which is warm for this run" if hit else ""))
    name = pool.idle_warm_runner(runners, root, tiers)
    if name:
        return (pool.pinned_admission(root, name), "warm",
                f"every mini runs a root job; `{name}` is idle and warm for this run")
    return json.dumps([root]), "root", f"every mini runs a root job; admission takes `{root}`"


def main(env: Mapping[str, str] = os.environ) -> int:
    runners = None
    failed: set[str] = set()
    token, repo = env.get("ROUTE_TOKEN", ""), env.get("GITHUB_REPOSITORY", "")
    run_id, attempt = env.get("GITHUB_RUN_ID", ""), env.get("GITHUB_RUN_ATTEMPT", "")
    if token and repo:
        github = pool.GitHub(token, repo)
        try:
            runners = github.runners()
        except Exception as error:  # noqa: BLE001 - fail open: keep the picker's choice
            print(f"::warning title=admission placement::could not list runners ({error})")
        if runners is not None and run_id.isdigit() and attempt.isdigit() and int(attempt) > 1:
            try:
                jobs = github.get(f"/actions/runs/{run_id}/attempts/{int(attempt) - 1}/jobs"
                                  f"?per_page={pool.PAGE_SIZE}").get("jobs") or []
                failed = failed_members(jobs)
            except Exception as error:  # noqa: BLE001 - fail open: skip no mini
                print(f"::warning title=admission placement::could not read attempt {int(attempt) - 1} ({error})")
    labels, placement, why = decide(env, runners, failed)
    if failed:
        why += f" (skipped {', '.join(sorted(failed))}, which failed a job in attempt {int(attempt) - 1})"
    print(f"admission placement: {why}")
    output = env.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"runner={labels}\nplacement={placement}\nattempt={attempt}\n")
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"### Admission placement\n\n{placement or 'unchanged'}: {why}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
