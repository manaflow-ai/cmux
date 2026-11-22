#!/usr/bin/env python3
"""Every cmux workflow job has a timeout, and none runs after a cancel unless .github/workflow-job-bounds.json says why.

A job with no `timeout-minutes` that hangs runs for GitHub's 6 h default. A job-level `if:` with `always()` and no
`!cancelled()` still queues when its run is cancelled; on a label with no free runner it waits there, and
`timeout-minutes` does not count queue time, so it holds the run and its concurrency group (the 453-run incident of
2026-11-18; cmuxterm-hq docs/investigations/2026-11-18-boneheaded-designs.md section 11). `!cancelled()` still runs
a summary after a failed, skipped or queue-cancelled need, and skips it only when the run itself was cancelled.

scripts/ci/workflow_job_bounds.py is byte-identical to manaflow-ai/cmuxterm-hq tests/workflow_job_bounds.py and
teamleaderleo/glaeda scripts/workflow_job_bounds.py. The pre-push hook refuses a push that adds either problem
(scripts/cmux-next/prepush-gate.py JOB_BOUNDS_CHECK). Manual lane: kept manual under the 2026-10-23 no-new-CI rule
(lifted 2026-11-18).
"""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
ALLOW = ROOT / ".github" / "workflow-job-bounds.json"
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
from workflow_job_bounds import findings  # noqa: E402


def always_on_cancel() -> dict[str, str]:
    return json.loads(ALLOW.read_text(encoding="utf-8"))["always_on_cancel"]


class WorkflowJobBounds(unittest.TestCase):
    def test_every_job_is_bounded(self) -> None:
        self.assertTrue(list(WORKFLOWS.glob("*.yml")), "no workflow files found, so nothing is checked")
        self.assertEqual(findings(WORKFLOWS, always_on_cancel()), [])

    def test_every_listed_job_says_why(self) -> None:
        for where, why in always_on_cancel().items():
            with self.subTest(job=where):
                self.assertGreater(len(why.split()), 5, "a listed job names why it must run on a cancel")

    def test_the_check_fails_on_a_missing_timeout_and_an_unlisted_always(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "w.yml").write_text(
                "on: push\n"
                "jobs:\n"
                "  build:\n"
                "    runs-on: ubuntu-24.04\n"
                "    steps:\n"
                "      - run: echo timeout-minutes: 5\n"
                "  report:\n"
                "    needs: build\n"
                "    if: ${{ always() && needs.build.result == 'failure' }}\n"
                "    runs-on: ubuntu-24.04\n"
                "    timeout-minutes: 5\n"
                "    steps:\n"
                "      - run: echo\n"
                "  guarded:\n"
                "    needs: build\n"
                "    if: ${{ always() && !cancelled() }}\n"
                "    runs-on: ubuntu-24.04\n"
                "    timeout-minutes: 5\n"
                "    steps:\n"
                "      - run: echo\n"
                "  call:\n"
                "    uses: ./.github/workflows/other.yml\n", encoding="utf-8")
            found = findings(Path(tmp), {"w.yml:gone": "stale"})
        self.assertEqual(len(found), 3, found)
        self.assertTrue(found[0].startswith("w.yml:build: no timeout-minutes"), found)
        self.assertTrue(found[1].startswith("w.yml:report: if: ${{ always() &&"), found)
        self.assertTrue(found[2].startswith("w.yml:gone: listed"), found)


if __name__ == "__main__":
    unittest.main(verbosity=2)
