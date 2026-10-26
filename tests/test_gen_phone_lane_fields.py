#!/usr/bin/env python3
"""Tests for scripts/cmux-next/gen-phone-lane-fields.py (p05-ipc-048): the phone lane's field table
is current and idempotent, a newly allowed command gets its row, and a `clients: ios` command the
lane would refuse stops the script."""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import unittest
import unittest.mock
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/cmux-next/gen-phone-lane-fields.py"
SPEC = importlib.util.spec_from_file_location("gen_phone_lane_fields", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
GEN = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = GEN
SPEC.loader.exec_module(GEN)


def schema_commands() -> dict:
    with open(os.path.join(GEN.ROOT, GEN.SCHEMA), encoding="utf-8") as handle:
        return json.load(handle)["commands"]


class PhoneLaneFieldsTests(unittest.TestCase):
    def test_committed_table_is_current(self) -> None:
        with unittest.mock.patch.object(sys, "argv", ["gen-phone-lane-fields.py", "--check"]):
            self.assertEqual(GEN.main(), 0)

    def test_two_renders_are_equal(self) -> None:
        self.assertEqual(GEN.render(), GEN.render())

    def test_every_ios_command_is_allowed(self) -> None:
        ios = GEN.ios_commands(schema_commands())
        self.assertIn("attach-surface", ios)
        self.assertLessEqual(set(ios), set(GEN.allowed_commands()))

    def test_newly_allowed_command_gets_its_row(self) -> None:
        # Names the schema gained in p05-ipc-016 (served by sniffers before) render once allowed.
        allowed = GEN.allowed_commands()
        added = ["browser-runtime-stop", "loopback-credit"]
        self.assertFalse(set(added) & set(allowed))
        with unittest.mock.patch.object(GEN, "allowed_commands", return_value=sorted(allowed + added)):
            text = GEN.render()
        self.assertIn('        "browser-runtime-stop": ["runtime"],', text)
        self.assertIn('        "loopback-credit": ["bytes", "stream"],', text)
        self.assertEqual(text.count("\n        \""), len(allowed) + len(added))

    def test_ios_command_the_lane_refuses_stops_the_script(self) -> None:
        allowed = [name for name in GEN.allowed_commands() if name not in ("browser-back", "send")]
        with unittest.mock.patch.object(GEN, "allowed_commands", return_value=allowed):
            with self.assertRaisesRegex(SystemExit, "iOS client sends .*: browser-back, send; allow each one"):
                GEN.render()

    def test_absent_clients_counts_as_ios(self) -> None:
        commands = {"ping": {}, "list-panes": {"clients": ["macos", "sdk"]}, "send": {"clients": ["ios", "sdk"]}}
        self.assertEqual(GEN.ios_commands(commands), ["ping", "send"])


if __name__ == "__main__":
    unittest.main()
