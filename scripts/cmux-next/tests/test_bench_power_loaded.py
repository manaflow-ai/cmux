#!/usr/bin/env python3
"""bench_power.py `loaded` (the shared idle-cost bench): renderer roles come from `debug.cef_pages`
by renderer client id, the per-role numbers sum their processes (p95 over the summed 1 s steps),
the peer's processes stay out, and the Performance-table rows carry before, after and delta.
idle_cost_load.seed_store copies the template chats under new ids, folders owner-only."""

from __future__ import annotations

import json
import os
import shutil
import stat
import tempfile
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import bench_power as bp  # noqa: E402
import idle_cost_load as load  # noqa: E402


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class LoadedTests(unittest.TestCase):
    def test_roles_by_renderer_client_id(self):
        processes = {11: ("cef-renderer", "Helper (Renderer) --type=renderer --renderer-client-id=4 --x"),
                     12: ("cef-renderer", "Helper (Renderer) --type=renderer --renderer-client-id=7"),
                     13: ("cef-renderer", "Helper (Renderer) --type=renderer --renderer-client-id=9"),
                     14: ("cef-gpu", "Helper (GPU) --type=gpu-process")}
        pages = [{"origin": "cmux-page://cmux.agent", "hidden": False, "renderer_clients": [4]},
                 {"origin": "cmux-page://cmux.home", "hidden": True, "renderer_clients": [7]},
                 {"origin": "http://t1.localhost", "hidden": True, "renderer_clients": [7]}]
        roles = bp.renderer_roles(pages, processes)
        self.assertEqual(roles, {11: "cef-renderer: agent", 12: "cef-renderer: browser-tab (hidden) + home (hidden)"})

    def test_measure_sums_roles_and_leaves_the_peer_out(self):
        clock = FakeClock()
        saved = (bp.time, bp.bm.owned, bp.usage_v6, bp.main_thread_ns)
        cpu_per_s = {1: 0.5e9, 2: 0.1e9, 3: 0.2e9, 9: 5e9}  # ns of CPU each second
        try:
            bp.time = clock
            bp.bm.owned = lambda pid, bundle: {1: ("app", "app"), 2: ("cef-renderer", "r"), 3: ("cef-renderer", "r"),
                                               9: ("acpmux-daemon", "peer")}
            bp.usage_v6 = lambda pid: (0, int(cpu_per_s[pid] * clock.now), int(2 * clock.now), int(3 * clock.now), 100 * 1048576)
            bp.main_thread_ns = lambda pid: int(0.25e9 * clock.now) if pid == 1 else None
            result = bp.measure_processes(1, "/x.app", "loaded", 10, {2: "cef-renderer: agent", 3: "cef-renderer: agent"}, {9})
        finally:
            bp.time, bp.bm.owned, bp.usage_v6, bp.main_thread_ns = saved
        self.assertEqual(sorted(r["pid"] for r in result["processes"]), [1, 2, 3])
        self.assertAlmostEqual(result["roles"]["app"]["cpu_pct"], 50.0)
        self.assertAlmostEqual(result["roles"]["app"]["main_thread_pct"], 25.0)
        agent = result["roles"]["cef-renderer: agent"]
        self.assertEqual((agent["count"], agent["footprint_mb"]), (2, 200.0))
        self.assertAlmostEqual(agent["cpu_pct"], 30.0)
        self.assertAlmostEqual(agent["cpu_p95_pct"], 30.0)
        self.assertIsNone(agent["main_thread_pct"])
        self.assertAlmostEqual(result["roles"]["total"]["cpu_pct"], 80.0)
        self.assertAlmostEqual(result["roles"]["total"]["idle_wakeups_per_s"], 6.0)
        self.assertAlmostEqual(result["roles"]["total"]["wakeups_per_s"], 15.0)  # idle 2 + interrupt 3, three processes

    def test_footprint_read_as_zero_is_unread_not_zero(self):
        # A display run read 0 MB for 24 of 46 live renderers and summed them as 0 (7.3 GB, not ~13).
        clock = FakeClock()
        saved = (bp.time, bp.bm.owned, bp.usage_v6, bp.main_thread_ns)
        try:
            bp.time = clock
            bp.bm.owned = lambda pid, bundle: {1: ("app", "app"), 2: ("cef-renderer", "r"), 3: ("cef-renderer", "r")}
            bp.usage_v6 = lambda pid: (0, int(1e8 * clock.now), 0, 0, 0 if pid == 3 else 100 * 1048576)
            bp.main_thread_ns = lambda pid: None
            result = bp.measure_processes(1, "/x.app", "idle-chats", 5, {2: "cef-renderer: agent", 3: "cef-renderer: agent"}, set())
        finally:
            bp.time, bp.bm.owned, bp.usage_v6, bp.main_thread_ns = saved
        unread = next(r for r in result["processes"] if r["pid"] == 3)
        self.assertIsNone(unread["footprint_mb"])
        agent = result["roles"]["cef-renderer: agent"]
        self.assertEqual((agent["footprint_mb"], agent["footprint_unread"]), (100.0, 1))
        self.assertEqual(result["roles"]["total"]["footprint_unread"], 1)
        rows, _ = bp.process_rows({**result, "label": "idle-chats"}, 5.0)
        self.assertTrue(any(row.startswith("| cef-renderer: agent | 3 |") and "|  |  |" in row for row in rows))

    def test_profile_summary_self_time_by_function(self):
        profile = {"nodes": [{"id": 1, "callFrame": {"functionName": "(root)", "url": "", "lineNumber": -1, "columnNumber": -1}},
                             {"id": 2, "callFrame": {"functionName": "(program)", "url": "", "lineNumber": -1, "columnNumber": -1}},
                             {"id": 3, "callFrame": {"functionName": "tick", "url": "cmux-page://cmux.agent/pane.js", "lineNumber": 9, "columnNumber": 4}}],
                   "samples": [2, 3, 3, 2], "timeDeltas": [0, 1000, 3000, 500]}
        summary = bp.profile_summary(profile)
        self.assertEqual(summary["self_ms"][0], ["tick pane.js:10:5", 3.5])
        self.assertEqual(summary["self_ms"][1], ["(program) :0:0", 1.0])
        self.assertEqual(summary["total_ms"], 4.5)

    def test_perf_rows(self):
        before = {"roles": {"total": {"cpu_pct": 70.0, "footprint_mb": 2000.0, "main_thread_pct": None}}}
        after = {"roles": {"total": {"cpu_pct": 35.0, "footprint_mb": 2100.0, "main_thread_pct": None}}}
        rows = bp.perf_rows(before, after, "h")
        self.assertEqual(rows[0], "| metric | before | after | delta | harness |")
        self.assertIn("| total: CPU % (avg) | 70 | 35 | -35 (-50%) | h |", rows)
        self.assertIn("| total: footprint MB | 2000 | 2100 | +100 (+5%) | h |", rows)
        self.assertFalse(any("main thread" in row for row in rows))
        self.assertIn("| total: CPU % (avg) | 70 |  |  | h |", bp.perf_rows(before, None, "h"))

    def test_seed_store(self):
        home = tempfile.mkdtemp()
        try:
            def template(sid, status):
                meta = json.dumps({"schema": "acpmux.session.v1", "id": sid, "name": "t", "status": status, "turnCount": 1})
                log = json.dumps({"seq": 1, "kind": "turn_started", "msg": {"session": sid}}) + "\n"
                return {"id": sid, "meta": meta.encode(), "events": {"000000.ndjson": log.encode()}}
            seeded = load.seed_store(os.path.join(home, "acpmux"), 10, 0.6, template("tmpl-a", "ready"), template("tmpl-c", "closed"))
            self.assertEqual(seeded, {"sessions": 10, "closed": 6, "idle": 4})
            root = Path(home, "acpmux", "sessions")
            metas = [json.loads(p.read_text()) for p in sorted(root.glob("*/session.json"))]
            self.assertEqual(sorted(m["status"] for m in metas), ["closed"] * 6 + ["idle"] * 4)
            self.assertEqual(len({m["id"] for m in metas}), 10)
            for folder in root.iterdir():
                meta = json.loads((folder / "session.json").read_text())
                self.assertEqual(meta["id"], folder.name)
                log = (folder / "events" / "000000.ndjson").read_text()
                self.assertIn(folder.name, log)
                self.assertNotIn("tmpl-", log)
                self.assertEqual(stat.S_IMODE(folder.stat().st_mode), 0o700)
                self.assertEqual(stat.S_IMODE((folder / "session.json").stat().st_mode), 0o600)
        finally:
            shutil.rmtree(home)


