"""footprint: a local probe dump (ps, proc_pid_rusage, vmmap --summary text) and xbench's cmux-budget kinds."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import Context  # noqa: E402
from benches.footprint import BENCH, kind_of, parse_ps, parse_vmmap, select  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"
APP = "/Applications/cmux NIGHTLY.app"


def find(rows, metric, **labels):
    got = [r for r in rows if r["metric"] == metric and all(r["labels"].get(k) == v for k, v in labels.items())]
    assert len(got) == 1, (metric, labels, len(got))
    return got[0]


def ctx(role: str = "local-readonly") -> Context:
    return Context(bench=BENCH, build={"channel": "nightly", "version": None, "sha": None}, host_role=role,
                   host={"name": "test", "role": role, "os": "", "chip": ""}, timestamp="2026-11-16T00:00:00Z")


class FootprintDumpTest(unittest.TestCase):
    def setUp(self):
        self.ctx = ctx()
        BENCH.ingest(self.ctx, FIXTURES / "footprint" / "probe-nightly.json")
        self.rows = self.ctx.rows

    def test_kinds(self):
        self.assertAlmostEqual(find(self.rows, "footprint", kind="app")["value"], 318.4, places=3)
        self.assertEqual(find(self.rows, "processes", kind="renderer")["value"], 2)
        # one renderer has no rusage reading: its vmmap physical footprint stands in
        self.assertAlmostEqual(find(self.rows, "footprint", kind="renderer")["value"], 141.3 + 128.9, places=3)
        self.assertAlmostEqual(find(self.rows, "footprint", kind="terminal-host")["value"], 2.7, places=3)
        for kind in ("gpu", "utility", "webcontent", "webkit-gpu", "webkit-networking", "cmux-tui", "acpmux"):
            find(self.rows, "footprint", kind=kind)
        total = find(self.rows, "footprint", kind="total")
        kinds = [r for r in self.rows if r["metric"] == "footprint" and r["labels"]["kind"] != "total"]
        self.assertAlmostEqual(total["value"], sum(r["value"] for r in kinds), places=6)
        self.assertEqual(find(self.rows, "processes", kind="total")["value"], 12)

    def test_vmmap_dirty_swapped(self):
        self.assertAlmostEqual(find(self.rows, "dirty", kind="app")["value"], 274.9, places=3)
        self.assertAlmostEqual(find(self.rows, "swapped", kind="renderer")["value"], 6.2 + 4.0, places=3)
        # WebContent had no vmmap reading: no dirty row for it, and none for the total
        self.assertFalse([r for r in self.rows
                          if r["metric"] == "dirty" and r["labels"]["kind"] in ("webcontent", "total")])
        self.assertAlmostEqual(find(self.rows, "rss", kind="app")["value"], 729100 / 1024, places=3)

    def test_parsers(self):
        vm = parse_vmmap("Physical footprint:         1.5G\nTOTAL   9G   2G   700M   12K   0K\n")
        self.assertEqual(vm, {"footprint": 1.5 * 1024 ** 3, "resident": 2 * 1024 ** 3, "dirty": 700 * 1024 ** 2,
                              "swapped": 12 * 1024})
        self.assertEqual(kind_of(f"{APP}/Contents/MacOS/cmux NIGHTLY --type=gpu-process"), "gpu")
        self.assertEqual(kind_of(f"{APP}/Contents/Resources/bin/cmux-tui __terminal-host --owner x@1"), "terminal-host")
        self.assertEqual(kind_of(f"{APP}/Contents/Frameworks/cmux NIGHTLY Helper.app/Contents/MacOS/cmux NIGHTLY Helper"),
                         "helper")

    def test_select(self):
        table = parse_ps("\n".join([
            f"100 1 5000 {APP}/Contents/MacOS/cmux NIGHTLY",
            f"101 100 4000 {APP}/Contents/MacOS/cmux NIGHTLY --type=renderer",
            f"102 100 4000 {APP}/Contents/MacOS/cmux NIGHTLY --type=code-sign-clone-cleanup",
            "103 101 100 /bin/zsh -l",
            f"104 1 300 {APP}/Contents/Resources/bin/cmux-tui daemon",
            "105 1 300 /opt/cmux/cmux-tui __terminal-host --owner cmux-app-nightly@104",
            "106 1 300 /Applications/Other.app/Contents/MacOS/Other",
            "107 1 300 /Applications/cmux NEXT.app/Contents/MacOS/cmux NEXT",
        ]))
        main, pids = select(table, APP)
        self.assertEqual(main, 100)
        self.assertEqual(pids, [100, 101, 103, 104, 105])
        self.assertEqual(select(table, "/Applications/Missing.app"), (None, []))


class FootprintFleetTest(unittest.TestCase):
    def test_budget_kinds(self):
        c = ctx("fleet")
        BENCH.ingest(c, FIXTURES / "xbench" / "results-budget.json")
        self.assertEqual(find(c.rows, "footprint", kind="total", phase="tabs-hidden")["value"], 1525.2)
        self.assertEqual(find(c.rows, "footprint", kind="app", phase="tabs-hidden")["value"], 322.0)
        self.assertEqual(find(c.rows, "footprint", kind="webcontent", phase="tabs-hidden")["value"], 153.4)
        self.assertEqual(find(c.rows, "processes", kind="total", phase="tabs-hidden")["value"], 53)
        self.assertEqual(find(c.rows, "footprint", kind="renderer", phase="home")["unit"], "MB")
        self.assertEqual(c.host["name"], "cmux22")


if __name__ == "__main__":
    unittest.main()
