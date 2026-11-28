"""Check both command registrations and the return and toast from the QuickJS host."""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts/cmux-next"
sys.path.insert(0, str(SCRIPTS))
from ext_prompt_palette import check_palette


class PalettePromptTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.folder = Path(directory.name)
        manifest = {
            "manifestVersion": 2, "id": "local/test-notes", "name": "Stand-up",
            "version": "0.1.0", "description": "Make a stand-up note.",
            "engines": {"cmux": "^2.0"}, "runtime": {"main": "main.js"},
            "cli": {"name": "standup"}, "catalog": "ops.json",
        }
        (self.folder / "cmux-app.json").write_text(json.dumps(manifest))
        self.op = {
            "name": "local.test_notes.daily", "owner": "app:local/test-notes",
            "class": "read", "risk": "read", "idempotency": "forbidden", "since": "0.1.0",
            "docs": "Return and show a note.", "export": "makeNote",
            "input": {"type": "object", "additionalProperties": False,
                      "properties": {"done": {"type": "array", "items": {"type": "string"}}}},
            "cli": {"path": "note"}, "palette": {"title": {"en": "Stand-up: Copy my note"}},
        }
        self.write_ops([self.op])

    def write_ops(self, ops):
        (self.folder / "ops.json").write_text(json.dumps({"family": "local.test_notes", "operations": ops}))

    def test_valid_unrelated_clock_has_no_standup_command(self):
        clock = ROOT / "examples/extensions/widget-clock"
        self.assertIn("does not register", check_palette(clock))

    def test_cli_and_palette_must_name_same_operation(self):
        other = dict(self.op, name="local.test_notes.other", cli={"path": "other"})
        self.write_ops([dict(self.op, palette={"title": "Other"}), other])
        self.assertIn("palette row", check_palette(self.folder))
        self.write_ops([other])
        self.assertIn("register one handler", check_palette(self.folder))

    def test_done_is_list_of_strings(self):
        self.op["input"]["properties"]["done"] = {"type": "string"}
        self.write_ops([self.op])
        self.assertIn("list of strings", check_palette(self.folder))

    @unittest.skipUnless(shutil.which("cmux-app-host"), "requires the bundled cmux-app-host")
    def test_registered_export_must_return_and_toast_the_note(self):
        cases = [
            ("await ctx.cmux.toast({title: 'Stand-up', message: note}); return {note}", None),
            ("await ctx.cmux.toast(note); return note", None),
            ("return note", "did not show"),
            ("await ctx.cmux.toast(note); return 'Finished'", "did not return"),
            ("await ctx.cmux.toast('Finished'); return note", "did not show"),
        ]
        for handler, expected in cases:
            with self.subTest(handler=handler):
                source = ("var __cmuxAppExports = { makeNote: async (args, ctx) => {"
                          "const note = args.done.join(' / '); " + handler + " } };")
                (self.folder / "main.js").write_text(source)
                outcome = check_palette(self.folder)
                if expected is None:
                    self.assertIsNone(outcome)
                else:
                    self.assertIn(expected, outcome)
        self.op["export"] = "missingHandler"
        self.write_ops([self.op])
        self.assertIn("export.missing", check_palette(self.folder))


if __name__ == "__main__":
    unittest.main()
