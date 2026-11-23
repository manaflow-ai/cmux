#!/usr/bin/env python3
"""memory-agents-cron.py says where the app's memory is: per process kind empty and with N chats, each kind's cost
per chat workspace (N - 1: the launch workspace counts in N), and the cmux pages' V8 heap; those rows are shown, never
judged (perf-cron.py REPORT_ONLY_ROW_RE). bench_memory.heap_summary counts each renderer's V8 isolate once (every page of a renderer answers the whole isolate).
Pure functions only: no app, runs on Linux."""

from __future__ import annotations

import ctypes
import importlib.util
import os
import sys
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, "..", file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


cron = load("memory_agents_cron", "memory-agents-cron.py")
perf_cron = load("perf_cron", "perf-cron.py")
if sys.platform == "darwin":
    import bench_memory as bm  # noqa: E402
else:
    with mock.patch.object(ctypes, "CDLL", mock.MagicMock()):
        import bench_memory as bm  # noqa: E402

MB = 1048576


def sample(label, workspaces, kinds, js_heap=None, failures=0):
    s = {"label": label, "workspaces": workspaces, "pane_failures": failures,
         "total_footprint_mb": round(sum(v for _, v in kinds.values()), 1),
         "kinds": {k: {"count": n, "footprint_mb": v, "rss_mb": v} for k, (n, v) in kinds.items()},
         "processes": [{"kind": k, "pid": 100 + i, "footprint_mb": v} for i, (k, (_, v)) in enumerate(kinds.items())]}
    if js_heap is not None:
        s["js_heap"] = js_heap
    return s


EMPTY = sample("idle-launch", 1, {"app": (1, 400.0), "cef-renderer": (2, 300.0), "cef-gpu": (1, 150.0),
                                  "tui-daemon": (1, 40.0), "acpmux-daemon": (1, 19.1), "cef-utility": (1, 0.4)},
               js_heap={"pages": 2, "used_mb": 30.0, "total_mb": 40.0, "by_path": {}})
TEN = sample("idle-10", 10, {"app": (1, 490.0), "cef-renderer": (4, 750.0), "cef-gpu": (1, 159.0),
                             "tui-daemon": (1, 58.0), "terminal-host": (9, 225.0), "acpmux-daemon": (1, 43.7),
                             "cef-utility": (1, 0.5)},
             js_heap={"pages": 11, "used_mb": 210.0, "total_mb": 265.0, "by_path": {}})


class BreakdownTests(unittest.TestCase):
    def test_per_chat_divides_by_the_chat_workspaces_not_n(self):
        out, rows = cron.breakdown_from({"samples": [EMPTY, TEN]})
        per_chat = out["per_chat"]
        self.assertEqual(per_chat["chats"], 9)
        self.assertEqual(per_chat["total_mb"], round((TEN["total_footprint_mb"] - EMPTY["total_footprint_mb"]) / 9, 1))
        self.assertEqual(per_chat["kinds"]["cef-renderer"], 50.0)
        self.assertEqual(per_chat["kinds"]["terminal-host"], 25.0)
        self.assertEqual(per_chat["kinds"]["app"], 10.0)
        self.assertEqual(per_chat["js_heap_total_mb"], 25.0)
        self.assertEqual(next(iter(per_chat["kinds"])), "cef-renderer", "largest per-chat kind first")
        names = {r["name"]: r["p95"] for r in rows}
        self.assertEqual(names["memory.app_agents.breakdown.per_chat.cef-renderer.footprint_mb"], 50.0)
        self.assertEqual(names["memory.app_agents.breakdown.empty.app.footprint_mb"], 400.0)
        self.assertEqual(names["memory.app_agents.breakdown.10.terminal-host.footprint_mb"], 225.0)
        self.assertEqual(names["memory.app_agents.breakdown.10.js_heap_total_mb"], 265.0)

    def test_small_kinds_fold_into_other(self):
        out, rows = cron.breakdown_from({"samples": [EMPTY, TEN]})
        self.assertNotIn("cef-utility", out["empty"]["kinds"])
        self.assertEqual(out["empty"]["kinds"]["other"], 0.4)
        self.assertFalse(any("cef-utility" in r["name"] for r in rows))

    def test_kinds_sum_to_the_judged_total(self):
        out, _ = cron.breakdown_from({"samples": [EMPTY, TEN]})
        for key in ("empty", "10"):
            self.assertAlmostEqual(sum(out[key]["kinds"].values()), out[key]["total_footprint_mb"], places=1)

    def test_partial_count_gets_no_breakdown_rows(self):
        partial = dict(TEN, workspaces=7)
        out, rows = cron.breakdown_from({"samples": [EMPTY, partial]})
        self.assertNotIn("per_chat", out)
        self.assertFalse(any(".10." in r["name"] for r in rows))
        out, rows = cron.breakdown_from({"samples": [EMPTY, dict(TEN, pane_failures=1)]})
        self.assertNotIn("per_chat", out)

    def test_no_empty_sample_no_breakdown(self):
        self.assertEqual(cron.breakdown_from({"samples": [TEN]}), ({}, []))
        self.assertEqual(cron.breakdown_from({}), ({}, []))

    def test_no_heap_no_heap_rows(self):
        bare = [dict(EMPTY), dict(TEN)]
        for s in bare:
            s.pop("js_heap")
        out, rows = cron.breakdown_from({"samples": bare})
        self.assertNotIn("js_heap_total_mb", out["per_chat"])
        self.assertFalse(any("js_heap" in r["name"] for r in rows))

    def test_kind_names_are_row_safe(self):
        self.assertEqual(cron.row_key("com.apple.WebKit Helper (GPU)"), "com_apple_webkit_helper_gpu", "a dot would split the row name")
        self.assertEqual(cron.row_key(""), "unknown")

    def test_breakdown_rows_are_report_only_and_the_goal_rows_are_judged(self):
        _, rows = cron.breakdown_from({"samples": [EMPTY, TEN]})
        self.assertTrue(rows)
        for r in rows:
            self.assertTrue(perf_cron.REPORT_ONLY_ROW_RE.match(r["name"]), r["name"])
        for r in cron.rows_from({"samples": [EMPTY, TEN]}):
            self.assertFalse(perf_cron.REPORT_ONLY_ROW_RE.match(r["name"]), r["name"])
        self.assertTrue(perf_cron.REPORT_ONLY_ROW_RE.match("terminal.throughput.ratio"))

    def test_breakdown_rows_belong_to_the_memory_agents_part(self):
        _, rows = cron.breakdown_from({"samples": [EMPTY, TEN]})
        self.assertEqual(perf_cron.part_for_row(rows[0]["name"]), "memory-agents")


