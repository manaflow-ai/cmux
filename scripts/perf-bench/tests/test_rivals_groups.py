#!/usr/bin/env python3
"""rivals.py (RFD 0062): the idle soak splits footprint, CPU and wakeups over the five process groups (app,
renderer, gpu, acpmux, terminals) for every app, the report prints that table, and it says whether Safari's
WebKit XPC processes were counted.
Run: python3 -I scripts/perf-bench/tests/test_rivals_groups.py"""
import contextlib, io, json, os, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import rivals  # noqa: E402  (imports procs lazily, so this runs on Linux)

MACHINE = {"chip": "Apple M4", "model": "Mac16,10", "cores": 10, "ram_gb": 16, "macos": "26.1", "build": "x",
           "host": "test"}


def report(samples, apps):
    out = tempfile.mkdtemp()
    with open(os.path.join(out, "samples.jsonl"), "w") as handle:
        for sample in samples:
            handle.write(json.dumps(sample) + "\n")
    with open(os.path.join(out, "meta.json"), "w") as handle:
        json.dump({"machine": MACHINE, "args": {"rounds": 1, "warm": 3, "after": 20, "soak": 300, "sample": 10},
                   "apps": {a: {"name": rivals.LABELS[a]} for a in apps}}, handle)
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rivals.report(out, None, None)
    return buf.getvalue()


class Groups(unittest.TestCase):
    def test_kinds_map_to_groups(self):
        cases = {"main": "app", "helper": "app", "utility:NetworkService": "app", "webkit-networking": "app",
                 "renderer": "renderer", "webkit-webcontent": "renderer", "gpu": "gpu", "webkit-gpu": "gpu",
                 "acpmux": "acpmux", "terminal-host": "terminals", "cmux-tui": "terminals",
                 "cmux-holder": "terminals", "crashpad_handler": "other"}
        for kind, group in cases.items():
            self.assertEqual(rivals.group_of(kind), group, kind)

    def test_by_group_sums(self):
        got = rivals.by_group({"main": 300.0, "renderer": 40.0, "gpu": 120.0, "terminal-host": 170.0, "acpmux": 15.0},
                              {"main": {"n": 1, "cpu_pct": 0.2, "wakeups_per_s": 3.0},
                               "gpu": {"n": 1, "cpu_pct": 1.5, "wakeups_per_s": 90.0},
                               "terminal-host": {"n": 99, "cpu_pct": 0.0, "wakeups_per_s": 0.0}})
        self.assertEqual(got["app"]["memory"], 300.0)
        self.assertEqual(got["gpu"]["wakeups"], 90.0)
        self.assertEqual(got["terminals"]["processes"], 99)
        self.assertEqual(got["other"]["memory"], 0.0)

    def test_report_prints_group_table_and_safari_check(self):
        samples = [{"browser": "cmux", "round": 1, "row": "soak-processes", "value": 110},
                   {"browser": "safari", "round": 1, "row": "soak-processes", "value": 6},
                   {"browser": "cmux", "round": 1, "row": "soak-group-gpu-memory", "value": 140.0},
                   {"browser": "safari", "round": 1, "row": "soak-group-gpu-memory", "value": 60.0},
                   {"browser": "safari", "round": 1, "row": "soak-detail", "value": 2,
                    "pids": [{"pid": 1, "kind": "main"}, {"pid": 2, "kind": "webkit-webcontent"}]}]
        text = report(samples, ["cmux", "safari"])
        self.assertIn("## Idle by process group", text)
        self.assertIn("| Idle, GPU: footprint, end (MB) | 140 | 60 (cmux 2.3x more) |", text)
        self.assertNotIn("Idle acpmux", text)  # unused groups have no rows
        self.assertIn("WebKit XPC processes (WebContent, GPU, Networking) counted: 1 in", text)
        missing = report([s for s in samples if s["row"] != "soak-detail"], ["cmux", "safari"])
        self.assertIn("NONE FOUND", missing)


class Growth(unittest.TestCase):
    def test_troughs_take_each_buckets_lowest(self):
        points = [(0, 100), (10, 90), (20, 120), (30, 95), (40, 130), (50, 99)]
        self.assertEqual(rivals.troughs(points, 20), [(10, 90), (30, 95), (50, 99)])
        self.assertEqual(rivals.troughs(points, 0), [])
        self.assertAlmostEqual(rivals.slope_per_min(rivals.troughs(points, 20)), 13.5)

    def test_trough_every_default(self):
        self.assertEqual(rivals.trough_every(300, None), 0)
        self.assertEqual(rivals.trough_every(28800, None), 2400)
        self.assertEqual(rivals.trough_every(300, 60), 60)

    def test_report_prints_extra_passes_only_when_measured(self):
        base = [{"browser": "chrome", "round": 1, "row": "soak-memory-growth", "value": 0.4}]
        text = report(base, ["cmux", "chrome"])
        self.assertNotIn("## Signed in", text)
        self.assertNotIn("## Background tabs", text)
        self.assertNotIn("Idle: trough growth", text)
        more = base + [{"browser": "chrome", "round": 1, "row": "tabs-soak-memory-end", "value": 900.0},
                       {"browser": "chrome", "round": 1, "row": "soak-memory-trough-growth", "value": 0.01},
                       {"browser": "claude", "round": 1, "row": "signed-in-soak-memory-end", "value": 700.0}]
        text = report(more, ["cmux", "chrome", "claude"])
        self.assertIn("| Background tabs, idle: footprint at end (MB) | – | – | 900 |", text)
        self.assertIn("| Signed in, idle: footprint at end (MB) | – | 700 | – |", text)
        self.assertIn("| Idle: trough growth (MB/min) | – | – | +0.010 |", text)


