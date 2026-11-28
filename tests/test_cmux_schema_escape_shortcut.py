#!/usr/bin/env python3
"""cmux.schema.json accepts Esc as a shortcut key when a modifier is held."""

import json
import re
import unittest
from pathlib import Path

SCHEMA = json.loads(
    (Path(__file__).resolve().parents[1] / "web" / "data" / "cmux.schema.json").read_text()
)
STROKE = re.compile(SCHEMA["$defs"]["shortcutStroke"]["pattern"])
FIRST_MODIFIER = re.compile(
    SCHEMA["$defs"]["shortcutFirstStroke"]["allOf"][1]["anyOf"][0]["pattern"]
)


class EscapeShortcutSchemaTests(unittest.TestCase):
    def test_modified_escape_matches_stroke_pattern(self):
        for value in ["ctrl+escape", "ctrl+esc", "cmd+shift+Escape", "ctrl+ESC"]:
            self.assertTrue(STROKE.fullmatch(value), value)
            self.assertTrue(FIRST_MODIFIER.match(value), value)

    def test_bare_escape_is_not_a_first_stroke(self):
        self.assertFalse(FIRST_MODIFIER.match("escape"))


if __name__ == "__main__":
    unittest.main()
