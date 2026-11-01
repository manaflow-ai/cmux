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

if __name__ == "__main__":
    unittest.main()
