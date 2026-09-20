import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import importlib.util

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("verification_receipt", REPO / "scripts/verification_receipt.py")
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)
ROOT = REPO / "tests/fixtures/verification_receipt"


class AdapterTests(unittest.TestCase):
    def test_failure_fixtures(self):
        for path in sorted((ROOT / "fixtures").glob("*.json")):
            with self.subTest(path=path.name):
                fixture = json.loads(path.read_text())
                result = a.assess(fixture["receipt"])
                self.assertFalse(result["assessment"]["exact_verification"])
                self.assertIn(fixture["expected_qualification"], result["assessment"]["qualifications"])
                if path.stem == "stale-review":
                    self.assertFalse(result["assessment"]["review_current"])
                if path.stem == "wrong-artifact":
                    self.assertFalse(result["assessment"]["launched_matches_produced"])

    def test_summary_counts_exclude_skipped(self):
        counts, ok = a.unittest_summary("Ran 4 tests in 0.01s\nOK (skipped=2)\n")
        self.assertTrue(ok)
        self.assertEqual(counts, {"runner_reported": 4, "executed": 2, "skipped": 2})

    def test_unknown_or_ambiguous_summary_is_not_pass(self):
        for output in ("OK", "Ran 2 tests in 0s\nOK\nRan 2 tests in 0s\nOK",
                       "Ran 1 test in 0s\nOK (skipped=2)"):
            counts, ok = a.unittest_summary(output)
            self.assertFalse(ok)
            self.assertIsNone(counts["executed"])

    def test_failed_tests_keep_count(self):
        counts, ok = a.unittest_summary("Ran 2 tests in 0.01s\nFAILED (failures=1)\n")
        self.assertEqual(counts["executed"], 2)
        self.assertFalse(ok)

    def test_local_real_execution_and_drift(self):
        # Deterministic temp Git fixture exercises the adapter across the actual subprocess.
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            (repo / "tests").mkdir()
            (repo / "tracked").write_text("before")
            (repo / a.RECIPE).write_text(
                "import unittest\nfrom pathlib import Path\n"
                "class T(unittest.TestCase):\n"
                " def test_drift(self):\n  Path('tracked').write_text('after')\n"
                "unittest.main()\n")
            for argv in (["init", "-q"], ["add", "."],
                         ["-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
                          "commit", "-qm", "fixture"]):
                subprocess.run(["git", "-C", tmp, *argv], check=True, capture_output=True)
            result = a.local(repo)
            self.assertEqual(a.check(result, "tests")["status"], "passed")
            self.assertEqual(result["tests"]["executed"], 1)
            self.assertEqual(result["source"]["before"]["commit"], result["source"]["after"]["commit"])
            self.assertIn("source_drift_observed", result["assessment"]["qualifications"])
            self.assertFalse(result["assessment"]["exact_verification"])
            self.assertIsNone(result["artifacts"]["produced"])

    def test_cli_defaults_to_its_repository_from_another_cwd(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            (repo / "scripts").mkdir()
            (repo / "tests").mkdir()
            script = repo / "scripts/verification_receipt.py"
            script.write_text((REPO / "scripts/verification_receipt.py").read_text())
            (repo / a.RECIPE).write_text(
                "import unittest\nclass T(unittest.TestCase):\n"
                " def test_ok(self): self.assertTrue(True)\nunittest.main()\n")
            for argv in (["init", "-q"], ["add", "."],
                         ["-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
                          "commit", "-qm", "fixture"]):
                subprocess.run(["git", "-C", tmp, *argv], check=True, capture_output=True)
            completed = subprocess.run(["python3", str(script), "local"], cwd=repo.parent,
                                       check=True, capture_output=True, text=True)
            result = json.loads(completed.stdout)
            self.assertEqual(result["tests"]["executed"], 1)
            self.assertEqual(a.check(result, "tests")["status"], "passed")
            self.assertIsNone(result["tests"]["discovered"])
            self.assertFalse(result["assessment"]["exact_verification"])

    def test_ci_real_receipt_preserves_failed_workflow_and_merge_source(self):
        data = json.loads((ROOT / "examples/ci-input.json").read_text())
        result = a.ci(data["run"], data["job"], data["log"])
        self.assertEqual(result, json.loads((ROOT / "examples/ci.json").read_text()))
        self.assertEqual(result["evidence"]["run_conclusion"], "failure")
        self.assertEqual(a.check(result, "tests")["status"], "passed")
        self.assertNotEqual(result["source"]["merge_sha"], result["source"]["head_sha"])
        self.assertIsNone(result["source"]["after"])
        self.assertIsNone(result["tests"]["discovered"])
        self.assertEqual(result["tests"]["executed"], 3)

    def ci_data(self):
        return json.loads((ROOT / "examples/ci-input.json").read_text())

    def test_ci_zero_tests_does_not_inherit_provider_green(self):
        data = self.ci_data()
        data["log"] = data["log"].replace("Ran 3 tests", "Ran 0 tests")
        result = a.ci(data["run"], data["job"], data["log"])
        self.assertEqual(a.check(result, "tests")["status"], "failed")
        self.assertEqual(result["evidence"]["step_conclusion"], "success")
        self.assertFalse(result["assessment"]["exact_verification"])

    def test_ci_missing_summary_and_wrong_job_fail_closed(self):
        data = self.ci_data()
        r = a.ci(data["run"], data["job"], "")
        self.assertEqual(a.check(r, "tests")["status"], "failed")
        data["job"]["run_id"] += 1
        with self.assertRaises(ValueError):
            a.ci(data["run"], data["job"], data["log"])

    def test_all_provider_terminal_states_remain_distinct(self):
        for conclusion, expected in (("failure", "failed"), ("skipped", "skipped"),
                                     ("neutral", "unsupported"), ("cancelled", "interrupted"),
                                     ("timed_out", "interrupted")):
            data = self.ci_data()
            data["job"]["steps"][0]["conclusion"] = conclusion
            r = a.ci(data["run"], data["job"], "")
            self.assertEqual(a.check(r, "tests")["status"], expected)

    def test_prep_or_parse_success_does_not_imply_typecheck(self):
        r = a.envelope()
        for phase in ("preparation", "parsing"):
            a.check(r, phase).update(status="passed", executed=True, evidence="fixture")
        a.check(r, "typechecking").update(status="failed", executed=True, evidence="fixture")
        r = a.assess(r)
        self.assertFalse(r["assessment"]["exact_verification"])
        self.assertEqual(a.check(r, "typechecking")["status"], "failed")
        self.assertEqual(a.check(r, "packaging")["status"], "skipped")

    def test_clean_equal_heads_still_not_exact(self):
        r = a.envelope()
        r["source"]["before"] = r["source"]["after"] = {"commit": "a" * 40, "clean": True}
        self.assertEqual(a.assess(r)["assessment"]["qualifications"], ["exact_snapshot_not_established"])

    def test_matching_artifact_and_review_are_separate_from_exact_source(self):
        r = json.loads((ROOT / "fixtures/wrong-artifact.json").read_text())["receipt"]
        r["artifacts"]["launched"] = copy.deepcopy(r["artifacts"]["produced"])
        r["review"] = {"status": "passed", "reviewed_head": "a" * 40,
                       "current_head": "a" * 40, "evidence": "fixture"}
        assessment = a.assess(r)["assessment"]
        self.assertTrue(assessment["launched_matches_produced"])
        self.assertTrue(assessment["review_current"])
        self.assertFalse(assessment["exact_verification"])

    def test_interrupted_local_stays_interrupted(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            (repo / "tests").mkdir()
            (repo / a.RECIPE).write_text("unused")
            with patch.object(a, "observe", return_value={"commit": None, "clean": None}), \
                 patch.object(a.subprocess, "check_output", return_value="Python fixture"), \
                 patch.object(a.subprocess, "run", side_effect=subprocess.TimeoutExpired("fixture", 60)):
                result = a.local(repo)
            self.assertEqual(a.check(result, "tests")["status"], "interrupted")
            self.assertIsNone(result["evidence"]["exit_code"])


if __name__ == "__main__":
    unittest.main()