class AppVmTests(unittest.TestCase):
    """ram-baseline (CMUX-571): every memory-agents run stores the empty app process's own split."""

    def args(self, *extra):
        import argparse
        ns = argparse.Namespace(app="/A.app", agents="10", settle="20", measure="30", no_app_vm=False, app_vm_stacks=None)
        for k, v in extra:
            setattr(ns, k, v)
        return ns

    def test_every_run_asks_for_the_app_process_split(self):
        self.assertIn("--app-vm", cron.bench_cmd(self.args(), "/r.json"))

    def test_no_app_vm_leaves_it_out(self):
        self.assertNotIn("--app-vm", cron.bench_cmd(self.args(("no_app_vm", True)), "/r.json"))

    def test_stacks_pass_their_pattern(self):
        cmd = cron.bench_cmd(self.args(("no_app_vm", True), ("app_vm_stacks", "Palette")), "/r.json")
        self.assertIn("--app-vm", cmd)
        self.assertEqual(cmd[cmd.index("--app-vm-stacks") + 1], "Palette")

    def test_the_part_stores_the_empty_samples_split(self):
        import json
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            raw = {"samples": [dict(EMPTY, app_vm={"vmmap": {"rc": 0, "lines": ["MALLOC_SMALL 40M"]}}), TEN]}

            def fake_run(cmd, cwd=None):
                with open(cmd[cmd.index("--out") + 1], "w") as f:
                    json.dump(raw, f)
                return mock.Mock(returncode=0)

            out = os.path.join(d, "report.json")
            with mock.patch.object(cron.subprocess, "run", side_effect=fake_run):
                cron.main(["--app", "/A.app", "--json", out, "--out", d])
            with open(out) as f:
                self.assertEqual(json.load(f)["app_vm"]["vmmap"]["lines"], ["MALLOC_SMALL 40M"])


