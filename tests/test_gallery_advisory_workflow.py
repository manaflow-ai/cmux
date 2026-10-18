"""Keep the advisory gallery workflow bound to passing exact-head evidence."""

import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "gallery-advisory.yml"


class GalleryAdvisoryWorkflowContract(unittest.TestCase):
    def test_receipt_gate_requires_passing_quality_and_exact_head_freshness(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn(".results.status == \"complete\"", text)
        self.assertIn(".quality == \"pass\"", text)
        self.assertIn('--live-head-sha \"$HEAD_SHA\"', text)


if __name__ == "__main__":
    unittest.main()
