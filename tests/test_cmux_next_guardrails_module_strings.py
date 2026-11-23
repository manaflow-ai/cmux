#!/usr/bin/env python3
"""guardrails.py rule `module-strings` (CMUX-570): a new string lookup reads `.localizedModule`, never `bundle: .module`.

Not on CI (Lawrence 2026-10-23: no new CI gates): run it yourself after a change to the rule:
python3 tests/test_cmux_next_guardrails_module_strings.py
"""
import importlib.util
from pathlib import Path
import sys
import unittest

_HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("cmux_next_guardrails_suite", _HERE / "test_cmux_next_guardrails.py")
suite = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = suite
_spec.loader.exec_module(suite)
KIT = suite.KIT

REFUSED = [
    'let s = String(localized: "a.b", defaultValue: "A", table: "T", bundle: .module)',
    'let s = String(localized: "a.b", defaultValue: "A", bundle:.module)',
    'Text("a.b", bundle: .module)',
]
ALLOWED = [
    'let s = String(localized: "a.b", defaultValue: "A", table: "T", bundle: .localizedModule)',
    'let s = String(localized: "a.b", defaultValue: "A", bundle: .module.inAppLanguage)',
    'let u = Bundle.module.url(forResource: "x", withExtension: "png")',
    'let i = Image("x", bundle: .module) // module-strings-allow: an image, not a string',
    '// any `String(localized:bundle: .module)` read creates the bundle',
    'let s = "bundle: .module"',
]


def swift(line: str) -> str:
    return f"func f() {{\n    {line}\n}}\n"


class ModuleStringsRuleTests(suite.Fixture):
    def refused_ids(self, line):
        self.git("reset", "--quiet", "--hard", self.base)
        self.write(f"{KIT}/Added.swift", swift(line))
        self.commit(f"adds {line}")
        refusals, _ = self.check()
        return [r.id for r, _ in refusals]

    def test_a_module_string_lookup_is_refused(self):
        for line in REFUSED:
            with self.subTest(line=line):
                self.assertIn("module-strings", self.refused_ids(line))

    def test_localized_module_the_app_form_other_resources_and_the_escape_pass(self):
        for line in ALLOWED:
            with self.subTest(line=line):
                self.assertNotIn("module-strings", self.refused_ids(line))

    def test_an_existing_module_lookup_never_counts(self):
        old = swift(REFUSED[0])
        self.rebase_on({f"{KIT}/Old.swift": old})
        self.write(f"{KIT}/Old.swift", old + "// edited\n")
        self.commit("edits around an old lookup")
        refusals, _ = self.check()
        self.assertNotIn("module-strings", [r.id for r, _ in refusals])


if __name__ == "__main__":
    unittest.main()
