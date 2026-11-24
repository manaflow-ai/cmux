#!/usr/bin/env python3
"""A job that must run on a one-job machine reads only an ephemeral_only runner pool.

A persistent runner keeps its disk between jobs, so a job that holds a write token, is marked
`ephemeral-required`, or runs a fork pull request's code must never land on one. Every persistent
cmux-runner-pool- runner carries the owned GCP label (cmux-fleet-linux-x64), and main's
runner_pools.py may put that label first in any pool not marked `ephemeral_only` (#48881, review
6004679006). So these jobs read a pool marked `ephemeral_only` in .github/runners.json, whose members
only one-job machines serve.

Three checks:
- a job whose effective permissions grant any write, or whose runs-on line says `ephemeral-required`,
  reads only ephemeral_only pools;
- a runs-on line a fork pull request reaches reads a non-ephemeral pool only after a fork branch has
  already sent forks to a literal label (the same reading as tests/test_ci_fork_runner_routing.py);
- an ephemeral_only pool names no owned or persistent label.
"""

from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
import test_ci_fork_runner_routing as fork  # noqa: E402
import workflow_jobs  # noqa: E402

WORKFLOWS = ROOT / ".github" / "workflows"
POOL_READ = re.compile(r"fromJSON\(vars\.RUNNER_POOLS\)\.([a-z][a-z0-9_]*)")
JOB_HEADER = re.compile(r"^  ([A-Za-z0-9_-]+):\s*(?:#.*)?$")
RUNS_ON_LINE = re.compile(r"^    runs-on:(.*)$")
# Labels a persistent or owned runner carries: the owned GCP fleet, glaeda's hosts, the JIT pools'
# labels (persistent runners carry them too, decisions/junctions.md) and the shared Linux label.
# Write-token pool readers left where they are, each with why.
NOT_YET_MOVED: dict = {}
OWNED_LABEL = re.compile(r"^(?:cmux-fleet-|cmux-gcp-|cmux-linux$|cmux-runner-pool-|glaeda-|self-hosted$)")


def pools() -> dict[str, dict]:
    declared = json.loads((ROOT / ".github" / "runners.json").read_text(encoding="utf-8"))["pools"]
    return {name: spec for name, spec in declared.items() if not name.startswith("$")}


def ephemeral_pools() -> set[str]:
    return {name for name, spec in pools().items() if spec.get("ephemeral_only") is True}


def grants_write(permissions) -> bool:
    if isinstance(permissions, str):
        return permissions.strip() == "write-all"
    if isinstance(permissions, dict):
        return any(str(value).strip() == "write" for value in permissions.values())
    return False


def runs_on_comments(text: str) -> dict[str, str]:
    """Each job's runs-on source line (with its trailing comment), by job id."""
    found: dict[str, str] = {}
    job = None
    in_jobs = False
    for line in text.splitlines():
        if line.startswith("jobs:"):
            in_jobs = True
            continue
        if in_jobs and line and not line.startswith(" ") and not line.startswith("#"):
            in_jobs = False
        if not in_jobs:
            continue
        header = JOB_HEADER.match(line)
        if header:
            job = header.group(1)
            continue
        runs_on = RUNS_ON_LINE.match(line)
        if job and runs_on and job not in found:
            found[job] = runs_on.group(1)
    return found


def protected_job_reads() -> list[tuple[str, str, str, list[str]]]:
    """(workflow, job, why, pools read) for every write-token or ephemeral-required job that reads a pool."""
    out = []
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        text = path.read_text(encoding="utf-8")
        if "RUNNER_POOLS" not in text:
            continue
        document = workflow_jobs.document(path)
        top = document.get("permissions")
        lines = runs_on_comments(text)
        for job_id, job in workflow_jobs.jobs(document).items():
            runs_on = job.get("runs-on")
            read = POOL_READ.findall(runs_on if isinstance(runs_on, str) else json.dumps(runs_on))
            if not read:
                continue
            why = []
            if "ephemeral-required" in lines.get(job_id, ""):
                why.append("ephemeral-required")
            if grants_write(job["permissions"] if "permissions" in job else top):
                why.append("write token")
            if why:
                out.append((path.name, job_id, " and ".join(why), sorted(set(read))))
    return out


def _pools_in(node) -> list[str]:
    if not isinstance(node, tuple):
        return []
    if node and node[0] == "pool":
        return [node[1]]
    found: list[str] = []
    for child in node[1:]:
        if isinstance(child, tuple):
            found += _pools_in(child)
        elif isinstance(child, list):
            found += [name for item in child for name in _pools_in(item)]
    return found


