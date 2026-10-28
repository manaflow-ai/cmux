#!/usr/bin/env python3
"""perf-signposts.py's presentation rows (p03-rendering 004): `action.presented_estimate`, `motion.late_commits`
and the estimate's error against a presented-frame timeline, through the command line (--from, --presented,
--json) as a fleet run reads them. No app, no build: a saved stream and a timeline file."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "cmux-next" / "perf-signposts.py"


def load():
    spec = importlib.util.spec_from_file_location("perf_signposts", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class PerfSignpostsPresentedTests(unittest.TestCase):
    def setUp(self) -> None:
        self.module = load()
        self.dir = tempfile.TemporaryDirectory()
        self.stream = Path(self.dir.name) / "signposts.ndjson"
        self.stream.write_text(self.module.SAMPLE)

    def tearDown(self) -> None:
        self.dir.cleanup()

    def run_script(self, *args: str) -> dict:
        result = subprocess.run([sys.executable, "-I", str(SCRIPT), "--from", str(self.stream), "--allow-loss",
                                 "--json", *args], capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    def test_self_test_passes(self) -> None:
        result = subprocess.run([sys.executable, "-I", str(SCRIPT), "--self-test"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("self-test ok", result.stdout)

    def test_json_reports_presentation_rows_and_late_commits(self) -> None:
        report = self.run_script()
        rows = {(r["name"], r["detail"]): r for r in report["rows"]}
        self.assertEqual(report["late_commits"], 2)
        self.assertEqual(report["estimate_phases"], {"running": 1, "recent": 1})
        self.assertIsNone(report["estimate_error_p95_frames"])
        self.assertEqual(rows[("action.presented_estimate", "*")]["count"], 2)
        self.assertAlmostEqual(rows[("action.input_to_presented_estimate", "tab.new")]["p50_ms"], 15.5)
        # perf_stats' linear interpolation over [1.25, 3.75]: 1.25 + 0.99 * 2.5.
        self.assertAlmostEqual(rows[("motion.late_commits", "*")]["p99_ms"], 3.725)
        for row in report["rows"]:
            self.assertTrue({"p50_ms", "p95_ms", "p99_ms", "max_ms"} <= row.keys(), row)

    def test_presented_timeline_gives_the_error_in_frames(self) -> None:
        timeline = Path(self.dir.name) / "presented.json"
        timeline.write_text(json.dumps({"presented_s": [0.9, 1.0125, 2.0105, 2.03], "refresh_hz": 120}))
        report = self.run_script("--presented", str(timeline))
        rows = {(r["name"], r["detail"]): r for r in report["rows"]}
        self.assertEqual(rows[("action.presented_estimate.error", "*")]["count"], 2)
        self.assertAlmostEqual(rows[("action.presented_estimate.error", "*")]["max_ms"], 2.5)
        # p95 of |error| [1.5, 2.5] ms is 2.45 ms (perf_stats' linear interpolation); one 120 Hz frame is 8.333 ms.
        self.assertAlmostEqual(report["estimate_error_p95_frames"], 0.294, places=3)
        self.assertEqual(report["estimate_pairing"], {"paired": 2, "busy": 0, "unshown": 0})

    def test_a_frame_at_every_vsync_pairs_no_estimate(self) -> None:
        """While the screen changes every frame the next changed frame may be anyone's: pairing with it would score
        every estimate one frame off, right or wrong. Those estimates are counted busy, never scored."""
        timeline = Path(self.dir.name) / "presented.json"
        timeline.write_text(json.dumps({"presented_s": [1 + k / 120 for k in range(150)], "refresh_hz": 120}))
        report = self.run_script("--presented", str(timeline))
        self.assertEqual(report["estimate_pairing"], {"paired": 0, "busy": 2, "unshown": 0})
        self.assertIsNone(report["estimate_error_p95_frames"])
        self.assertFalse(any(r["name"] == "action.presented_estimate.error" for r in report["rows"]))

    def test_an_estimate_two_frames_off_fails_dc14(self) -> None:
        timeline = Path(self.dir.name) / "presented.json"
        timeline.write_text(json.dumps({"presented_s": [1.014 + 2 / 120, 2.013 + 2 / 120], "refresh_hz": 120}))
        report = self.run_script("--presented", str(timeline))
        self.assertAlmostEqual(report["estimate_error_p95_frames"], 2.0, places=3)
        self.assertGreater(report["estimate_error_p95_frames"], 1)

    def test_a_stream_without_presentation_events_reports_none(self) -> None:
        self.stream.write_text("\n".join(line for line in self.module.SAMPLE.splitlines()
                                         if '"signpostType":"event"' not in line) + "\n")
        report = self.run_script()
        self.assertEqual(report["late_commits"], 0)
        self.assertEqual(report["estimate_phases"], {})
        self.assertFalse(any(r["name"].startswith(("action.presented", "motion.")) for r in report["rows"]))


if __name__ == "__main__":
    unittest.main()
