#!/usr/bin/env python3
"""cmux-next-ios/scripts/pagedlist_stress_gate.py: red on layout shift or a case that measured nothing,
green with hitches (reported only)."""
from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "cmux-next-ios" / "scripts"))

import pagedlist_stress_gate as gate  # noqa: E402

SUITE = """
final class PagedListStressUITests: XCTestCase {
    @MainActor func testDownSlowFlood() { stress("down", .slow, "flood") }
    @MainActor func testUpFastHugeWindowed() { stress("up", .fast, "huge", window: 300) }
}
"""


def hud(**over):
    base = {"frameShift": 0.17, "shiftedFrames": 0, "maxShift": 0.0, "hitchMsPerS": 1.0, "worstMs": 33.0,
            "dropped": 2, "inMemory": 300, "samples": 4000, "changes": 900}
    base.update(over)
    return base


def line(name, direction, speed, load, window, h):
    record = {"direction": direction, "speed": speed, "load": load, "window": window, "hud": h}
    return f"t = 1.0 PAGEDLIST {name} {json.dumps(record)}"


class GateTest(unittest.TestCase):
    def run_gate(self, records: list[str]) -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as tmp:
            ev = Path(tmp) / "ios-sim"
            ev.mkdir()
            (ev / "ui-console.txt").write_text("\n".join(records) + "\n")
            suite = Path(tmp) / "PagedListStressUITests.swift"
            suite.write_text(SUITE)
            summary = Path(tmp) / "summary.md"
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = gate.main([str(ev), "--suite", str(suite), "--summary", str(summary)])
            self.assertIn("## PagedList stress", summary.read_text())
            return code, out.getvalue()

    def both(self, down=None, up=None):
        return [line("STRESS-down-slow-flood", "down", "slow", "flood", None, down or hud(inMemory=2400)),
                line("STRESS-up-fast-huge", "up", "fast", "huge", 300, up or hud())]

    def test_reads_the_suite_cases(self):
        with tempfile.TemporaryDirectory() as tmp:
            suite = Path(tmp) / "s.swift"
            suite.write_text(SUITE)
            self.assertEqual(gate.expected_cases(suite), ["STRESS-down-slow-flood", "STRESS-up-fast-huge"])
        self.assertEqual(len(gate.expected_cases(gate.SUITE)), 22)

    def test_green_when_nothing_shifts(self):
        code, out = self.run_gate(self.both())
        self.assertEqual(code, 0, out)
        self.assertIn("2 of 2 cases measured", out)

    def test_hitches_are_reported_not_failed(self):
        code, out = self.run_gate(self.both(down=hud(hitchMsPerS=154.3, inMemory=2400)))
        self.assertEqual(code, 0, out)
        self.assertIn("::warning::PagedList stress: STRESS-down-slow-flood: scrolling hitched 154.3 ms a second", out)

    def test_red_on_a_frame_shift(self):
        code, out = self.run_gate(self.both(up=hud(frameShift=0.8, shiftedFrames=3)))
        self.assertEqual(code, 1, out)
        self.assertIn("::error::PagedList stress: STRESS-up-fast-huge: a row being read moved 0.8 pt", out)

    def test_red_on_a_landing_shift(self):
        code, out = self.run_gate(self.both(down=hud(maxShift=66.0, inMemory=2400)))
        self.assertEqual(code, 1, out)
        self.assertIn("a landing page moved the reader 66 pt", out)

    def test_red_on_a_missing_case(self):
        code, out = self.run_gate(self.both()[:1])
        self.assertEqual(code, 1, out)
        self.assertIn("STRESS-up-fast-huge: no record", out)

    def test_red_on_a_case_that_measured_nothing(self):
        code, out = self.run_gate(self.both(up=hud(samples=4)))
        self.assertEqual(code, 1, out)
        self.assertIn("sampled only 4 layout passes", out)
        code, out = self.run_gate(self.both(up=hud(changes=0)))
        self.assertEqual(code, 1, out)
        self.assertIn("the load changed nothing", out)

    def test_red_when_there_is_no_evidence(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(gate.main(["/nonexistent/ios-sim", "--summary", "/dev/null"]), 1)


if __name__ == "__main__":
    unittest.main()
