#!/usr/bin/env python3
"""scripts/ci/shed_superseded_runs.py keeps base push runs whose queued jobs must keep their place (no network).

2026-11-23 08:54Z: a sweep cancelled three cmux-next base autofix carriers (runs 45137487300, 45139343522,
45141537736) as superseded-base while their Mac exports job waited on glaeda-side-std-xcode-26.6. Newer runs defer
their exports to a queued carrier, so none regenerated them and feat-cmux-next's settings export stayed stale.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/shed_superseded_runs.py"
if str(SCRIPT.parent) not in sys.path:
    sys.path.insert(0, str(SCRIPT.parent))
import shed_superseded_runs as shed  # noqa: E402

REPO = "manaflow-ai/cmux"
TIPS = {"feat-cmux-next": "b" * 40}


def base_run(name: str, path: str) -> dict:
    return {
        "id": 45139343522, "status": "in_progress", "run_attempt": 1, "event": "push",
        "head_branch": "feat-cmux-next", "head_sha": "a" * 40, "head_repository": {"full_name": REPO},
        "name": name, "path": path,
    }


# Every started job finished; the Mac exports job waits in its label's queue with no runner.
WAITING_MAC = [
    {"status": "completed", "conclusion": "success"},
    {"status": "queued", "runner_id": None, "runner_name": None, "steps": []},
]


class BaseKeepTests(unittest.TestCase):
    def test_base_autofix_carrier_with_queued_mac_job_is_kept(self):
        run = base_run("cmux-next base autofix", ".github/workflows/cmux-next-base-autofix.yml")
        self.assertEqual(shed.verdict(run, REPO, TIPS, {run["id"]: WAITING_MAC}), "keep:publishes-per-commit")

    def test_other_superseded_base_push_run_is_still_shed(self):
        run = base_run("cmux-next", ".github/workflows/cmux-next.yml")
        self.assertEqual(shed.verdict(run, REPO, TIPS, {run["id"]: WAITING_MAC}), "superseded-base")


if __name__ == "__main__":
    unittest.main()
