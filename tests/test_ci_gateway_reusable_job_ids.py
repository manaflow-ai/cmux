#!/usr/bin/env python3
"""A gateway-Mac job inside a reusable workflow has a job id ending in -fleet.

The glaeda gateway runner's job-started hook accepts only thin cmux-ci client jobs. It names a job by its
calling workflow file plus its job id, and it takes any job id ending in -fleet. A job that runs directly
from its own workflow file is named by that file (cmux-next-perf-bench.yml bench, ...), which is on the
hook's allowlist. A job moved into a reusable workflow (on: workflow_call) is named by its caller instead.

2026-11-25 (cmuxterm-hq#26191): #55354 moved the fast tier's Swift job and the tip test-compile job into
cmux-next-post-merge.yml as reusable workflows. The hook saw "cmux-next-post-merge.yml swift" and
"cmux-next-post-merge.yml compile", refused both on every batch, and "fast tier (Swift entries, build fleet)"
and "tip test-compile" stayed red on feat-cmux-next until #56548 renamed the ids to swift-fleet and
compile-fleet. Before #56548 this test fails with those 2 jobs; after it, 0.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

WORKFLOWS = Path(__file__).resolve().parents[1] / ".github/workflows"
# The literal label, or a repository variable that names it (vars.CI_COMPILE_CHECK_GATEWAY before cmux#55571 froze it).
GATEWAY = re.compile(r"glaeda-gateway|vars\.\w*GATEWAY\b")
SUFFIX = "-fleet"


def _triggers(doc: dict) -> object:
    # PyYAML reads the bare key `on` as the boolean True.
    return doc.get(True, doc.get("on")) or {}


def refused_gateway_jobs(root: Path = WORKFLOWS) -> list[str]:
    refused = []
    for path in sorted(root.glob("*.yml")):
        doc = yaml.safe_load(path.read_text()) or {}
        triggers = _triggers(doc)
        if not (isinstance(triggers, dict) and "workflow_call" in triggers):
            continue
        for job_id, job in (doc.get("jobs") or {}).items():
            if GATEWAY.search(str((job or {}).get("runs-on", ""))) and not job_id.endswith(SUFFIX):
                refused.append(f"{path.name} {job_id}")
    return refused


class GatewayReusableJobIds(unittest.TestCase):
    def test_gateway_jobs_in_reusable_workflows_end_in_fleet(self) -> None:
        self.assertEqual(
            refused_gateway_jobs(),
            [],
            "the gateway hook refuses these when a caller runs them; rename each job id to end in -fleet",
        )

    def test_the_check_sees_the_two_jobs_hq_26191_broke(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, job_id in (("fast-tier.yml", "swift"), ("tip.yml", "compile"), ("ok.yml", "swift-fleet")):
                (root / name).write_text(
                    "on:\n  workflow_call:\njobs:\n"
                    f"  {job_id}:\n    runs-on: ${{{{ 'glaeda-gateway-xcode-26.6' }}}}\n    steps: []\n"
                )
            (root / "var.yml").write_text(
                "on:\n  workflow_call:\njobs:\n  compile:\n    runs-on: ${{ vars.CI_TIP_TEST_COMPILE_GATEWAY }}\n    steps: []\n"
            )
            (root / "direct.yml").write_text(
                "on:\n  workflow_dispatch:\njobs:\n  bench:\n    runs-on: glaeda-gateway-xcode-26.6\n    steps: []\n"
            )
            self.assertEqual(refused_gateway_jobs(root), ["fast-tier.yml swift", "tip.yml compile", "var.yml compile"])


if __name__ == "__main__":
    unittest.main()
