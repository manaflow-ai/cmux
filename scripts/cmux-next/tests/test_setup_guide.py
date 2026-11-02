"""The shipped guide, native defaults and docs must derive from the setup task manifest."""
import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location("setup_guide", Path(__file__).parents[1] / "generate-setup-guide.py")
guide = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guide)


class SetupGuideTests(unittest.TestCase):
    def test_committed_outputs_match_manifest(self):
        for path, expected in guide.outputs().items():
            with self.subTest(path=path):
                self.assertEqual(path.read_text(), expected)

    def test_manifest_has_unique_nonempty_sections(self):
        entries = guide.guides()
        self.assertEqual(len(entries), len({entry["id"] for entry in entries}))
        for entry in entries:
            self.assertTrue(entry["title"].strip())
            self.assertTrue(entry["steps"])
            self.assertTrue(all(step.strip() for step in entry["steps"]))


if __name__ == "__main__":
    unittest.main()
