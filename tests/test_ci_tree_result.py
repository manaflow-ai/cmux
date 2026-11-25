"""scripts/ci/tree_result.py: a restored record counts only as a green result of the same job for the same input
tree, and says which run earned it."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("tree_result", ROOT / "scripts/ci/tree_result.py")
tree_result = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tree_result)

ENV = {"GITHUB_SHA": "a" * 40, "GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/feat-cmux-next",
       "GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_RUN_ID": "77", "GITHUB_RUN_ATTEMPT": "2"}


class TreeResult(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name) / ".tree-result"

    def test_a_marked_result_is_said_with_its_run(self):
        tree_result.mark(self.dir, "acpmux-tests", "k" * 64, ENV)
        ok, line = tree_result.said(self.dir, "acpmux-tests", "k" * 64)
        self.assertTrue(ok)
        self.assertIn("https://github.com/manaflow-ai/cmux/actions/runs/77/attempts/2", line)
        self.assertIn("aaaaaaaaaaaa", line)

    def test_another_jobs_or_another_keys_record_is_no_hit(self):
        tree_result.mark(self.dir, "acpmux-tests", "k" * 64, ENV)
        self.assertFalse(tree_result.said(self.dir, "acpmux-sim", "k" * 64)[0])
        self.assertFalse(tree_result.said(self.dir, "acpmux-tests", "j" * 64)[0])

    def test_a_record_that_is_not_green_or_not_readable_is_no_hit(self):
        self.assertFalse(tree_result.said(self.dir, "acpmux-tests", "k")[0])  # nothing restored
        self.dir.mkdir()
        (self.dir / tree_result.RECORD).write_text("{", encoding="utf-8")
        self.assertFalse(tree_result.said(self.dir, "acpmux-tests", "k")[0])
        (self.dir / tree_result.RECORD).write_text(json.dumps(
            {"job": "acpmux-tests", "key": "k", "conclusion": "failure"}), encoding="utf-8")
        self.assertFalse(tree_result.said(self.dir, "acpmux-tests", "k")[0])

    def test_the_cli_exits_1_on_a_miss(self):
        self.assertEqual(tree_result.main(["said", "--dir", str(self.dir), "--job", "x", "--key", "k"]), 1)


class TheAction(unittest.TestCase):
    """.github/actions/tree-result: only a pull request reuses, and only a passed job saves."""

    def test_only_a_pull_request_restores(self):
        text = (ROOT / ".github/actions/tree-result/action.yml").read_text(encoding="utf-8")
        self.assertIn("github.event_name == 'pull_request'", text)
        self.assertIn("steps.said.outcome == 'success'", text)


if __name__ == "__main__":
    unittest.main()
