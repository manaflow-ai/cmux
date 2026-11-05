#!/usr/bin/env python3
"""feat-cmux-next's copy of the runner pools equals main's, the copy scripts/ci/runner_pools.py reads.

main declares the pools (.github/runners.json `pools`) and its scheduled watch keeps RUNNER_POOLS on a live
member of each. feat-cmux-next's workflows read fromJSON(vars.RUNNER_POOLS).<pool>, and its tests resolve those
reads from the copy here (tests/runs_on_labels.py pool_members()). A pool added on main, or a member changed
there, is copied here in the same change. The comparison runs where origin/main is in the checkout (a full
clone, the fleet mirror); a shallow CI checkout skips it.
"""

from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from runs_on_labels import declared_pools  # noqa: E402


def main_pools() -> dict[str, list[str]] | None:
    shown = subprocess.run(["git", "-C", str(ROOT), "show", "origin/main:.github/runners.json"],
                           capture_output=True, text=True, check=False)
    if shown.returncode != 0:
        return None
    pools = json.loads(shown.stdout).get("pools")
    if pools is None:
        return None
    return {name: list(spec["members"]) for name, spec in pools.items() if not name.startswith("$")}


class PoolsCopy(unittest.TestCase):
    def test_every_pool_read_names_a_declared_pool(self) -> None:
        import re
        read = re.compile(r"fromJSON\(vars\.RUNNER_POOLS\)\.([a-z][a-z0-9_]*)")
        pools = declared_pools()
        for workflow in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
            for name in set(read.findall(workflow.read_text(encoding="utf-8"))):
                with self.subTest(workflow=workflow.name, pool=name):
                    self.assertIn(name, pools, "an undeclared pool reads as '' and its job queues forever")

    def test_the_copy_equals_mains_pools(self) -> None:
        upstream = main_pools()
        if upstream is None:
            self.skipTest("origin/main is not in this checkout, or declares no pools yet")
        copy = declared_pools()
        self.assertEqual(sorted(copy), sorted(upstream), "the copy declares a different set of pools than main")
        for name, members in upstream.items():
            with self.subTest(pool=name):
                self.assertEqual(copy.get(name), members)


if __name__ == "__main__":
    unittest.main()
