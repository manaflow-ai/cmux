#!/usr/bin/env python3
"""bench_memory --idle-minutes/--soak-vm: the growth between idle-launch and the last soak sample, and which two
processes soak_vm reads (the app and the largest Chromium renderer). CMUX-571: what grows over uptime."""
from __future__ import annotations

import ctypes
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
if sys.platform == "darwin":
    import bench_memory as bm  # noqa: E402
else:
    with mock.patch.object(ctypes, "CDLL", mock.MagicMock()):
        import bench_memory as bm  # noqa: E402


def sample(app, big, small):
    return {"total_footprint_mb": app + big + small,
            "kinds": {"app": {"footprint_mb": app}, "cef-renderer": {"footprint_mb": big + small}},
            "processes": [{"pid": 2, "kind": "cef-renderer", "footprint_mb": big},
                          {"pid": 1, "kind": "app", "footprint_mb": app},
                          {"pid": 3, "kind": "cef-renderer", "footprint_mb": small}]}


class SoakTest(unittest.TestCase):
    def test_growth_by_kind_largest_first(self):
        got = bm.soak_growth(sample(266, 100, 30), sample(300, 160, 31))
        self.assertEqual(got, {"total": 95.0, "cef-renderer": 61.0, "app": 34.0})
        self.assertEqual(list(got), ["total", "cef-renderer", "app"])

    def test_soak_vm_reads_the_app_and_the_largest_renderer_only(self):
        with mock.patch.object(bm, "app_vm", side_effect=lambda pid: {"vmmap": {"lines": [f"pid {pid}"]}}) as vm:
            got = bm.soak_vm(sample(266, 100, 30), "soak-10m")
        self.assertEqual(sorted(call.args[0] for call in vm.call_args_list), [1, 2])
        self.assertEqual(got["cef-renderer"]["pid"], 2)
        self.assertEqual(got["app"]["pid"], 1)


if __name__ == "__main__":
    unittest.main()
