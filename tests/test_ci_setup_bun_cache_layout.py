"""A setup-bun step on a route that can reach an owned runner skips the Bun cache off the Blacksmith layout.

actions/cache stores ~/.bun/bin/bun relative to the workspace. Saved on Blacksmith (workspace
/home/runner/work/cmux/cmux) it is ../../../.bun; restored on an owned GCP lane (workspace
/home/runner/actions-runner/_work/cmux/cmux) it lands in /home/runner/actions-runner/.bun, and setup-bun
then fails "Unable to locate executable file: /home/runner/.bun/bin/bun" (2026-11-20, cmux-next guards
runs 44681141685 and 44680147246, "cmux-next CI guard group"). Such a step downloads Bun instead.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
OWNED_ROUTE = re.compile(r"LINUX_RUNNER|RUNNER_POOLS|cmux-gcp|cmux-fleet|CI_TRUSTED_RUNNER|linux_runner")
NO_CACHE = "${{ !startsWith(github.workspace, '/home/runner/work/') }}"


def setup_bun_steps():
    for path in sorted((ROOT / ".github/workflows").glob("*.yml")):
        data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for job_name, job in (data.get("jobs") or {}).items():
            if not OWNED_ROUTE.search(str(job.get("runs-on", ""))):
                continue
            for index, step in enumerate(job.get("steps") or []):
                if "oven-sh/setup-bun" in str(step.get("uses", "")):
                    yield f"{path.name}:{job_name}:{index}", step


class SetupBunCacheLayout(unittest.TestCase):
    def test_every_owned_route_setup_bun_skips_a_foreign_layout_cache(self) -> None:
        steps = list(setup_bun_steps())
        self.assertTrue(steps)
        # `true` (no cache anywhere, billing.yml) is stricter and also fine.
        wrong = [where for where, step in steps
                 if str((step.get("with") or {}).get("no-cache")) not in (NO_CACHE, "True", "true")]
        self.assertEqual(wrong, [], f"set `no-cache: {NO_CACHE}` on these setup-bun steps")


if __name__ == "__main__":
    unittest.main()
