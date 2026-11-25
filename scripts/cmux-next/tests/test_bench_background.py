#!/usr/bin/env python3
"""bench_background.py: the background daemon CPU a bench round records (a reader drops a round over its limit).

Runs on any host (Linux included): no app, no fleet, no ps.

    python3 -m unittest scripts/cmux-next/tests/test_bench_background.py
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import bench_background  # noqa: E402


class ParseCpuTimeTests(unittest.TestCase):
    def test_every_ps_time_shape(self):
        parse = bench_background.parse_cpu_time
        self.assertEqual(parse("0:00.50"), 0.5)
        self.assertEqual(parse("12:34.25"), 12 * 60 + 34.25)
        self.assertEqual(parse("1:02:03"), 3600 + 120 + 3)
        self.assertEqual(parse("7.5"), 7.5)

    def test_days_are_whole_days_not_sixty_hours(self):
        # The scratch sampler turned "2-03:04:05" into "2:03:04:05" and counted a day as 60 hours.
        self.assertEqual(bench_background.parse_cpu_time("2-03:04:05"), 2 * 86400 + 3 * 3600 + 4 * 60 + 5)

    def test_a_bad_field_is_none_not_zero(self):
        for bad in ("", "x:10", "1:y", "a-01:00:00"):
            self.assertIsNone(bench_background.parse_cpu_time(bad), bad)


class ParsePsTests(unittest.TestCase):
    PS = """  101   12:34.25 /System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Support/mds
  102    0:01.50 /System/Library/PrivateFrameworks/MediaAnalysis.framework/Versions/A/mediaanalysisd
  103    5:00.00 /Applications/cmux NEXT.app/Contents/MacOS/cmux NEXT
  104   bad-time /usr/libexec/mds_stores
  105 1-00:00:00 mdworker_shared
"""

    def test_only_the_daemons_with_a_readable_time(self):
        found = bench_background.parse_ps(self.PS)
        self.assertEqual(found, {"101": ("mds", 754.25), "102": ("mediaanalysisd", 1.5),
                                 "105": ("mdworker_shared", 86400.0)})


class DeltaTests(unittest.TestCase):
    def test_used_seconds_per_name_and_the_limit(self):
        before = {"1": ("mds", 10.0), "2": ("mediaanalysisd", 3.0)}
        after = {"1": ("mds", 10.4), "2": ("mediaanalysisd", 3.9), "3": ("mdworker_shared", 0.2)}
        d = bench_background.delta(before, after)
        self.assertEqual(d["by_name"], {"mds": 0.4, "mediaanalysisd": 0.9, "mdworker_shared": 0.2})
        self.assertEqual(d["total_s"], 1.5)
        self.assertTrue(d["over_limit"])

    def test_a_quiet_round_is_under_the_limit_and_an_ended_pid_counts_nothing(self):
        before = {"1": ("mds", 10.0), "9": ("mediaanalysisd", 50.0)}
        after = {"1": ("mds", 10.3)}
        d = bench_background.delta(before, after)
        self.assertEqual((d["total_s"], d["over_limit"], d["limit_s"]), (0.3, False, 1.0))


if __name__ == "__main__":
    unittest.main()