def _bare_fork_branch(node) -> bool:
    """`head.repo.full_name != github.repository && '<label>'` in a pull_request-only workflow (pr-router.yml)."""
    return (isinstance(node, tuple) and node[0] == "and" and len(node[1]) == 2
            and node[1][0] == ("cmp", "!=", ("ref", "github.event.pull_request.head.repo.full_name"),
                               ("ref", "github.repository"))
            and isinstance(node[1][1], tuple) and node[1][1][0] == "literal")


def fork_reachable_pool_errors(expression: str, ephemeral: set[str]) -> list[str]:
    """Pools that aren't ephemeral_only and that a fork pull request can reach before any fork branch."""
    node = fork.parse_expression(expression)
    branches = node[1] if node[0] == "or" else [node]
    for branch in branches:
        if fork._is_fork_pull_request_branch(branch) or _bare_fork_branch(branch):
            return []
        bad = [name for name in _pools_in(branch) if name not in ephemeral]
        if bad:
            return bad
    return []


def fork_reachable_reads() -> list[tuple[str, int, str]]:
    out = []
    for path in fork.fork_exercised_workflows():
        text = path.read_text(encoding="utf-8")
        excluded = fork.fork_excluded_job_lines(text)
        for number, line in enumerate(text.splitlines(), 1):
            if (number in excluded or line.lstrip().startswith("#") or "runs-on:" not in line
                    or "RUNNER_POOLS" not in line):
                continue
            out.append((path.name, number, line))
    return out


class EphemeralPoolReaders(unittest.TestCase):
    def test_there_is_an_ephemeral_only_pool(self) -> None:
        self.assertIn("linux_4", ephemeral_pools(), "the write-token and fork readers' pool is linux_4")

    def test_ephemeral_only_pools_name_no_owned_label(self) -> None:
        for name in sorted(ephemeral_pools()):
            for member in pools()[name]["members"]:
                with self.subTest(pool=name, member=member):
                    self.assertIsNone(OWNED_LABEL.match(member),
                                      f"{name} is ephemeral_only but {member} is served by a persistent runner")

    def test_write_token_and_ephemeral_required_jobs_read_ephemeral_pools(self) -> None:
        reads = protected_job_reads()
        self.assertGreater(len(reads), 10, "the scan found no write-token pool readers: it is reading nothing")
        ephemeral = ephemeral_pools()
        for workflow, job, why, read in reads:
            if (workflow, job) in NOT_YET_MOVED:
                continue
            with self.subTest(workflow=workflow, job=job):
                self.assertEqual([name for name in read if name not in ephemeral], [],
                                 f"{workflow}:{job} holds a {why} and reads a pool that isn't ephemeral_only; "
                                 "read fromJSON(vars.RUNNER_POOLS).linux_4")

    def test_fork_pull_requests_reach_only_ephemeral_pools(self) -> None:
        lines = fork_reachable_reads()
        self.assertGreater(len(lines), 10, "the scan found no fork-reachable pool reads: it is reading nothing")
        ephemeral = ephemeral_pools()
        for workflow, number, line in lines:
            unwrapped = fork.FORK_WRAPPED_POOL_READ.sub(lambda m: m.group(1) or m.group(2), fork.FORK_WRAPPED_GUARDED_POOL_READ.sub(r"\1", line))
            for expression in fork.EXPRESSION.findall(unwrapped):
                with self.subTest(workflow=workflow, line=number):
                    self.assertEqual(fork_reachable_pool_errors(expression, ephemeral), [],
                                     f"{workflow}:{number}: a fork pull request reaches a pool that isn't "
                                     "ephemeral_only; send forks to a literal Blacksmith label first")

    def test_the_fork_check_refuses_an_unguarded_shared_pool(self) -> None:
        self.assertEqual(fork_reachable_pool_errors("fromJSON(vars.RUNNER_POOLS).linux_16", {"linux_4"}),
                         ["linux_16"])
        self.assertEqual(fork_reachable_pool_errors(
            "vars.CI_CLOUD_OVERFLOW_SAVED && fromJSON(vars.RUNNER_POOLS).linux_16 || fromJSON(vars.RUNNER_POOLS).linux_4",
            {"linux_4"}), ["linux_16"])
        self.assertEqual(fork_reachable_pool_errors("fromJSON(vars.RUNNER_POOLS).linux_4", {"linux_4"}), [])

    def test_the_bare_fork_branch_counts(self) -> None:
        self.assertEqual(fork_reachable_pool_errors(
            "github.event.pull_request.head.repo.full_name != github.repository && 'blacksmith-2vcpu-ubuntu-2404'"
            " || fromJSON(vars.RUNNER_POOLS).linux", {"linux_4"}), [])

    def test_write_detection(self) -> None:
        self.assertTrue(grants_write({"contents": "write"}))
        self.assertTrue(grants_write("write-all"))
        self.assertFalse(grants_write({"contents": "read"}))
        self.assertFalse(grants_write(None))


if __name__ == "__main__":
    unittest.main()
