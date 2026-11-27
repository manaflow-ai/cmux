"""Behavioral checks for the manifest-only composer prompt."""
from __future__ import annotations

import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts/cmux-next"
sys.path.insert(0, str(SCRIPTS))
from ext_prompt_composer import check_composer

RECIPE = ROOT / "skills/cmux-extension-author/recipes/composer-command.md"
REVIEW = {
    "name": "review",
    "description": "Review my changes",
    "insert": "Review the changes on this branch: what could break, what is missing a test, "
              "and what you would rename.",
}


class ComposerPromptTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.folder = Path(directory.name)
        block = re.search(r"^```json cmux-app\.json\n(.*?)\n```$", RECIPE.read_text(), re.M | re.S)
        self.app = json.loads(block.group(1))
        self.commands = self.app["implements"]["cmux.composer.command/1"]["options"]["commands"]

    def write_manifest(self, name="cmux-app.json"):
        (self.folder / name).write_text(json.dumps(self.app), encoding="utf-8")

    def test_manifest_only_review(self):
        self.commands.append(REVIEW)
        self.write_manifest()
        self.assertIsNone(check_composer(self.folder))

    def test_unmodified_recipe_lacks_requested_command(self):
        self.write_manifest()
        self.assertIn("missing /review", check_composer(self.folder))

    def test_description_and_insert_must_belong_to_review(self):
        for field in ("description", "insert"):
            with self.subTest(field=field):
                self.commands[:] = [dict(REVIEW, name="other"), {**REVIEW, field: "wrong"}]
                self.write_manifest()
                self.assertIn(field, check_composer(self.folder))

    def test_only_active_manifest_counts(self):
        self.write_manifest()
        self.commands.append(REVIEW)
        self.write_manifest("cmux-app.v2.json")
        self.assertIn("missing /review", check_composer(self.folder))
        (self.folder / "cmux-app.json").unlink()
        self.assertIsNone(check_composer(self.folder))


if __name__ == "__main__":
    unittest.main()
