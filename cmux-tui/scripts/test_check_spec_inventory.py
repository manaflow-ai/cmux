#!/usr/bin/env python3
"""Regression tests for the cmux-tui specification inventory checker."""

from __future__ import annotations

import importlib.util
import io
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path


SCRIPT = Path(__file__).with_name("check-spec-inventory.py")
SPEC = importlib.util.spec_from_file_location("check_spec_inventory", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


class RustEnumVariantTests(unittest.TestCase):
    def test_command_names_include_bare_final_variant(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            tui = Path(directory)
            server = tui / "crates/cmux-tui-core/src/server.rs"
            server.parent.mkdir(parents=True)
            server.write_text(
                """\
enum Command {
    Ping,
    TupleValue(u8),
    StructValue { value: u8 },
    BareFinal
}
"""
            )

            original_tui = CHECKER.TUI
            CHECKER.TUI = tui
            try:
                self.assertEqual(
                    CHECKER.command_names(),
                    {"ping", "tuple-value", "struct-value", "bare-final"},
                )
            finally:
                CHECKER.TUI = original_tui


class SchemaValidationTests(unittest.TestCase):
    SCHEMA = {
        "type": "object",
        "required": ["names"],
        "properties": {
            "names": {
                "type": "array",
                "minItems": 1,
                "uniqueItems": True,
                "items": {
                    "type": "string",
                    "minLength": 2,
                    "pattern": "^[a-z]+$",
                },
            }
        },
        "additionalProperties": False,
    }

    def test_nested_schema_subset_accepts_valid_values(self) -> None:
        CHECKER.validate_schema({"names": ["alpha", "beta"]}, self.SCHEMA)

    def test_nested_schema_subset_preserves_error_path(self) -> None:
        errors = io.StringIO()
        with redirect_stderr(errors), self.assertRaises(SystemExit):
            CHECKER.validate_schema({"names": ["alpha", "AA"]}, self.SCHEMA)
        self.assertIn("$.names[1] does not match", errors.getvalue())

    def test_nested_schema_subset_rejects_unknown_properties(self) -> None:
        errors = io.StringIO()
        with redirect_stderr(errors), self.assertRaises(SystemExit):
            CHECKER.validate_schema({"names": ["alpha"], "extra": True}, self.SCHEMA)
        self.assertIn("$ has unknown property 'extra'", errors.getvalue())


if __name__ == "__main__":
    unittest.main()
