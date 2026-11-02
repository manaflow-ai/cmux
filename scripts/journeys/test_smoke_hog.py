#!/usr/bin/env python3
"""Tests of smoke_hog.py's sizing and steering (pure functions; no memory is allocated, no sysctl is read).

The SMOKE ENV "no memory pressure (the hog)" of 2026-11-02 (builds dbfec5b8, 767c572c, f666c68b; 44 rounds on
cmux18/19/21/22/23): the hog stopped at its fixed cap of 0.9 x 16 GB = 14.25 GB about 4 s after its start, and the
kernel's free level went back up to 30-47 while swap grew only +6..8 GB: almost all the hog held was idle, and the
kernel swapped it. The rows below are from round 4 of tip-watcher-smoke-25346d489c33-20261102T090317Z-1 (cmux23, job
dbfec5b848c25b76512efc4e). A first fix that held more swappable memory (25 GB on cmux21, swap +16 GB) kept the level at 28-39 too: on macOS
only wired memory and the compressor lower the level, so the fix steers it with a wired part.

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
OPTS = argparse.Namespace(floor=12, target=16, resume=20, disk_reserve_gb=10.0)
# (held_mb, swap_used_mb, level) of the failed round: the hog at its cap, swap far from +15 GB, the level 34-47.
CMUX23_ROUND4 = [(14592, 5660.06, 35), (14592, 6647.25, 34), (14592, 7337.44, 35), (14592, 7521.31, 41),
                 (14592, 7521.31, 43), (14592, 7513.31, 47), (14592, 7520.69, 35), (14592, 7496.69, 39)]


def sample(level, vm_pressure=2, swap=0.0):
    return {"level": level, "vm_pressure": vm_pressure, "swap_used_mb": swap, "compressed_mb": None}


class Caps(unittest.TestCase):
    def test_the_swap_part_keeps_the_old_cap_and_the_wired_part_its_own(self):
        cap, wire_cap = hog.caps(M6_PHYSICAL, 0.9, 0.5, 13056700579)  # cmux21's vm.user_wire_limit
        self.assertEqual(cap * (hog.CHUNK >> 20), 14592)  # 14.25 GB, the cap every failed round stopped at
        self.assertEqual(wire_cap * (hog.CHUNK >> 20), 8192)  # half of physical memory (under 0.8 x the wire limit)
        _, wire_cap = hog.caps(M6_PHYSICAL, 0.9, 0.5, 4 * GIB)
        self.assertEqual(wire_cap * (hog.CHUNK >> 20), 3072)  # 0.8 x a smaller wire limit


class Plan(unittest.TestCase):
    def plan(self, s, held, wired=0, grown=False, disk=200 * GIB, critical_for=0.0, wire_ok=True, backing_off=False):
        cap, wire_cap = hog.caps(M6_PHYSICAL, 0.9, 0.5, None)
        return hog.plan(s, held, wired, cap, wire_cap, grown, disk, critical_for, wire_ok, OPTS, backing_off)

    def test_regression_at_the_old_cap_with_the_level_above_the_target_the_hog_wires(self):
        # Every sample of the failed cmux23 round: the old hog only held (len(chunks) >= cap) with the level at 34-47.
        for held_mb, swap, level in CMUX23_ROUND4:
            action, _ = self.plan(sample(level, swap=swap), held_mb // (hog.CHUNK >> 20))
            self.assertEqual(action, "wire", (held_mb, swap, level))
        # ... and the same when the swap target stopped the swap part first (cmux21, 25 GB of swappable memory).
        self.assertEqual(self.plan(sample(36), 40, grown=True)[0], "wire")

    def test_the_swap_part_grows_first_as_before(self):
        self.assertEqual(self.plan(sample(60), 10), ("grow", False))

    def test_the_wired_part_holds_at_the_target(self):
        self.assertEqual(self.plan(sample(16), 57, wired=12)[0], "hold")
        self.assertEqual(self.plan(sample(17), 57, wired=12)[0], "wire")
        self.assertEqual(self.plan(sample(30), 57, wired=32)[0], "hold")  # its cap: 8 GB
        self.assertEqual(self.plan(sample(30), 57, wire_ok=False)[0], "hold")  # an mlock was refused

    def test_at_the_floor_it_gives_memory_back_until_resume(self):
        self.assertEqual(self.plan(sample(12), 57, wired=20), ("free", True))
        self.assertEqual(self.plan(sample(16), 57, wired=19, backing_off=True), ("free", True))
        self.assertEqual(self.plan(sample(20), 57, wired=15, backing_off=True), ("wire", False))

    def test_critical_pressure_stops_the_growth_and_when_it_lasts_gives_memory_back(self):
        self.assertEqual(self.plan(sample(30, vm_pressure=4), 57, wired=5), ("hold", False))
        self.assertEqual(self.plan(sample(30, vm_pressure=4), 57, wired=5, critical_for=5.0), ("free", True))
        self.assertEqual(self.plan(sample(30, vm_pressure=4), 57, wired=4, backing_off=True), ("free", True))
        self.assertEqual(self.plan(sample(30, vm_pressure=2), 57, wired=3, backing_off=True), ("wire", False))

    def test_critical_pressure_stops_the_swap_part_too(self):
        self.assertEqual(self.plan(sample(30, vm_pressure=4), 40, critical_for=1.0), ("hold", False))

    def test_a_sample_without_a_level_changes_nothing(self):
        # Review of 1af4a7d7d70: a failed sysctl (likely at the edge) ended a back-off and grew the swap part.
        self.assertEqual(self.plan(sample(None, vm_pressure=None), 50, wired=10), ("hold", False))
        # ... but a back-off goes on giving memory back, and a nearly full disk (statvfs, not sysctl) starts one.
        self.assertEqual(self.plan(sample(None, vm_pressure=None), 50, wired=10, backing_off=True), ("free", True))
        self.assertEqual(self.plan(sample(None, vm_pressure=None), 50, wired=10, disk=4 * GIB), ("free", True))

    def test_a_nearly_full_disk_stops_the_growth_or_gives_memory_back(self):
        self.assertEqual(self.plan(sample(30), 40, disk=4 * GIB)[0], "free")
        self.assertEqual(self.plan(sample(30), 40, disk=8 * GIB)[0], "hold")

    def test_without_a_level_from_the_start_it_is_the_original_hog_and_never_wires(self):
        cap, _ = hog.caps(M6_PHYSICAL, 0.9, 0.5, None)
        blind = lambda held: hog.plan(sample(None, vm_pressure=None), held, 0, cap, 0, False, 200 * GIB, 0.0, True, OPTS,
                                      False, steered=False)
        self.assertEqual(blind(10)[0], "grow")
        self.assertEqual(blind(cap)[0], "hold")

    def test_nothing_held_nothing_to_free(self):
        self.assertEqual(self.plan(sample(5), 0)[0], "hold")


class Locker(unittest.TestCase):
    def test_a_wired_chunk_can_be_unlocked_and_closed(self):
        import mmap
        chunk = mmap.mmap(-1, 4 * hog.PAGE)
        locker = hog.Locker()
        buf, error = locker.lock(chunk)
        if buf is None:
            self.skipTest(f"mlock refused here: {error}")
        locker.unlock(chunk, buf)
        del buf
        chunk.close()  # no export is left


class Loop(unittest.TestCase):
    def test_main_steers_to_the_target_and_frees_everything_at_its_deadline(self):
        # main() with 1 MiB chunks and a fake kernel: level = 100 x (64 - 10 - wired - half the swap part (at most 20))
        # / 64. Every chunk it made is closed at the end, and the log has the start, the samples and the end row.
        import mmap as real_mmap
        live, wired_ids = [], set()

        class Chunk(bytearray):
            def __init__(self, fd, size):
                super().__init__(size)
                live.append(self)

            def close(self):
                live[:] = [c for c in live if c is not self]  # by identity, not by content

        class FakeLocker(object):
            def lock(self, chunk):
                wired_ids.add(id(chunk))
                return object(), None

            def unlock(self, chunk, buf):
                wired_ids.discard(id(chunk))

        def fake_sysctls(names):
            w = sum(1 for c in live if id(c) in wired_ids)
            level = int(100 * (64 - 10 - w - min((len(live) - w) * 0.5, 20)) / 64)
            values = {"hw.memsize": str(64 << 20), "vm.user_wire_limit": str(48 << 20), "kern.memorystatus_level": str(level),
                      "kern.memorystatus_vm_pressure_level": "2", "vm.swapusage": "used = 10.0M"}
            return {k: v for k, v in values.items() if k in names}

        import signal
        saved = (hog.CHUNK, hog.mmap.mmap, hog.Locker, hog.sysctls, hog.disk_free_bytes, hog.PACE_SECONDS, sys.argv)
        handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "hog.jsonl")
            try:
                hog.CHUNK, hog.mmap.mmap, hog.Locker, hog.sysctls = 1 << 20, Chunk, FakeLocker, fake_sysctls
                hog.disk_free_bytes, hog.PACE_SECONDS = (lambda path=None: 100 * GIB), 0.0
                sys.argv = ["smoke_hog.py", "--swap-gb", "15", "--deadline", str(__import__("time").time() + 3), "--log", path]
                hog.main()
            finally:
                hog.CHUNK, hog.mmap.mmap, hog.Locker, hog.sysctls, hog.disk_free_bytes, hog.PACE_SECONDS, sys.argv = saved
                for sig, handler in handlers.items():  # main() set its own: give the test process its handlers back
                    signal.signal(sig, handler)
            with open(path) as f:
                rows = [json.loads(line) for line in f]
        self.assertEqual(live, [])
        self.assertTrue(rows[0]["start"])
        self.assertEqual((rows[0]["cap_mb"], rows[0]["wire_cap_mb"]), (57, 32))
        end = rows[-1]
        self.assertTrue(end["released"])
        self.assertLessEqual(end["level_min"], 16)
        self.assertGreater(end["wired_mb_max"], 0)
        self.assertTrue(all(r.get("level", 0) > 12 for r in rows[1:-1]))  # it never went down to the floor
        self.assertIs(real_mmap.mmap, hog.mmap.mmap)
        self.assertEqual({sig: signal.getsignal(sig) for sig in handlers}, handlers)


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
            rows = [{"t": 0, "start": True, "cap_mb": 14592, "wire_cap_mb": 8192, "level": 80, "vm_pressure": 1}]
            rows += [{"t": i, "held_mb": 256 * i, "swap_used_mb": 400.0 + 100 * i, "level": max(14, 40 - i),
                      "vm_pressure": 2 if i < 30 else 4, "action": "grow", "wired_mb": 64 * i} for i in range(40)]
            rows.append({"t": 41, "held_mb": 0, "released": True, "level_min": 14, "vm_pressure_max": 4})
            Path(tmp, "hog-cmux99.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
            p = gate.pressure(Path(tmp), 15.0)
        self.assertTrue(p["ok"])
        self.assertEqual(p["samples"], 41)  # the start row is no sample; the released row is one, as before
        self.assertEqual((p["level_min"], p["vm_pressure_max"], p["hog_cap_gb"], p["wired_gb_max"]), (14, 4, 14.25, 2.44))


if __name__ == "__main__":
    unittest.main()
