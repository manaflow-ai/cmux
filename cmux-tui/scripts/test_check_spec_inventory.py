#!/usr/bin/env python3
"""Regression tests for the cmux-tui specification inventory checker."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
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


if __name__ == "__main__":
    unittest.main()
