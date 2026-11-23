#!/usr/bin/env python3
"""A required check, and every job it needs, runs on the size it was measured at, not the outage upsize.

feat-cmux-next's ruleset requires the contexts in REQUIRED (read from
GET /repos/manaflow-ai/cmux/rules/branches/feat-cmux-next on 2026-11-18 00:39Z). On 2026-11-17 the
overflow switch's CI_CLOUD_OVERFLOW_SAVED record stayed set from 19:48Z past 00:48Z (cmux#45818 fixes
that latch), and about 216 runs-on read `vars.CI_CLOUD_OVERFLOW_SAVED && <bigger pool>`. The required
`clippy (changed cmux-tui packages)`, measured at 8 vCPU, took RUNNER_POOLS.linux_16, whose live member was
then 32 vCPU: of the Linux jobs created 00:00-00:48Z, 32 vCPU started 1 of 282 while 8 vCPU started 7 of 33
and 4 vCPU 47 of 209. Blacksmith caps us on vCPUs at once, so the upsize sends a required check into exactly
the queue that starts least, behind every advisory job taking the same upsize.

A required job reads its measured pool, `fromJSON(vars.RUNNER_POOLS).<pool>`, and nothing that moves it with
the advisory crowd: no `vars.CI_CLOUD_OVERFLOW_SAVED` arm, no shared `vars.LINUX_RUNNER`, no
`github.run_attempt == 1 && 'ubuntu-24.04'` hosted-first arm (GitHub-hosted Ubuntu sat about 2 h behind on
2026-11-17), and no pool above 8 vCPU without a linux_sizes `why_32`. A stalled pool member still moves:
scripts/ci/runner_pools.py moves the pool, and the job follows with no YAML edit. The same holds for every job
in its `needs` chain, since a required job cannot start before them.

When the ruleset gains or loses a context, update REQUIRED (the live call in
.github/workflows/required-checks-drift.yml reconciles main's mirror; this tuple is feat-cmux-next's).
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

REQUIRED = (
    "clippy (changed cmux-tui packages)",
    "React Doctor (changed React projects)",
)
# What moves a job with the advisory crowd (module docstring).
SHARED_ROUTES = {
    "the overflow upsize": re.compile(r"vars\.CI_CLOUD_OVERFLOW_SAVED"),
    "the shared LINUX_RUNNER": re.compile(r"vars\.LINUX_RUNNER(?!\w)"),
    "the hosted-first arm": re.compile(r"github\.run_attempt\s*==\s*1\s*&&\s*'ubuntu-"),
}
LARGE_POOL = re.compile(r"fromJSON\(vars\.RUNNER_POOLS\)\.linux_(16|32)\b")
# The fork branches name a literal (a fork's run gets no variables); only the trusted tail is a route.
FORK_BRANCHES = (
    re.compile(r"github\.repository_owner != 'manaflow-ai' && '[^']+' \|\| "),
    re.compile(r"github\.event_name == 'pull_request' && github\.event\.pull_request\.head\.repo\.full_name"
               r" != github\.repository && '[^']+' \|\| "),
)


def workflows() -> dict[str, dict]:
    found = {}
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
        if isinstance(document, dict):
            found[path.name] = document
    return found


def owners(documents: dict[str, dict], context: str) -> list[tuple[str, str]]:
    """The (workflow, job id) pairs whose job name is the context (a pull request runs them)."""
    out = []
    for workflow, document in documents.items():
        triggers = document.get("on", document.get(True)) or {}
        if "pull_request" not in (triggers if isinstance(triggers, (dict, list)) else [triggers]):
            continue
        for job_id, job in (document.get("jobs") or {}).items():
            if isinstance(job, dict) and job.get("name") == context:
                out.append((workflow, job_id))
    return out


def chain(document: dict, job_id: str) -> list[str]:
    """The job and every job it needs, transitively, in first-seen order."""
    jobs = document.get("jobs") or {}
    seen: list[str] = []
    todo = [job_id]
    while todo:
        name = todo.pop(0)
        if name in seen or name not in jobs:
            continue
        seen.append(name)
        needs = jobs[name].get("needs") or []
        todo.extend([needs] if isinstance(needs, str) else needs)
    return seen


def trusted_route(runs_on: object) -> str:
    text = json.dumps(runs_on) if not isinstance(runs_on, str) else runs_on
    for branch in FORK_BRANCHES:
        text = branch.sub("", text)
    return text


def problems(documents: dict[str, dict]) -> list[str]:
    out = []
    for context in REQUIRED:
        found = owners(documents, context)
        if not found:
            out.append(f"{context!r}: no pull_request job has this name (REQUIRED drifted from the ruleset?)")
        for workflow, job_id in found:
            document = documents[workflow]
            for name in chain(document, job_id):
                route = trusted_route(document["jobs"][name].get("runs-on", ""))
                where = f"{workflow}#{name} (needed by {context!r})" if name != job_id else f"{workflow}#{name}"
                for why, pattern in SHARED_ROUTES.items():
                    if pattern.search(route):
                        out.append(f"{where}: runs-on reads {why}; read the job's measured pool only")
                if LARGE_POOL.search(route):
                    out.append(f"{where}: runs-on reads a 16 or 32 vCPU pool; a required job takes its measured size")
    return out


class RequiredChecksKeepTheirSize(unittest.TestCase):
    def test_required_jobs_and_their_needs_read_only_their_measured_pool(self) -> None:
        self.assertEqual(problems(workflows()), [])

    def test_the_checker_flags_each_shared_route(self) -> None:
        tail = "fromJSON(vars.RUNNER_POOLS).linux_8 }}"
        cases = {
            "the overflow upsize": "${{ vars.CI_CLOUD_OVERFLOW_SAVED && fromJSON(vars.RUNNER_POOLS).linux_16 || " + tail,
            "the shared LINUX_RUNNER": "${{ !startsWith(vars.LINUX_RUNNER, 'blacksmith-') && vars.LINUX_RUNNER || " + tail,
            "the hosted-first arm": "${{ github.run_attempt == 1 && 'ubuntu-24.04' || " + tail,
        }
        for why, runs_on in cases.items():
            with self.subTest(why=why):
                documents = {"w.yml": {"on": {"pull_request": None}, "jobs": {
                    "router": {"runs-on": runs_on},
                    "check": {"name": REQUIRED[0], "needs": "router", "runs-on": "${{ " + tail}}}}
                found = problems(documents)
                self.assertTrue(any("w.yml#router" in line and why in line for line in found), found)

    def test_the_fork_branches_are_not_routes(self) -> None:
        runs_on = ("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.event_name == "
                   "'pull_request' && github.event.pull_request.head.repo.full_name != github.repository && "
                   "'blacksmith-4vcpu-ubuntu-2404' || fromJSON(vars.RUNNER_POOLS).linux_8 }}")
        documents = {"w.yml": {"on": {"pull_request": None}, "jobs": {"check": {"name": REQUIRED[0], "runs-on": runs_on}}}}
        found = [line for line in problems(documents) if REQUIRED[0] in line and "no pull_request job" in line]
        self.assertEqual([line for line in problems(documents) if "w.yml" in line], [])
        self.assertEqual(found, [])


if __name__ == "__main__":
    unittest.main()
