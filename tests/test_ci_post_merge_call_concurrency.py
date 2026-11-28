"""Every suite workflow cmux-next-post-merge calls keys its concurrency group by the caller's run.

Two calls of one suite at one commit (a confirm round's red-1 and red-2 runs, or a probe dispatched again) shared a
group keyed by commit and job, or by branch alone: GitHub evicted the pending one or cancelled the running one, the
judge read that as no verdict and dispatched it again. On 11-27 rust-workspaces' confirm round at bf6927f2f3 ran 11
times, 10 of them cancelled (cmux runs 45988834788...45989822489), and acpmux-protocol-ir's round at 569198fe37 ran 11
times, all cancelled (45997396504...).
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
CALLER = WORKFLOWS / "cmux-next-post-merge.yml"
KEY = "${{ inputs.sha && format('-call-{0}', github.run_id) || '' }}"


def called_workflows() -> list[str]:
    return sorted(set(re.findall(r"uses: \./\.github/workflows/([\w.-]+\.yml)", CALLER.read_text())))


class PostMergeCallConcurrencyTest(unittest.TestCase):
    def test_every_called_suite_with_a_group_keys_by_caller_run(self) -> None:
        checked = 0
        for name in called_workflows():
            doc = yaml.safe_load((WORKFLOWS / name).read_text())
            group = (doc.get("concurrency") or {}).get("group") if isinstance(doc.get("concurrency"), dict) else doc.get("concurrency")
            if not group:
                continue  # no workflow-level group: calls never collide
            checked += 1
            with self.subTest(workflow=name):
                self.assertIn(KEY, group)
        self.assertGreaterEqual(checked, 10)

    def test_caller_passes_sha_to_every_suite(self) -> None:
        # The key is on only when inputs.sha is set, so every call must pass it.
        doc = yaml.safe_load(CALLER.read_text())
        for job_name, job in doc["jobs"].items():
            if str(job.get("uses", "")).startswith("./.github/workflows/"):
                with self.subTest(job=job_name):
                    self.assertIn("sha", job.get("with") or {})


if __name__ == "__main__":
    unittest.main()
