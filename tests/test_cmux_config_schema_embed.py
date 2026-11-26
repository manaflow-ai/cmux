#!/usr/bin/env python3
"""The Swift-embedded cmux.json schema decodes to the exact source bytes.

scripts/generate-cmux-config-schema.py writes the schema into
CmuxConfigSchema.generated.swift as a raw multi-line string literal, line for
line with web/data/cmux.schema.json, so git merges independent schema edits
in the generated file as cleanly as in the source. These tests read the literal
back with Swift's rules (closing delimiter, dropped final line break, no
escapes) and check the result, the delimiter choice, and the merge property.
"""

from __future__ import annotations

import importlib.util
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "generate_cmux_config_schema", ROOT / "scripts" / "generate-cmux-config-schema.py"
)
generator = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(generator)

LITERAL = re.compile(r'static let json = (#+)"""\n(.*?)\n"""\1\n', re.S)


def swift_literal_value(source: str) -> bytes:
    match = LITERAL.search(source)
    assert match, "no raw multi-line json literal in the generated Swift"
    hashes, body = match.groups()
    # A raw literal has no escapes unless a backslash is followed by its
    # delimiter, and ends only at the closing quotes plus that delimiter.
    assert f"\\{hashes}" not in body
    assert f'"""{hashes}' not in body
    return body.encode("utf-8")


class EmbeddedSchemaTests(unittest.TestCase):
    def test_committed_swift_decodes_to_source_bytes(self) -> None:
        swift = (ROOT / generator.OUTPUT_PATH).read_text(encoding="utf-8")
        self.assertEqual(swift_literal_value(swift), (ROOT / generator.SCHEMA_PATH).read_bytes())
        self.assertIn("static let data = Data(json.utf8)", swift)

    def generate(self, text: str) -> str:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "schema.json"
            path.write_bytes(text.encode("utf-8"))
            return generator.generated_source(path)

    def test_round_trips_with_and_without_final_newline(self) -> None:
        for text in ('{"a": 1}\n', '{"a": 1}', '{\n  "a": "\\u00e9 ok"\n}\n\n'):
            self.assertEqual(swift_literal_value(self.generate(text)), text.encode("utf-8"))

    def test_delimiter_grows_past_colliding_content(self) -> None:
        self.assertEqual(generator.raw_string_delimiter('{"$ref": "x"}'), "#")
        self.assertEqual(generator.raw_string_delimiter('{"$ref": "#/a"}'), "##")
        self.assertEqual(generator.raw_string_delimiter('{"p": "\\\\##x", "q": "#"}'), "###")
        text = '{"a": "#/x", "b": "##y", "c": "\\\\###"}\n'
        swift = self.generate(text)
        self.assertIn('static let json = ####"""', swift)
        self.assertEqual(swift_literal_value(swift), text.encode("utf-8"))

    def test_rejects_carriage_returns(self) -> None:
        with self.assertRaises(SystemExit):
            self.generate('{"a": 1}\r\n')

    def test_independent_settings_merge_cleanly(self) -> None:
        lines = [f'  "k{i}": {i},' for i in range(40)]
        base = "{\n" + "\n".join(lines) + '\n  "end": 0\n}\n'
        ours = base.replace('  "k5": 5,\n', '  "k5": 5,\n  "ours": true,\n')
        theirs = base.replace('  "k30": 30,\n', '  "k30": 30,\n  "theirs": true,\n')
        merged_json = ours.replace('  "k30": 30,\n', '  "k30": 30,\n  "theirs": true,\n')
        with tempfile.TemporaryDirectory() as temp:
            paths = {}
            for name, text in (("base", base), ("ours", ours), ("theirs", theirs)):
                paths[name] = Path(temp) / name
                paths[name].write_text(self.generate(text), encoding="utf-8")
            result = subprocess.run(
                ["git", "merge-file", "-p", str(paths["ours"]), str(paths["base"]), str(paths["theirs"])],
                capture_output=True, text=True, check=False,
            )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout, self.generate(merged_json))


if __name__ == "__main__":
    unittest.main()
