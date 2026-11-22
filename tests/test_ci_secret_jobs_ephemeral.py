"""A secret-bearing job that routes through RUNNER_POOLS or CI_TRUSTED_RUNNER can only land on a one-job machine.

Leo, 2026-11-19, on Blacksmith: "stop ... relying on it". linux_4, the pool secret-bearing and write-token jobs read,
now leads with an owned GCP label (cmux-gcp-secret-jit-x64) instead of a Blacksmith size. That label is ephemeral (a
VM booted per queued job and deleted after it); the owned GCP pool label (cmux-fleet-linux-x64) is not: persistent
runners carry it, and a job there leaves its secrets on a machine the next job reuses.

For every main workflow job that uses a secret other than GITHUB_TOKEN, or is marked `# ephemeral-required`, and whose
runs-on reads a RUNNER_POOLS pool or CI_TRUSTED_RUNNER, this finds every label the expression can produce (every member
of a pool it reads, the list of a bounded `contains(...)` selector, every literal) and fails on one that is not a
Blacksmith size, a named owned one-job label, a one-job GCP JIT label or GitHub-hosted.
"""
from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import runner_pools  # noqa: E402

WORKFLOWS = ROOT / ".github" / "workflows"
POOL = r"fromJSON\(vars\.RUNNER_POOLS(?: \|\| '\{\}')?\)\.([a-z0-9_]+)"
VARIABLE = r"vars\.([A-Z0-9_]+)"
BOUNDED = re.compile(r"contains\(fromJSON\('(\[[^']*\])'\), (" + POOL + "|" + VARIABLE + r")\) && \2")
# The one-job GCP labels (cmuxterm-hq runner_pool.py JIT_ONLY_LABELS): no persistent runner carries them.
GCP_JIT = re.compile(r"^cmux-gcp-[a-z0-9-]+-jit-x64$")
GITHUB_HOSTED = re.compile(r"^(?:ubuntu|macos|windows)-[a-z0-9.-]+$")
SECRET = re.compile(r"secrets\.([A-Za-z0-9_]+)")


def one_job(label: str) -> bool:
    """A label only fresh machines take: a Blacksmith size, a named owned one-job label, a GCP JIT label, hosted."""
    return bool(runner_pools.EPHEMERAL.match(label) or runner_pools.owned_ephemeral(label) or GCP_JIT.match(label)
                or GITHUB_HOSTED.match(label))


def reachable(expression: str, pools: dict) -> tuple[set[str], set[str]]:
    """(labels the runs-on expression can produce, variables it can produce as its label unbounded).

    A variable compared (`vars.X != '1'`) or tested (`vars.X && ...`) is a condition, not a label."""
    labels: set[str] = set()
    for match in BOUNDED.finditer(expression):
        labels |= set(json.loads(match.group(1)))
    rest = BOUNDED.sub("BOUNDED", expression)
    rest = re.sub(r"startsWith\([^)]*\)", "X", rest)
    rest = re.sub(r"fromJSON\('[^']*'\)", "X", rest)
    for match in re.finditer(POOL, rest):
        labels |= set(runner_pools.members(pools[match.group(1)]))
    rest = re.sub(POOL, "POOL", rest)
    rest = re.sub(VARIABLE + r" [=!]= '[^']*'", "X", rest)
    unbounded = {f"vars.{name}" for name in re.findall(VARIABLE + r"(?! &&)", rest)}
    rest = re.sub(r"[=!]= '[^']*'", "X", rest)
    labels |= set(re.findall(r"'([^']+)'", rest))
    return labels, unbounded


def routed_secret_jobs() -> list[tuple[str, str, str]]:
    """(workflow, job, runs-on) for each secret-bearing job routed by RUNNER_POOLS or CI_TRUSTED_RUNNER."""
    found = []
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        text = path.read_text(encoding="utf-8")
        document = yaml.safe_load(text) or {}
        for name, job in (document.get("jobs") or {}).items():
            if not isinstance(job, dict) or "runs-on" not in job:
                continue
            runs_on = str(job["runs-on"])
            if "RUNNER_POOLS" not in runs_on and "CI_TRUSTED_RUNNER" not in runs_on:
                continue
            secrets = set(SECRET.findall(yaml.safe_dump(job))) - {"GITHUB_TOKEN"}
            marked = any("# ephemeral-required" in line and line.strip().startswith("runs-on:")
                         and runs_on.split(" # ", 1)[0].strip() in line for line in text.splitlines())
            if secrets or marked:
                found.append((path.name, name, runs_on))
    return found


def problems(jobs: list[tuple[str, str, str]], pools: dict) -> list[str]:
    found = []
    for workflow, job, runs_on in jobs:
        labels, unbounded = reachable(runs_on, pools)
        reused = sorted(label for label in labels if not one_job(label))
        if reused:
            found.append(f"{workflow} {job}: can land on {', '.join(reused)}, a machine a later job reuses")
        for variable in sorted(unbounded):
            found.append(f"{workflow} {job}: can land wherever {variable} points; bound it with contains([...])")
    return found


class SecretJobsStayEphemeral(unittest.TestCase):
    def test_the_scan_is_not_vacuous(self) -> None:
        self.assertGreater(len(routed_secret_jobs()), 0)

    def test_no_secret_bearing_job_can_land_on_a_reused_machine(self) -> None:
        self.assertEqual(problems(routed_secret_jobs(), runner_pools.load_pools()), [])

    def test_a_secret_job_on_the_persistent_gcp_pool_fails(self) -> None:
        pools = runner_pools.load_pools()
        for runs_on in ("${{ fromJSON(vars.RUNNER_POOLS).linux }}",
                        "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-fleet-linux-x64' }}",
                        "${{ vars.CI_TRUSTED_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}"):
            with self.subTest(runs_on=runs_on):
                self.assertNotEqual(problems([("x.yml", "job", runs_on)], pools), [])
        bad = json.loads(json.dumps(pools))
        bad["linux_4"]["members"] = ["cmux-fleet-linux-x64", *bad["linux_4"]["members"][1:]]
        self.assertNotEqual(problems([("x.yml", "job", "${{ fromJSON(vars.RUNNER_POOLS).linux_4 }}")], bad), [])

    def test_linux_4_and_the_bounded_trusted_selector_pass(self) -> None:
        pools = runner_pools.load_pools()
        for runs_on in ("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || "
                        "fromJSON(vars.RUNNER_POOLS).linux_4 }}",
                        "${{ contains(fromJSON('[\"ubuntu-24.04\",\"blacksmith-4vcpu-ubuntu-2404\"]'), "
                        "vars.CI_TRUSTED_RUNNER) && vars.CI_TRUSTED_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}"):
            with self.subTest(runs_on=runs_on):
                self.assertEqual(problems([("x.yml", "job", runs_on)], pools), [])


if __name__ == "__main__":
    unittest.main()
