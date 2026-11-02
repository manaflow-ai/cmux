#!/usr/bin/env python3
"""Tests of smoke_hog.py's sizing and steering (pure functions; no memory is allocated, no sysctl is read).

The SMOKE ENV "no memory pressure (the hog)" of 2026-11-02 (builds dbfec5b8, 767c572c, f666c68b; 44 rounds on
cmux18/19/21/22/23): the hog stopped at its fixed cap of 0.9 x 16 GB = 14.25 GB about 4 s after its start, and the
kernel's free level went back up to 30-47 while swap grew only +6..8 GB. The rows below are from round 4 of
tip-watcher-smoke-25346d489c33-20261102T090317Z-1 (cmux23, job dbfec5b848c25b76512efc4e).

    python3 -m unittest test_smoke_hog
"""
import argparse
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("smoke_hog", HERE / "smoke_hog.py")
hog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hog)

GIB = 1 << 30
M6_PHYSICAL = 16 * GIB
OPTS = argparse.Namespace(floor=12, resume=20, disk_reserve_gb=10.0)
# (held_mb, swap_used_mb, level) of the failed round: the hog at its cap, swap far from +15 GB, the level 34-47.
CMUX23_ROUND4 = [(14592, 5660.06, 35), (14592, 6647.25, 34), (14592, 7337.44, 35), (14592, 7521.31, 41),
                 (14592, 7521.31, 43), (14592, 7513.31, 47), (14592, 7520.69, 35), (14592, 7496.69, 39)]
CMUX23_SWAP_START = 390.81


def sample(level, vm_pressure=2, swap=0.0):
    return {"level": level, "vm_pressure": vm_pressure, "swap_used_mb": swap, "compressed_mb": None}


class Caps(unittest.TestCase):
    def test_the_old_cap_is_kept_as_the_soft_cap(self):
        soft, _ = hog.caps(M6_PHYSICAL, 0.9, 15, 200 * GIB, 10)
        self.assertEqual(soft * (hog.CHUNK >> 20), 14592)  # 14.25 GB: the cap every failed round stopped at

    def test_the_hard_cap_adds_the_swap_target_less_the_disk_reserve(self):
        soft, hard = hog.caps(M6_PHYSICAL, 0.9, 15, 200 * GIB, 10)
        self.assertEqual(hard - soft, 15 * 4)  # 15 GB of 256 MiB chunks
        _, hard = hog.caps(M6_PHYSICAL, 0.9, 15, 18 * GIB, 10)
        self.assertEqual(hard - soft, 8 * 4)  # only 18 - 10 GB of disk may go to swap
        _, hard = hog.caps(M6_PHYSICAL, 0.9, 15, 5 * GIB, 10)
        self.assertEqual(hard, soft)  # less free disk than the reserve: never past physical memory


class Plan(unittest.TestCase):
    def plan(self, s, held, grown=False, disk=200 * GIB, backing_off=False):
        soft, hard = hog.caps(M6_PHYSICAL, 0.9, 15, 200 * GIB, 10)
        return hog.plan(s, held, soft, hard, grown, disk, OPTS, backing_off)

    def test_regression_at_the_old_cap_with_no_pressure_the_hog_grows(self):
        # Every sample of the failed cmux23 round: the old hog held (len(chunks) >= cap) with the level above 20.
        for held_mb, swap, level in CMUX23_ROUND4:
            grown = swap - CMUX23_SWAP_START >= 15 * 1024
            action, _ = self.plan(sample(level, swap=swap), held_mb // (hog.CHUNK >> 20), grown=grown)
            self.assertEqual(action, "grow", (held_mb, swap, level))

    def test_at_the_floor_it_gives_memory_back_until_resume(self):
        self.assertEqual(self.plan(sample(12), 70), ("free", True))
        self.assertEqual(self.plan(sample(16), 69, backing_off=True), ("free", True))
        self.assertEqual(self.plan(sample(20), 60, backing_off=True), ("grow", False))
        self.assertEqual(self.plan(sample(16), 60), ("grow", False))  # within the band, not backing off: it may grow

    def test_critical_pressure_or_a_nearly_full_disk_gives_memory_back(self):
        self.assertEqual(self.plan(sample(30, vm_pressure=4), 60)[0], "free")
        self.assertEqual(self.plan(sample(30), 60, disk=4 * GIB)[0], "free")
        self.assertEqual(self.plan(sample(30), 60, disk=8 * GIB)[0], "hold")  # under the reserve: no more growth

    def test_the_swap_target_and_the_hard_cap_stop_the_growth(self):
        _, hard = hog.caps(M6_PHYSICAL, 0.9, 15, 200 * GIB, 10)
        self.assertEqual(self.plan(sample(30), 60, grown=True)[0], "hold")
        self.assertEqual(self.plan(sample(30), hard)[0], "hold")

    def test_without_a_level_it_never_goes_past_physical_memory(self):
        soft, _ = hog.caps(M6_PHYSICAL, 0.9, 15, 200 * GIB, 10)
        self.assertEqual(self.plan(sample(None, vm_pressure=None), soft - 1)[0], "grow")
        self.assertEqual(self.plan(sample(None, vm_pressure=None), soft)[0], "hold")

    def test_nothing_held_nothing_to_free(self):
        self.assertEqual(self.plan(sample(5), 0)[0], "hold")


class Sysctl(unittest.TestCase):
    def test_swapusage_text(self):
        self.assertEqual(hog.parse_swap_used_mb("total = 3072.00M  used = 1802.25M  free = 1269.75M  (encrypted)"), 1802.25)
        self.assertEqual(hog.parse_swap_used_mb(""), 0.0)


class GateReadsTheHogRecord(unittest.TestCase):
    def test_pressure_shows_the_kernel_level_and_the_cap(self):
        spec = importlib.util.spec_from_file_location("smoke_gate", HERE / "smoke-gate.py")
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        with tempfile.TemporaryDirectory() as tmp:
            rows = [{"t": 0, "start": True, "cap_mb": 29952, "level": 80, "vm_pressure": 1}]
            rows += [{"t": i, "held_mb": 14592 + 256 * i, "swap_used_mb": 400.0 + 100 * i, "level": max(14, 40 - i),
                      "vm_pressure": 2 if i < 30 else 4, "action": "grow"} for i in range(40)]
            rows.append({"t": 41, "held_mb": 0, "released": True, "level_min": 14, "vm_pressure_max": 4})
            Path(tmp, "hog-cmux99.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
            p = gate.pressure(Path(tmp), 15.0)
        self.assertTrue(p["ok"])
        self.assertEqual(p["samples"], 41)  # the start row is no sample; the released row is one, as before
        self.assertEqual((p["level_min"], p["vm_pressure_max"], p["hog_cap_gb"]), (14, 4, 29.25))


if __name__ == "__main__":
    unittest.main()