class HeapSummaryTests(unittest.TestCase):
    def test_counts_each_renderer_isolate_once_and_counts_errors(self):
        # Pages 1 and 2 share renderer 7 (process-per-site): each answers the renderer's whole isolate.
        pages = [{"browser": 1, "origin": "cmux-page://agent", "path": "/chat", "hidden": True, "renderer_clients": [7]},
                 {"browser": 2, "origin": "cmux-page://agent", "path": "/chat", "hidden": False, "renderer_clients": [7]},
                 {"browser": 3, "origin": "cmux-page://home", "path": "/", "renderer_clients": [9]},
                 {"browser": 4, "origin": "cmux-page://agent", "path": "/chat", "renderer_clients": [7]},
                 {"browser": 6, "origin": "cmux-page://agent", "path": "/chat"},
                 {"browser": 5, "origin": "https://example.com", "renderer_clients": [7]}]
        replies = {1: {"usedSize": 190 * MB, "totalSize": 200 * MB}, 2: {"usedSize": 192 * MB, "totalSize": 200 * MB},
                   3: {"usedSize": 5 * MB, "totalSize": 8 * MB}, 4: {"error": "no live page 4"},
                   6: {"usedSize": 3 * MB, "totalSize": 4 * MB}}
        got = bm.heap_summary(pages, replies)
        self.assertEqual(got["pages"], 4)
        self.assertEqual(got["hidden_pages"], 1)
        self.assertEqual(got["renderers"], 3, "renderer 7, renderer 9 and the page with no renderer id")
        self.assertEqual(got["used_mb"], 192.0 + 5.0 + 3.0)
        self.assertEqual(got["total_mb"], 200.0 + 8.0 + 4.0, "the shared isolate counts once, not once per page")
        self.assertEqual(got["by_renderer"][0], {"renderer": 7, "pages": 2, "hidden_pages": 1, "used_mb": 192.0, "total_mb": 200.0})
        self.assertEqual(got["by_path"]["/chat"], {"pages": 3, "hidden_pages": 1})
        self.assertEqual(list(got["by_path"]), ["/chat", "/"])
        self.assertEqual(got["error_count"], 1)
        self.assertEqual(got["errors"], ["no live page 4"])


def windowed(s, disk, gpu):
    """A copy of sample s measured over 30 s, with disk MB/h per kind and the window's GPU reading."""
    out = dict(s, measure_s=30, kinds={k: dict(v, disk_write_mb_per_h=disk.get(k, 0.0)) for k, v in s["kinds"].items()})
    if gpu is not None:
        out["gpu"] = {"samples": 30, "device_utilization_pct": gpu}
    return out


class IdleGpuDiskTests(unittest.TestCase):
    """Goal idle-gpu-disk: the worst idle window's GPU (minus the Mac with no app) and the app's disk writes."""

    def report(self, base=0.4, empty_gpu=0.6, ten_gpu=1.3, ten_failures=0):
        ten = windowed(dict(TEN, pane_failures=ten_failures), {"acpmux-daemon": 2.5, "tui-daemon": 0.75}, ten_gpu)
        rep = {"samples": [windowed(EMPTY, {"app": 0.5}, empty_gpu), ten]}
        if base is not None:
            rep["gpu_no_app"] = {"samples": 30, "device_utilization_pct": base}
        return rep

    def rows(self, **kw):
        return {r["name"]: r for r in cron.idle_rows(self.report(**kw))}

    def test_worst_window_minus_the_mac_with_no_app(self):
        got = self.rows()
        self.assertEqual(got[cron.GPU_ROW]["p95"], 0.9)
        self.assertEqual(got[cron.GPU_ROW]["window"], "idle-10")
        self.assertEqual(got[cron.DISK_ROW]["p95"], 3.25, "every process of the app's writes, summed")

    def test_gpu_below_the_baseline_reads_zero(self):
        self.assertEqual(self.rows(base=2.0)[cron.GPU_ROW]["p95"], 0.0)

    def test_no_baseline_no_gpu_row(self):
        got = self.rows(base=None)
        self.assertNotIn(cron.GPU_ROW, got, "a whole-Mac reading alone counts whatever else the Mac draws")
        self.assertIn(cron.BREAKDOWN_PREFIX + "gpu_device_pct_raw", got)

    def test_a_partial_count_is_no_window(self):
        got = self.rows(ten_failures=1)
        self.assertEqual(got[cron.DISK_ROW]["p95"], 0.5)
        self.assertEqual(got[cron.GPU_ROW]["p95"], 0.2)

    def test_unmeasured_samples_give_no_rows(self):
        self.assertEqual(cron.idle_rows({"samples": [EMPTY, TEN]}), [])

    def test_goal_rows_are_judged_and_the_gpu_split_is_report_only(self):
        for r in cron.idle_rows(self.report()):
            only = bool(perf_cron.REPORT_ONLY_ROW_RE.match(r["name"]))
            self.assertEqual(only, r["name"] not in (cron.GPU_ROW, cron.DISK_ROW), r["name"])
            self.assertEqual(perf_cron.part_for_row(r["name"]), "memory-agents")

    def test_the_part_asks_for_gpu_counters(self):
        import argparse
        ns = argparse.Namespace(app="/A.app", agents="10", settle="20", measure="30", no_app_vm=False, app_vm_stacks=None)
        self.assertIn("--gpu", cron.bench_cmd(ns, "/r.json"))


if __name__ == "__main__":
    unittest.main()
