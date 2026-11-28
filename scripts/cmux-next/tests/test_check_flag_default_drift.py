#!/usr/bin/env python3
# guard-inputs: scripts/cmux-next/check-flag-default-drift.py
"""check-flag-default-drift.py: a switch's code default against the default its comments and docs state
(memory-per-chat, 2026-11-28: CMUX_NEXT_CHAT_RENDERER_RECYCLE read == "1" while its arch exception said on)."""
from __future__ import annotations

import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("drift", os.path.join(HERE, "..", "check-flag-default-drift.py"))
drift = importlib.util.module_from_spec(spec)
spec.loader.exec_module(drift)

SWIFT_OFF = '''
public struct Recycle {
    public static let environmentKey = "CMUX_NEXT_CHAT_RENDERER_RECYCLE"
    public static func isEnabled(_ environment: [String: String]) -> Bool { environment[environmentKey] == "1" }
}
'''


class DriftTests(unittest.TestCase):
    def test_the_recycle_drift_is_named(self):
        defaults = drift.defaults_in(SWIFT_OFF)
        self.assertEqual(defaults, {"CMUX_NEXT_CHAT_RENDERER_RECYCLE": {"off"}})
        doc = '{"why": "Chat renderer recycle, on by default (CMUX_NEXT_CHAT_RENDERER_RECYCLE=0 turns it off)"}'
        found = drift.check_named(defaults, {"plans/x.json": doc})
        self.assertEqual(len(found), 1)
        self.assertIn("plans/x.json:1: says CMUX_NEXT_CHAT_RENDERER_RECYCLE is on by default", found[0])

    def test_a_matching_doc_passes(self):
        on = SWIFT_OFF.replace('== "1"', '!= "0"')
        doc = "On unless `CMUX_NEXT_CHAT_RENDERER_RECYCLE=0`."
        self.assertEqual(drift.check_named(drift.defaults_in(on), {"a.md": doc}), [])

    def test_a_comment_beside_the_read_that_disagrees(self):
        text = '''// On by default; CMUX_X_SWITCH=0 turns it off.
let on = ProcessInfo.processInfo.environment["CMUX_X_SWITCH"] == "1"
'''
        self.assertEqual(len(drift.check_text("a.swift", text)), 1)

    def test_rust_reads_through_a_constant(self):
        text = '''/// Off by default: `CMUX_Y_SWITCH=1` turns it on.
const SWITCH: &str = "CMUX_Y_SWITCH";
fn enabled() -> bool { std::env::var(SWITCH).as_deref() != Ok("0") }
'''
        self.assertEqual(drift.defaults_in(text), {"CMUX_Y_SWITCH": {"on"}})
        self.assertEqual(len(drift.check_text("a.rs", text)), 1)

    def test_an_opt_out_switch_set_to_1_is_no_claim(self):
        text = '''/// Opt out with CMUX_Z_DISABLED=1.
let off = env["CMUX_Z_DISABLED"] == "1"
'''
        self.assertEqual(drift.check_text("a.swift", text), [])


if __name__ == "__main__":
    unittest.main()
