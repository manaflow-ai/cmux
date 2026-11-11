"""scripts/cmux-next/cloud-composer-journey.py: the cell filter, the actionable-refusal rule, the fixtures and
the report table. The app half runs only in cloud-composer-journey.yml."""

import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("cloud_composer_journey", ROOT / "scripts/cmux-next/cloud-composer-journey.py")
journey = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(journey)


class CellFilter(unittest.TestCase):
    def test_empty_selects_every_cell(self):
        self.assertTrue(journey.selected("", "plain", "team", "bypass"))

    def test_names_and_ids(self):
        self.assertTrue(journey.selected("removed", "none", "removed", "default"))
        self.assertTrue(journey.selected("small-repo/personal/default", "small-repo", "personal", "default"))
        self.assertFalse(journey.selected("small-repo/personal/default", "small-repo", "personal", "bypass"))
        self.assertFalse(journey.selected("over-limit", "plain", "personal", "default"))

    def test_matrix_is_thirty_cells(self):
        cells = [(f, a, m) for f in journey.FOLDERS for a in journey.ACCOUNTS for m in journey.MODES]
        self.assertEqual(len(cells), 30)


class Args(unittest.TestCase):
    def test_defaults_parse(self):
        args = journey.parse_args(["--cli", "/bin/true", "--out", "/tmp/ccj-test"])
        self.assertTrue(args.tag.startswith("ccj-"))
        self.assertEqual(args.parallel, 1)

    def test_app_needs_its_backend(self):
        with self.assertRaises(SystemExit):
            journey.parse_args(["--app", "/x.app", "--out", "/tmp/ccj-test"])

    def test_answer_prompt_holds_its_token(self):
        prompt, token = journey.answer_prompt("cjabc")
        self.assertIn("cjabc", prompt)
        self.assertTrue(token.endswith(" cjabc"))


class Actionable(unittest.TestCase):
    def test_bare_retry_is_not(self):
        for message in ("", "Retry", "Something went wrong.", "Cloud start failed", "try again"):
            self.assertFalse(journey.actionable(message), message)

    def test_a_message_that_says_what_to_do_is(self):
        self.assertTrue(journey.actionable(
            "Projects is too big to copy to a Cloud machine: pick the project folder inside it"))


class Fixtures(unittest.TestCase):
    def test_each_kind(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            self.assertIsNone(journey.fixture("none", root))
            parent = journey.fixture("parent", root)
            self.assertEqual(sorted(p.name for p in parent.iterdir() if (p / ".git").exists()), ["api", "tools", "web"])
            self.assertFalse((journey.fixture("plain", root) / ".git").exists())
            over = journey.fixture("over-limit", root)
            self.assertGreater((over / "disk.img").stat().st_size, 20 * 1024 ** 3)


class Report(unittest.TestCase):
    def test_grid_marks_red_cells(self):
        text = journey.grid([
            {"folder": "plain", "account": "personal", "mode": "default", "result": "pass", "outcome": "started",
             "machines_made": ["vm_a"], "machines_left": []},
            {"folder": "parent", "account": "team", "mode": "bypass", "outcome": "refused", "mode_chip": "Mode",
             "result": "fail: refused AFTER leasing a machine (vm_b)", "machines_made": ["vm_b"], "machines_left": []},
        ])
        self.assertIn("| plain | personal | default | pass |", text)
        self.assertIn("**RED**: refused AFTER leasing a machine (vm_b)", text)


if __name__ == "__main__":
    unittest.main()
