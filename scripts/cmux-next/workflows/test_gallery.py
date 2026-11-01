"""Receipt normalization tests; run with the workflow tests on cmux-ci."""
import copy
from pathlib import Path
import tempfile
import unittest

from gallery import normalize


class GalleryReceiptTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name)
        for name in ("results.json", "index.html", "case.png", "before.png", "after.png"):
            (self.output / name).write_text("fixture")
        self.context = {"source_sha": "a" * 40}
        self.step = {"id": "open-menu", "target": {"entry": "menu", "variant": "open"},
                     "expect": {"made-up": "not observed"}}
        self.result = {
            "id": "open-menu", "ready": "1", "revision": {"sha": "a" * 40, "entry": "menu", "variant": "open"},
            "params": {"entry": "menu", "variant": "open"},
            "play": {"status": "pass", "steps": [
                {"action": "click", "status": "pass", "problems": [], "settleMs": 10,
                 "layoutShift": 0, "longFrames": [], "frameSource": "long-animation-frame"}]},
            "workflowEvidence": {"final": {"screenshot": "case.png", "axDigest": {
                "sha256": "b" * 64, "count": 2}}},
        }
        self.add_captures(0)

    def add_captures(self, index):
        for phase, name in (("beforeSteps", "before.png"), ("afterSteps", "after.png")):
            self.result["workflowEvidence"].setdefault(phase, []).append({
                "index": index, "screenshot": name, "axDigest": {"sha256": "b" * 64, "count": 2}})

    def receipt(self):
        return normalize(self.result, self.step, self.context, self.output, 0)

    def test_actual_outcomes_and_evidence_are_preserved(self):
        receipt = self.receipt()
        self.assertEqual(receipt["status"], "passed")
        self.assertEqual(receipt["state"]["entry"], "menu")
        self.assertNotIn("made-up", receipt["state"])
        self.assertEqual(receipt["event_refs"][0]["step"], 0)
        self.assertEqual(receipt["evidence"]["final"]["ax_digest"]["count"], 2)

    def test_first_failed_inner_step_is_identified(self):
        failed = copy.deepcopy(self.result["play"]["steps"][0])
        failed.update(status="fail", problems=["anchor moved"])
        self.result["play"]["steps"].append(failed)
        self.result["play"]["status"] = "fail"
        self.add_captures(1)
        receipt = self.receipt()
        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(receipt["first_failed_step"], 1)
        self.assertEqual(receipt["state"]["steps"][1]["status"], "fail")
        self.assertNotIn("problems", receipt["state"]["steps"][1])

    def test_empty_play_does_not_pass_as_a_workflow(self):
        self.result["play"]["steps"] = []
        self.assertEqual(self.receipt()["status"], "unavailable")

    def test_wrong_source_fails(self):
        self.result["revision"]["sha"] = "c" * 40
        self.assertEqual(self.receipt()["status"], "failed")

    def test_wrong_target_fails(self):
        self.result["revision"]["entry"] = "different-menu"
        self.assertEqual(self.receipt()["status"], "failed")

    def test_missing_before_or_after_capture_preserves_report_link(self):
        for phase in ("beforeSteps", "afterSteps"):
            with self.subTest(phase=phase):
                frames = self.result["workflowEvidence"].pop(phase)
                receipt = self.receipt()
                self.assertEqual(receipt["status"], "unavailable")
                self.assertEqual(receipt["evidence"]["report"], str(self.output.relative_to(self.output.parent) / "results.json"))
                self.result["workflowEvidence"][phase] = frames

    def test_step_capture_index_must_match_observed_step(self):
        self.result["workflowEvidence"]["beforeSteps"][0]["index"] = 1
        self.assertEqual(self.receipt()["status"], "unavailable")

    def test_each_step_requires_valid_ax_digest(self):
        self.result["workflowEvidence"]["afterSteps"][0]["axDigest"]["sha256"] = "not-a-digest"
        self.assertEqual(self.receipt()["status"], "unavailable")

    def test_each_step_requires_existing_frame(self):
        (self.output / "before.png").unlink()
        self.assertEqual(self.receipt()["status"], "unavailable")

    def test_missing_frame_is_unavailable(self):
        (self.output / "case.png").unlink()
        self.assertEqual(self.receipt()["status"], "unavailable")

    def test_external_frame_reference_is_unavailable(self):
        self.result["workflowEvidence"]["final"]["screenshot"] = "../private.png"
        self.assertEqual(self.receipt()["status"], "unavailable")

    def test_ax_evidence_is_required(self):
        self.result["workflowEvidence"]["final"]["axDigest"] = {}
        self.assertEqual(self.receipt()["status"], "unavailable")


if __name__ == "__main__":
    unittest.main()
