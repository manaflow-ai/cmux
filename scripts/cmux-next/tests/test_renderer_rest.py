#!/usr/bin/env python3
"""renderer-rest.py (split-spring --suite=renderer-rest) names each Chromium renderer by the pages it hosts and says
whether its footprint levels off at rest. Pure functions only: no app, runs on Linux."""

from __future__ import annotations

import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("renderer_rest", os.path.join(HERE, "..", "renderer-rest.py"))
rr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rr)


class RendererRestTests(unittest.TestCase):
    def test_roles_by_pid_names_pages_and_spare_renderers(self):
        pages = [{"origin": "cmux-page://home", "path": "/", "renderer_clients": [3]},
                 {"origin": "cmux-page://agent", "path": "/chat", "hidden": True, "renderer_clients": [3]},
                 {"origin": "https://example.com", "renderer_clients": [5]}]
        renderers = {101: "Helper --type=renderer --renderer-client-id=3 --lang=en",
                     102: "Helper --type=renderer --renderer-client-id=5",
                     103: "Helper --type=renderer --renderer-client-id=9"}
        self.assertEqual(rr.roles_by_pid(pages, renderers),
                         {101: "agent/chat (hidden) + home", 102: "browser-tab", 103: "no page"})

    def test_growth_after_60s_reads_a_plateau_as_zero_and_a_leak_as_its_slope(self):
        flat = [(t, 300.0 if t >= 60 else 200.0 + t) for t in range(0, 181, 5)]
        leak = [(t, 300.0 + t / 6) for t in range(0, 181, 5)]  # 10 MB a minute
        self.assertEqual(rr.growth_per_min(flat), 0.0)
        self.assertEqual(rr.growth_per_min(leak), 10.0)
        self.assertIsNone(rr.growth_per_min([(0, 1.0), (70, 2.0)]))

    def test_summarize_and_rows(self):
        timeline = [{"t": t, "renderers": [{"pid": 7, "role": "home", "footprint_mb": 280.0 + t / 3,
                                            "page_metrics": [{"JSHeapUsedSize": 20 * rr.MB, "Nodes": 900}]}]}
                    for t in range(5, 181, 5)]
        summary = rr.summarize(timeline)["7"]
        self.assertEqual(summary["roles"], ["home"])
        self.assertAlmostEqual(summary["at20_mb"], 280 + 20 / 3)
        self.assertEqual(summary["growth_after_60s_mb_per_min"], 20.0)
        self.assertEqual(summary["js_heap_mb"]["end"], 20.0)
        rows = {r["name"]: r["p50"] for r in rr.rows_from([{"timeline": timeline}] * 3)}
        self.assertEqual(rows["memory.renderer_rest.cef_renderer_growth_after_60s_mb_per_min"], 20.0)

    def test_vmmap_regions_reads_dirty_plus_swapped(self):
        text = ("REGION TYPE                        SIZE    SIZE    SIZE    SIZE  COUNT\n"
                "MALLOC_SMALL                      40.0M   12.5M   10.0M    2.0M     5\n"
                "PartitionAlloc                   300.0M   90.0M   80.0M  512K      9\n"
                "TOTAL                             1.0G    200M    150M    10M    100\n")
        self.assertEqual(rr.vmmap_regions(text), {"PartitionAlloc": 80.5, "MALLOC_SMALL": 12.0})

    def test_sampling_top_sums_self_size_by_frame(self):
        node = {"callFrame": {"functionName": "", "url": ""}, "selfSize": 0, "children": [
            {"callFrame": {"functionName": "tick", "url": "cmux-page://home/app.js", "lineNumber": 4}, "selfSize": 2 * rr.MB},
            {"callFrame": {"functionName": "tick", "url": "cmux-page://home/app.js", "lineNumber": 4}, "selfSize": rr.MB}]}
        self.assertEqual(rr.sampling_top({"head": node}), [{"frame": "tick app.js:4", "mb": 3.0}])


if __name__ == "__main__":
    unittest.main()
