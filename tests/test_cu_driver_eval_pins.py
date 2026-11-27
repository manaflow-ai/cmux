#!/usr/bin/env python3
"""Every `pin KEY...` lookup in scripts/measure/cu-driver-eval/*.sh resolves in pins.json.

Regression: cueval-guest.sh read `pin python sha256`, but the Python pin lives at
bench_v2.python, so the guest died with KeyError and "could not unpack the pinned Python"
on every CU suite run.
"""
from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EVAL_DIR = ROOT / "scripts/measure/cu-driver-eval"
PINS = EVAL_DIR / "pins.json"
GUEST = EVAL_DIR / "cueval-guest.sh"
PIN_CALL = re.compile(r"\$\(pin ((?:[A-Za-z0-9_.-]+ ?)+)\)")
SHA256 = re.compile(r"^[0-9a-f]{64}$")


def pin_calls() -> list[tuple[str, list[str]]]:
    calls = []
    for script in sorted(EVAL_DIR.glob("*.sh")):
        for match in PIN_CALL.finditer(script.read_text()):
            calls.append((script.name, match.group(1).split()))
    return calls


class CuDriverEvalPinsTest(unittest.TestCase):
    def test_guest_script_has_pin_lookups(self) -> None:
        self.assertIn("$(pin ", GUEST.read_text())
        self.assertTrue(pin_calls())

    def test_every_pin_lookup_resolves(self) -> None:
        pins = json.loads(PINS.read_text())
        for script, keys in pin_calls():
            node = pins
            for key in keys:
                self.assertIsInstance(node, dict, f"{script}: pin {' '.join(keys)}")
                self.assertIn(key, node, f"{script}: pin {' '.join(keys)} is not in pins.json")
                node = node[key]
            self.assertIsInstance(node, str, f"{script}: pin {' '.join(keys)}")
            self.assertTrue(node, f"{script}: pin {' '.join(keys)} is empty")
            if keys[-1] == "sha256":
                self.assertRegex(node, SHA256, f"{script}: pin {' '.join(keys)}")


if __name__ == "__main__":
    unittest.main()
