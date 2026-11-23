#!/usr/bin/env python3
"""interactive-lateness.sh prints one JSON line with every reading RFD 0072 names; the macOS parsers read real text."""
from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path

MEASURE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(MEASURE))

import latency_probe as lp  # noqa: E402


class WrapperPrintsOneLine(unittest.TestCase):
    def test_one_json_line_with_every_reading(self):
        out = subprocess.run(["bash", str(MEASURE / "interactive-lateness.sh"), "seconds=0.3", "label=test"],
                             text=True, capture_output=True, timeout=60, check=True).stdout
        lines = out.strip().splitlines()
        self.assertEqual(len(lines), 1, out)
        doc = json.loads(lines[0])
        self.assertEqual(doc["schema"], "interactive-lateness/v1")
        self.assertEqual(doc["label"], "test")
        for key in ("lateness_ms", "cpu", "memory", "swap", "thermal", "hid_idle_s", "load", "errors"):
            self.assertIn(key, doc)
        self.assertGreater(doc["lateness_ms"]["wakes"], 5)
        self.assertIsNotNone(doc["lateness_ms"]["p50"])
        self.assertIn("busy_pct", doc["cpu"], doc["errors"])

    def test_bad_arguments_refused(self):
        for args in (["foo=1"], ["1", "a", "b"], ["seconds=nope"], ["seconds=0"]):
            rc = subprocess.run(["bash", str(MEASURE / "interactive-lateness.sh"), *args], capture_output=True,
                                timeout=30).returncode
            self.assertEqual(rc, 2, args)


class Parsers(unittest.TestCase):
    def test_swapusage(self):
        got = lp.parse_swapusage("total = 24576.00M  used = 23450.25M  free = 1125.75M  (encrypted)")
        self.assertEqual(got, {"total_mb": 24576.0, "used_mb": 23450.2, "free_mb": 1125.8})
        self.assertEqual(lp.parse_swapusage("total = 1.00G  used = 0.00M  free = 1.00G")["total_mb"], 1024.0)

    def test_vm_stat(self):
        text = ("Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free:  1000.\n"
                "Swapins:                                3361205.\nSwapouts:                               4040551.\n")
        self.assertEqual(lp.parse_vm_stat_swapouts(text), (4040551, 16384))

    def test_hid_idle(self):
        text = '    |   "HIDIdleTime" = 2547316041\n    |   "HIDIdleTime" = 9\n'
        self.assertEqual(lp.parse_hid_idle(text), 2.5)

    def test_cpu_share_and_lateness_summary(self):
        self.assertEqual(lp.cpu_share((0, 0, 0, 0), (60, 20, 20, 0))["busy_pct"], 80.0)
        s = lp.summarize_lateness([1.0] * 98 + [6.0, 20.0])
        self.assertEqual((s["wakes"], s["p50"], s["max"], s["over_5ms_pct"], s["over_16ms_pct"]),
                         (100, 1.0, 20.0, 2.0, 1.0))


if __name__ == "__main__":
    unittest.main()