class IdleChatsTests(unittest.TestCase):
    """`idle-chats`: the idle-CPU stop condition's preset, its per-process table and its verdict."""

    def args(self, **given):
        base = {"load_remote": None, "load_local": None, "load_streaming": None, "load_tabs": None,
                "settle": None, "measure": None}
        base.update(given)
        return type("Args", (), base)()

    def test_preset_fills_unset_flags_only(self):
        args = bp.apply_preset(self.args(measure=30), "idle-chats")
        self.assertEqual((args.load_local, args.load_remote, args.load_streaming, args.load_tabs), (40, 0, 0, 0))
        self.assertEqual((args.settle, args.measure), (60, 30))
        loaded = bp.apply_preset(self.args(), "loaded")
        self.assertEqual((loaded.load_remote, loaded.load_local, loaded.settle, loaded.measure), (20, 5, 120, 60))

    def result(self):
        return {"label": "idle-chats", "harness": "h", "load": {"local_chats": 40},
                "roles": {"total": {"cpu_pct": 101.0}},
                "processes": [
                    {"pid": 1, "kind": "app", "role": "app", "cpu_pct": 4.5, "cpu_p95_pct": 6.0,
                     "wakeups_per_s": 120.0, "main_thread_pct": 3.0, "footprint_mb": 300.0, "command": "cmux"},
                    {"pid": 2, "kind": "cef-renderer", "role": "cef-renderer: agent", "cpu_pct": 95.25,
                     "cpu_p95_pct": 99.0, "wakeups_per_s": 900.0, "main_thread_pct": 90.0, "footprint_mb": 650.0,
                     "command": "Helper (Renderer) --type=renderer --renderer-client-id=4"},
                    {"pid": 3, "kind": "cef-renderer", "role": "cef-renderer", "cpu_pct": 1.25, "cpu_p95_pct": 2.0,
                     "wakeups_per_s": 5.0, "main_thread_pct": None, "footprint_mb": 80.0,
                     "command": "Helper (Renderer) --type=renderer --lang=en --renderer-client-id=9"}]}

    def test_table_busiest_first_and_over_budget_named(self):
        rows, verdict = bp.process_rows(self.result(), 5.0)
        self.assertEqual(rows[0].split("|")[1].strip(), "process")
        self.assertTrue(rows[2].startswith("| cef-renderer: agent | 2 | 95.25 | 99.00 | 900.0 | 90.00 | 650.0 | OVER |"))
        self.assertTrue(rows[3].startswith("| app | 1 | 4.50 |"))
        self.assertTrue(rows[3].endswith("|  |"))
        # A renderer with no page map shows its command-line kind, not a bare "cef-renderer".
        self.assertIn("`--type=renderer --renderer-client-id=9`", rows[4])
        self.assertEqual(verdict["verdict"], "OVER")
        self.assertEqual([entry["pid"] for entry in verdict["over"]], [2])
        self.assertEqual((verdict["max_role"], verdict["max_cpu_pct"]), ("cef-renderer: agent", 95.25))

    def test_pass_when_every_process_is_under_budget(self):
        result = self.result()
        result["processes"] = [proc for proc in result["processes"] if proc["pid"] != 2]
        markdown, verdict = bp.idle_cost_markdown(result, 5.0)
        self.assertEqual(verdict["verdict"], "PASS")
        self.assertIn("Verdict: **PASS** (budget 5% CPU per process; busiest app at 4.5%)", markdown)
        self.assertIn("| total: CPU % (avg) | 101 |  |  | h |", markdown)

    def test_no_process_measured_is_not_a_pass(self):
        result = self.result()
        result["processes"] = []
        _rows, verdict = bp.process_rows(result, 5.0)
        self.assertEqual(verdict["verdict"], "UNMEASURED")

    def test_renderer_flags_survive_a_truncated_command(self):
        result = self.result()
        result["processes"] = [{**result["processes"][2], "command": "/" + "x" * 200,
                                "flags": "--type=renderer --renderer-client-id=9"}]
        rows, _verdict = bp.process_rows(result, 5.0)
        self.assertIn("`--type=renderer --renderer-client-id=9`", rows[2])

    def test_compare_reads_an_idle_chats_run(self):
        folder = tempfile.mkdtemp()
        try:
            path = os.path.join(folder, "run.json")
            with open(path, "w") as handle:
                json.dump({"results": [self.result()]}, handle)
            self.assertEqual(bp.loaded_result(path)["label"], "idle-chats")
        finally:
            shutil.rmtree(folder)


if __name__ == "__main__":
    unittest.main()