class Bounds(unittest.TestCase):
    def test_growth_bounds_are_advisory_perf_rows(self):
        import growth_bounds
        rows = {"soak-memory-growth": {"cmux": {"median": 1.4}},
                "soak-group-renderer-growth": {"cmux": {"median": 0.2}},
                "soak-group-gpu-growth": {"cmux": {"median": 0.3}},
                "soak-memory-trough-growth": {"cmux": {"median": 0.01}}}
        short = growth_bounds.lines(rows, "cmux", 300)
        self.assertIn("| idle, short: whole instance | 1 MB/min | +1.400 | OVER | rivals.py soak, slope after --settle-cut |",
                      short)
        self.assertIn("| idle, short: worst group | 0.5 MB/min | +0.300 | yes | rivals.py soak, per-group slope |", short)
        names = [json.loads(l[len("PERF_ROW "):])["name"] for l in short if l.startswith("PERF_ROW ")]
        self.assertEqual(names, ["growth.idle_short", "growth.idle_short_group"])  # a 300 s soak has no long bound
        long = growth_bounds.lines(rows, "cmux", 28800)
        self.assertIn('PERF_ROW {"clock": "cpu", "floor": 0.01, "name": "growth.idle_long", "p50": 0.01, "p95": 0.01, '
                      '"target": 0.02, "unit": "MB/min"}', long)
        self.assertTrue(any("not measured here" in l for l in long))

    def test_report_ends_with_growth_bounds(self):
        text = report([{"browser": "cmux", "round": 1, "row": "soak-memory-growth", "value": 0.2}], ["cmux"])
        self.assertIn("## Growth bounds (RFD 0062, advisory", text)
        self.assertIn('PERF_ROW {"clock": "cpu", "floor": 0.1, "name": "growth.idle_short"', text)


class ByProcess(unittest.TestCase):
    """RFD 0062: a group's growth split into processes that grew and processes born or gone in the soak."""

    def series(self):
        ticks = list(range(0, 301, 30))
        return {
            1: {"kind": "renderer", "command": "steady", "points": [(t, 100.0 + t / 60) for t in ticks]},  # +1 MB/min
            2: {"kind": "renderer", "command": "born", "points": [(t, 200.0) for t in ticks if t >= 180]},
            3: {"kind": "helper", "command": "gone", "points": [(t, 50.0) for t in ticks if t <= 150]},
            4: {"kind": "renderer", "command": "warmup", "points": [(t, 10.0) for t in ticks if t < 90]},
        }

    def test_steady_and_churn(self):
        rows = rivals.growth_by_process(self.series(), 90)
        by_pid = {r["pid"]: r for r in rows}
        self.assertNotIn(4, by_pid)  # gone before the settle cut
        self.assertTrue(by_pid[1]["steady"])
        self.assertAlmostEqual(by_pid[1]["growth_mb_per_min"], 1.0, places=3)
        self.assertEqual(by_pid[2]["born_s"], 180)
        self.assertEqual(by_pid[2]["added_mb"], 200.0)
        self.assertEqual(by_pid[3]["gone_s"], 150)
        self.assertEqual(by_pid[3]["added_mb"], -50.0)
        self.assertEqual(rows[0]["pid"], 2)  # sorted by MB added
        split = rivals.growth_split(rows, "renderer", 3.5)
        self.assertAlmostEqual(split["steady"], 1.0, places=3)
        self.assertAlmostEqual(split["churn"], 200 / 3.5, places=2)
        self.assertEqual((split["born"], split["gone"]), (1, 0))

    def test_report_section(self):
        rows = rivals.growth_by_process(self.series(), 90)
        sample = {"browser": "cmux", "round": 1, "row": "soak-growth-by-process", "value": len(rows),
                  "settle_cut": 90, "minutes": 3.5, "pids": rows,
                  "split": {g: rivals.growth_split(rows, g, 3.5) for g in rivals.GROUPS}}
        text = "\n".join(rivals.growth_by_process_lines([sample], ["cmux"]))
        self.assertIn("Idle growth by process: cmux NEXT", text)
        self.assertIn("| renderer | +1.000 | +57.143 | 1 | 0 |", text)
        self.assertIn("| 2 | renderer | renderer | 200.0 | 200.0 | +200.0 |", text)


if __name__ == "__main__":
    unittest.main()
