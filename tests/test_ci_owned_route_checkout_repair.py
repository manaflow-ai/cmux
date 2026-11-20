#!/usr/bin/env python3
"""Every checkout of a job that can take the owned GCP build lane repairs a reused workspace.

The GCP build-lane runners (cmux-gcp-lane-build-x64) are persistent: jobs share one
_work/cmux/cmux. After an earlier job's sparse checkout, actions/checkout's full checkout
there stopped at "not uptodate; will not remove from working tree" with HEAD at the right
commit and tracked files missing: proof run 44398113924's `publish to R2` failed on
scripts/ci/cmux-machine-linux-bytes.sh (No such file or directory). On 2026-11-18 the
NEXT nightly path moved onto that lane (Blacksmith's vCPU cap held its tree jobs for hours),
so every checkout there must write HEAD's files again before it runs a script.

This fails when a job that can be placed on that lane (its runs-on names the label, or a
placed `linux_runner`) has a checkout not followed by the repair step.
"""

from __future__ import annotations

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
REPAIR = "Repair a reused self-hosted checkout"
OWNED = "cmux-gcp-lane-build-x64"
FILES = ("cmux-tui-artifacts.yml", "cmux-tui-build-package.yml", "cmux-tui-tree-request.yml", "cloud-vm-image-roll.yml")


def owned_jobs(workflow: dict) -> dict[str, dict]:
    jobs = {}
    for name, job in workflow["jobs"].items():
        runs_on = str(job.get("runs-on", ""))
        if OWNED in runs_on or "linux_runner" in runs_on:
            jobs[name] = job
    return jobs


def repaired(steps: list[dict], index: int) -> bool:
    """The step after the checkout is the repair, or (the build legs) a step that runs it inline."""
    if index + 1 >= len(steps):
        return False
    after = steps[index + 1]
    if after.get("name") == REPAIR:
        return True
    run = str(after.get("run", ""))
    return "RUNNER_ENVIRONMENT" in run and "git reset -q --hard HEAD" in run


class OwnedRouteCheckoutRepair(unittest.TestCase):
    def test_every_owned_route_checkout_is_repaired(self) -> None:
        missing = []
        seen = 0
        for file in FILES:
            workflow = yaml.safe_load((WORKFLOWS / file).read_text())
            for name, job in owned_jobs(workflow).items():
                steps = job.get("steps") or []
                for index, step in enumerate(steps):
                    if str(step.get("uses", "")).startswith("actions/checkout@"):
                        seen += 1
                        if not repaired(steps, index):
                            missing.append(f"{file}:{name}")
        self.assertGreaterEqual(seen, 6, "the owned route lost its jobs; this test checks nothing")
        self.assertEqual(missing, [], "checkouts on the owned GCP lane with no reused-workspace repair")

    def test_a_full_checkout_leaves_sparse_mode(self) -> None:
        for file in FILES:
            workflow = yaml.safe_load((WORKFLOWS / file).read_text())
            for name, job in owned_jobs(workflow).items():
                steps = job.get("steps") or []
                for index, step in enumerate(steps):
                    if not str(step.get("uses", "")).startswith("actions/checkout@"):
                        continue
                    if steps[index + 1].get("name") != REPAIR:
                        continue
                    sparse = bool((step.get("with") or {}).get("sparse-checkout"))
                    run = steps[index + 1]["run"]
                    with self.subTest(job=f"{file}:{name}"):
                        # A sparse job keeps its sparse set; a full one must leave sparse mode first.
                        self.assertEqual("sparse-checkout disable" in run, not sparse)


if __name__ == "__main__":
    unittest.main()
