#!/usr/bin/env python3
"""wallpaper-cost.py's readers on stand-in ps, nettop and netstat output, and its Markdown table.

bench_memory.py needs macOS's libproc, so a stand-in module takes its place. The checks: ps CPU times in every form;
nettop's delta samples summed per pid with the first (total-so-far) sample left out; netstat's link rows summed over
non-loopback interfaces, an interface with no address included; the cost groups; p95; one table row per phase.
Run: python3 -I scripts/measure/tests/wallpaper-cost.test.py
"""
import importlib.util
import sys
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load():
    sys.modules["bench_memory"] = types.ModuleType("bench_memory")
    spec = importlib.util.spec_from_file_location("wallpaper_cost", HERE.parent / "wallpaper-cost.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


WC = load()

NETTOP = """,bytes_in,bytes_out,
com.apple.WebKit.Networking.500,9000000,4000,
cmux DEV wallpapercost.100,100,10,
,bytes_in,bytes_out,
com.apple.WebKit.Networking.500,250000,1000,
cmux DEV wallpapercost.100,0,0,
launchd.1,0,0,
,bytes_in,bytes_out,
com.apple.WebKit.Networking.500,150000,500,
mDNSResponder.300,40,20,
"""

NETSTAT = """Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
lo0        16384 <Link#1>                         1000     0     500000     1000     0     500000     0
en0        1500  <Link#6>    aa:bb:cc:dd:ee:ff    2000     0    3000000     1500     0     200000     0
en0        1500  10.0.0/24     10.0.0.5           2000     -    3000000     1500     -     200000     -
utun0      1380  <Link#20>                          10     0       4000       12     0       5000     0
"""


class Readers(unittest.TestCase):
    def test_cpu_time_forms(self):
        self.assertEqual(WC.parse_cpu_time("0:01.50"), 1.5)
        self.assertEqual(WC.parse_cpu_time("1:02:03"), 3723)
        self.assertEqual(WC.parse_cpu_time("2-00:00:01"), 2 * 86400 + 1)
        self.assertIsNone(WC.parse_cpu_time("x"))
        self.assertEqual(WC.parse_ps_times("  88 12:00.25\n 99 0:00.01\nbad line here\n"), {88: 720.25, 99: 0.01})

    def test_nettop_skips_the_first_sample(self):
        got = WC.parse_nettop(NETTOP)
        self.assertEqual(got[500], [400000, 1500])
        self.assertEqual(got[100], [0, 0])
        self.assertEqual(got[300], [40, 20])
        self.assertEqual(WC.parse_nettop(""), {})

    def test_netstat_link_rows_without_loopback(self):
        self.assertEqual(WC.parse_netstat(NETSTAT), (3000000 + 4000, 200000 + 5000))
        self.assertEqual(WC.parse_netstat("nonsense"), (0, 0))

    def test_groups_and_p95(self):
        self.assertEqual(WC.group_of("app"), "app")
        self.assertEqual(WC.group_of("webkit-webcontent"), "webkit")
        self.assertEqual(WC.group_of("tui-daemon"), "other")
        self.assertEqual(WC.p95(list(range(101))), 95)
        self.assertIsNone(WC.p95([]))

    def test_table(self):
        rows = [{"phase": "picture", "id": "art", "state": "none", "cpu_s_per_s": 0.004, "gpu_s_per_s": 0.0,
                 "footprint_mb": 212.4},
                {"phase": "video", "id": "video-4k60", "state": "none", "cpu_s_per_s": 0.02, "tree_cpu_s_per_s": 0.06,
                 "tree_cpu_p95_s_per_s": 0.08, "gpu_util_pct": 11.5, "gpu_util_p95_pct": 14.0, "net_in_kb_per_s": None}]
        lines = WC.markdown(rows).splitlines()
        self.assertEqual(len(lines), 4)
        self.assertIn("| video | video-4k60 | none | 2.0 | 6.0 (8.0) |", lines[3])
        self.assertIn("11.5 (14.0)", lines[3])
        self.assertIn("| picture | art | none | 0.4 | - (-) |", lines[2])


if __name__ == "__main__":
    unittest.main()
