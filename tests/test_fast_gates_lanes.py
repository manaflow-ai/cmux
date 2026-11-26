#!/usr/bin/env python3
"""Fast gates run side by side; only web lint and webviews checks (both may bun install) share a lane.

On 2026-11-22 webviews checks waited for crash-class rules in a second batch, so the gates step took the sum
of the two (157 s) instead of the longer one (93 s). These tests run fake gates that sleep and check the
wall time and the order.
"""
from __future__ import annotations

import importlib.util
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("cmux_next_fast_gates", ROOT / "scripts/ci/cmux_next_fast_gates.py")
fast_gates = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fast_gates)


def sleeper(seconds: float, marker: Path | None = None, wait_for: Path | None = None) -> list[str]:
    """A gate that sleeps, optionally fails unless WAIT_FOR exists, then writes MARKER."""
    code = "import sys, time, pathlib\n"
    code += f"time.sleep({seconds})\n"
    if wait_for is not None:
        code += f"sys.exit(0 if pathlib.Path({str(wait_for)!r}).exists() else 7)\n"
    if marker is not None:
        code += f"pathlib.Path({str(marker)!r}).write_text('done')\n"
    return [sys.executable, "-c", code]


class GateLanes(unittest.TestCase):
    def test_only_the_bun_gates_share_a_lane(self) -> None:
        active = [("web lint", ["a"]), ("prepush gate", ["b"]), ("crash-class rules", ["c"]),
                  ("webviews checks", ["d"])]
        lanes = fast_gates.gate_lanes(active)
        self.assertEqual([[name for name, _ in lane] for lane in lanes],
                         [["prepush gate"], ["crash-class rules"], ["web lint", "webviews checks"]])

    def test_webviews_checks_alone_gets_its_own_lane(self) -> None:
        lanes = fast_gates.gate_lanes([("crash-class rules", ["c"]), ("webviews checks", ["d"])])
        self.assertEqual([[name for name, _ in lane] for lane in lanes],
                         [["crash-class rules"], ["webviews checks"]])

    def test_lanes_overlap_and_a_lane_runs_in_order(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            lint_done = work / "lint.done"
            lanes = fast_gates.gate_lanes([
                ("web lint", sleeper(0.6, marker=lint_done)),
                ("crash-class rules", sleeper(1.0)),
                ("webviews checks", sleeper(0.1, wait_for=lint_done)),
            ])
            started = time.monotonic()
            results = fast_gates.run_gate_batch(lanes, work, None, work / "logs")
            wall = time.monotonic() - started
        self.assertEqual({name: result[0] for name, result in results.items()},
                         {"web lint": 0, "crash-class rules": 0, "webviews checks": 0})
        # Side by side: about max(1.0, 0.6 + 0.1), not the 1.7 s sum.
        self.assertLess(wall, 1.5, wall)

    def test_deadline_stops_running_gates_and_skips_the_rest_of_a_lane(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            lanes = fast_gates.gate_lanes([("web lint", sleeper(30)), ("webviews checks", sleeper(0))])
            results = fast_gates.run_gate_batch(lanes, work, time.monotonic() + 0.5, work / "logs")
        self.assertIsNone(results["web lint"][0])
        self.assertNotIn("webviews checks", results)


if __name__ == "__main__":
    unittest.main()
