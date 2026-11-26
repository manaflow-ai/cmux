#!/usr/bin/env python3
"""vmmap_regions parses `vmmap --summary` into the per-region dirty+swapped MB perf-idle-ab records per
process (goal ram-baseline: what the app's 233-268 MB and the main renderer's 122-216 MB are made of).

The fixture is a renderer's summary in the shape macOS 15's vmmap prints: region names with spaces, a
number (`Memory Tag 255`) and parentheses, rows that end in a note, a MALLOC ZONE table with % FRAG."""

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import vmmap_regions as vr  # noqa: E402

FIXTURE = (Path(__file__).resolve().parent / "fixtures" / "vmmap" / "renderer-summary.txt").read_text()


class ParseSummary(unittest.TestCase):
    def setUp(self):
        self.got = vr.parse_summary(FIXTURE)

    def test_footprint(self):
        self.assertEqual(self.got["physical_footprint_mb"], 122.2)
        self.assertEqual(self.got["physical_footprint_peak_mb"], 265.1)

    def test_names_with_numbers_spaces_and_notes(self):
        regions = self.got["regions"]
        self.assertEqual(regions["Memory Tag 255"]["dirty_mb"], 41.6)
        self.assertEqual(regions["Memory Tag 255"]["swapped_mb"], 1.0)
        self.assertEqual(regions["Memory Tag 255"]["dirty_swapped_mb"], 42.6)
        self.assertEqual(regions["MALLOC_SMALL"]["dirty_swapped_mb"], 28.9)  # its row ends in a note
        self.assertEqual(regions["MALLOC_SMALL (empty)"]["dirty_mb"], 1.1)
        self.assertEqual(regions["unused but dirty shlib __DATA"]["dirty_mb"], 0.5)
        self.assertEqual(regions["PartitionAlloc"]["virtual_mb"], 12288.0)

    def test_drops_clean_and_totals(self):
        regions = self.got["regions"]
        for clean in ("__TEXT", "__LINKEDIT", "IOSurface", "STACK GUARD", "VM_ALLOCATE (reserved)"):
            self.assertNotIn(clean, regions)
        self.assertFalse(any(name.startswith("TOTAL") for name in regions))

    def test_largest_first(self):
        names = list(self.got["regions"])
        self.assertEqual(names[:3], ["Memory Tag 255", "MALLOC_SMALL", "PartitionAlloc"])

    def test_malloc_zones(self):
        zones = self.got["malloc_zones"]
        self.assertEqual(set(zones), {"DefaultMallocZone_0x100b18000", "QuartzCore_0x100c90000"})
        zone = zones["DefaultMallocZone_0x100b18000"]
        self.assertEqual((zone["dirty_swapped_mb"], zone["allocated_mb"], zone["frag_mb"], zone["frag_pct"]),
                         (33.0, 21.3, 11.7, 36.0))

    def test_empty_input(self):
        self.assertEqual(vr.parse_summary(""), {"physical_footprint_mb": None, "physical_footprint_peak_mb": None,
                                                "regions": {}, "malloc_zones": {}})


class Targets(unittest.TestCase):
    ROWS = [
        {"pid": 1, "kind": "app", "footprint_mb": 236.9, "command": "Contents/MacOS/cmux NEXT"},
        {"pid": 2, "kind": "cef-renderer", "footprint_mb": 122.2, "command": "renderer main"},
        {"pid": 3, "kind": "cef-renderer", "footprint_mb": 59.9, "command": "--extension-process"},
        {"pid": 4, "kind": "cef-renderer", "footprint_mb": 28.3, "command": "renderer spare"},
        {"pid": 5, "kind": "acpmux-daemon", "footprint_mb": 40.0, "command": "bin/acpmux daemon"},
        {"pid": 6, "kind": "acpmux-daemon", "footprint_mb": 37.1, "command": "bin/acpmux daemon --home chief"},
        {"pid": 7, "kind": "tui-daemon", "footprint_mb": 32.0, "command": "bin/cmux mcp serve"},
        {"pid": 8, "kind": "tui-daemon", "footprint_mb": 30.0, "command": "bin/cmux-tui __agent-host optchat-chief"},
        {"pid": 9, "kind": "cef-gpu", "footprint_mb": 60.0, "command": "gpu-process"},
    ]

    def test_picks(self):
        got = [(row["pid"], why) for row, why in vr.targets(self.ROWS)]
        self.assertEqual(got, [(1, "app"), (2, "cef-renderer-1"), (3, "cef-renderer-2"), (5, "acpmux-daemon"),
                               (6, "acpmux-daemon"), (7, "mcp-serve"), (8, "optchat-chief")])

    def test_cap(self):
        many = [{"pid": i, "kind": "acpmux-daemon", "footprint_mb": i, "command": ""} for i in range(20)]
        self.assertEqual(len(vr.targets(many)), vr.MAX_TARGETS)


class Breakdown(unittest.TestCase):
    def test_bounded(self):
        def wedged(cmd, **kw):
            self.assertEqual(kw["timeout"], vr.TIMEOUT_S)
            raise subprocess.TimeoutExpired(cmd, kw["timeout"])
        self.assertEqual(vr.breakdown(7, run=wedged), {"error": "vmmap timed out after 20 s"})

    def test_parsed(self):
        def ok(cmd, **kw):
            self.assertEqual(cmd, ["vmmap", "--summary", "7"])
            return subprocess.CompletedProcess(cmd, 0, FIXTURE, "")
        self.assertEqual(vr.breakdown(7, run=ok)["physical_footprint_mb"], 122.2)

    def test_failed(self):
        def denied(cmd, **kw):
            return subprocess.CompletedProcess(cmd, 1, "", "vmmap: task_for_pid failed")
        self.assertIn("task_for_pid", vr.breakdown(7, run=denied)["error"])


if __name__ == "__main__":
    unittest.main()
