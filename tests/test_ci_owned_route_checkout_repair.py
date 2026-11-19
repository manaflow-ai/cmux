#!/usr/bin/env python3
"""Every checkout of a Linux job that repairs a reused workspace repairs each of its checkouts.

The GCP build-lane runners (cmux-gcp-lane-build-x64) are persistent: jobs share one
_work/cmux/cmux. After an earlier job's sparse checkout, actions/checkout's full checkout
there stopped at "not uptodate; will not remove from working tree" with HEAD at the right
commit and tracked files missing: proof run 44398113924's `publish to R2` failed on
scripts/ci/cmux-machine-linux-bytes.sh (No such file or directory). On 2026-11-18 the
NEXT nightly path moved onto that lane (Blacksmith's vCPU cap held its tree jobs for hours),
so every checkout there must write HEAD's files again before it runs a script.

Since cmuxterm-hq#14156 ("capacity comes to the job") those jobs no longer name the GCP lane
or a placed `linux_runner`: every own-branch Linux job says the one label cmux-linux. The
repair stays on the jobs that took the persistent lane, so a host the provider reuses is still
safe. This fails when such a job (on cmux-linux, with the repair) has a checkout not followed
by the repair step, or when those jobs leave cmux-linux or lose the repair altogether.
"""

from __future__ import annotations

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
REPAIR = "Repair a reused self-hosted checkout"
LINUX = "'cmux-linux'"
FILES = ("cmux-tui-artifacts.yml", "cmux-tui-build-package.yml", "cmux-tui-tree-request.yml", "cloud-vm-image-roll.yml")


def owned_jobs(workflow: dict) -> dict[str, dict]:
    """Jobs on the one Linux label that carry the reused-workspace repair."""
    jobs = {}
    for name, job in workflow["jobs"].items():
        runs_on = str(job.get("runs-on", ""))
        steps = job.get("steps") or []
        has_repair = any(s.get("name") == REPAIR or "git reset -q --hard HEAD" in str(s.get("run", ""))
                         for s in steps)
        if LINUX in runs_on and has_repair:
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
        self.assertGreaterEqual(seen, 6, "the repaired Linux jobs left cmux-linux; this test checks nothing")
        self.assertEqual(missing, [], "checkouts on cmux-linux with no reused-workspace repair")

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
