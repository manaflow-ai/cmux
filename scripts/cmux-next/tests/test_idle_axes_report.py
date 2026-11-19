#!/usr/bin/env python3
"""perf-10x-idle axes= (CMUX-672): the per-item marginal cost, the disk bytes and the GPU summary.

idle_axes_report.py turns bench_memory.py --axis reports into the marginal cost of one more item per process
group; bench_memory.disk_io reads RUSAGE_INFO_V4's disk words (18 read, 19 written, 29 logical writes) and
gpu_summary averages ioreg's PerformanceStatistics. Off macOS the libproc handle is a stub the test fills."""

from __future__ import annotations

import ctypes
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import idle_axes_report as report  # noqa: E402

if sys.platform == "darwin":
    import bench_memory as bm  # noqa: E402
else:
    with mock.patch.object(ctypes, "CDLL", mock.MagicMock()):
        import bench_memory as bm  # noqa: E402


def sample(label, items, renderer_mb, acpmux_cpu, disk_w):
    return {"label": label, "items": items, "kinds": {
        "app": {"count": 1, "footprint_mb": 200.0, "rss_mb": 250.0, "cpu_pct": 0.5, "wakeups_per_s": 10.0,
                "disk_write_mb_per_h": 1.0, "disk_read_mb_per_h": 0.0},
        "cef-renderer": {"count": 2, "footprint_mb": renderer_mb, "rss_mb": renderer_mb, "cpu_pct": 0.1,
                         "wakeups_per_s": 2.0, "disk_write_mb_per_h": 0.0, "disk_read_mb_per_h": 0.0},
        "acpmux-daemon": {"count": 1, "footprint_mb": 20.0, "rss_mb": 25.0, "cpu_pct": acpmux_cpu,
                          "wakeups_per_s": 1.0, "disk_write_mb_per_h": disk_w, "disk_read_mb_per_h": 0.5}}}


class IdleAxesReportTest(unittest.TestCase):
    def test_marginal_is_the_slope_per_item_by_group(self):
        # Each hidden chat adds 3 MB of renderer and 0.01 % acpmux CPU at first; settled, 0.5 MB and nothing.
        axis = {"axis": "chat-hidden", "axis_made": {"10": 10, "100": 100}, "samples": [
            sample("idle-launch", 0, 100.0, 0.2, 2.0),
            sample("items-10", 10, 130.0, 0.3, 4.0),
            sample("settled-10", 10, 105.0, 0.2, 2.0),
            sample("items-100", 100, 400.0, 1.2, 22.0),
            sample("settled-100", 100, 150.0, 0.2, 2.0)]}
        got = report.summarize([axis])["axes"][0]["phases"]
        self.assertAlmostEqual(got["items"]["marginal_per_item"]["cef-renderer"]["footprint_mb"], 3.0, places=3)
        self.assertAlmostEqual(got["items"]["marginal_per_item"]["acpmux"]["cpu_pct"], 0.01, places=4)
        self.assertAlmostEqual(got["items"]["marginal_per_item"]["total"]["disk_write_mb_per_h"], 0.2, places=3)
        self.assertAlmostEqual(got["settled"]["marginal_per_item"]["cef-renderer"]["footprint_mb"], 0.5, places=3)
        self.assertAlmostEqual(got["settled"]["marginal_per_item"]["acpmux"]["cpu_pct"], 0.0, places=4)
        text = report.markdown(report.summarize([axis]))
        self.assertIn("| chat-hidden | items | 3.00 |", text)
        self.assertIn("| settled-100 | 100 | cef-renderer | 2 | 150.0 |", text)

    def test_groups(self):
        self.assertEqual(report.group_of("acpmux-daemon"), "acpmux")
        self.assertEqual(report.group_of("tui-daemon"), "cmux-tui")
        self.assertEqual(report.group_of("terminal-host"), "terminal-hosts")
        self.assertEqual(report.group_of("cef-utility"), "cef-other")
        self.assertEqual(report.group_of("cef-gpu"), "cef-gpu")

    def test_one_count_has_no_slope(self):
        self.assertIsNone(report.slope([(0, 1.0), (0, 2.0)]))


class DiskAndGpuTest(unittest.TestCase):
    def test_disk_io_reads_rusage_v4_disk_words(self):
        def fill(_pid, _flavor, ref):
            buf = ref._obj
            buf[18], buf[19], buf[29] = 4096, 8192, 12288
            return 0
        with mock.patch.object(bm._libproc, "proc_pid_rusage", side_effect=fill):
            self.assertEqual(bm.disk_io(1), (4096, 8192, 12288))
        with mock.patch.object(bm._libproc, "proc_pid_rusage", return_value=-1):
            self.assertIsNone(bm.disk_io(1))

    def test_gpu_summary_means(self):
        got = bm.gpu_summary([{"Device Utilization %": 2, "In use system memory": 100 * 1048576},
                              {"Device Utilization %": 4, "In use system memory": 300 * 1048576}])
        self.assertEqual(got["device_utilization_pct"], 3.0)
        self.assertEqual(got["in_use_system_memory_mb"], 200.0)
        self.assertIn("error", bm.gpu_summary([]))

    def test_page_frames_window_sums_by_visibility(self):
        # Page 0 visible at 60 frames/s; page 1 hidden and still beating, no frames; page 2 frozen (no beat).
        before = {0: {"raf": 100, "vis": "visible", "at": 1.0}, 1: {"raf": 50, "vis": "hidden", "at": 1.0},
                  2: {"raf": 70, "vis": "hidden", "at": 1.0}}
        after = {0: {"raf": 700, "vis": "visible", "at": 11.0}, 1: {"raf": 50, "vis": "hidden", "at": 11.0},
                 2: {"raf": 70, "vis": "hidden", "at": 1.0}}
        got = bm.PageFrames.window(before, after, 10.0)
        self.assertEqual(got["visible"], {"pages": 1, "frames_per_s": 60.0, "max_page_frames_per_s": 60.0, "reporting": 1})
        self.assertEqual(got["hidden"], {"pages": 2, "frames_per_s": 0.0, "max_page_frames_per_s": 0.0, "reporting": 1})

    def test_page_axis_reports_frames_priorities_and_show_latency(self):
        def page_sample(label, items, hidden_fps):
            s = sample(label, items, 100.0 + items, 0.1, 0.0)
            s["kinds"]["cef-renderer"]["priorities"] = {"47": {"n": 1, "cpu_pct": 0.1}, "28": {"n": items, "cpu_pct": 0.0}}
            s["page_frames"] = {"hidden": {"pages": items, "frames_per_s": hidden_fps, "max_page_frames_per_s": 0.0,
                                           "reporting": items}}
            return s
        axis = {"axis": "page-hidden", "samples": [sample("idle-launch", 0, 100.0, 0.1, 0.0),
                                                   page_sample("items-10", 10, 0.0)],
                "show_latency": [{"page": 0, "first_frame_ms": 42.0}]}
        lines = report.page_lines(axis)
        self.assertIn('renderer_priorities={"47":{"n":1', lines[1])
        self.assertEqual(lines[-1], 'page-hidden show_latency=[{"page":0,"first_frame_ms":42.0}]')
        text = report.markdown(report.summarize([axis]))
        self.assertIn("| items-10 | 10 | hidden: 10 pages 0.00/s (max 0.00) | 47: 1 (0.100 %); 28: 10 (0.000 %) |", text)
        self.assertIn("Show latency, request to first frame (ms): 42", text)


if __name__ == "__main__":
    unittest.main()
