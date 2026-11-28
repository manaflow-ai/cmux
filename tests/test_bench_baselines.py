#!/usr/bin/env python3
"""scripts/bench/benchlib/baselines.py and `cmux-bench for-paths --run --repeats 3 --baselines`.

Leo, 2026-11-27: "A PR fetches only the baselines for its own areas, which takes milliseconds. A wall-clock result
blocks only if it's more than ~15% worse on 3 repeats. If the baseline is missing, no Mac is free or the
infrastructure is flaky, the check posts a warning and passes."

  - only its own areas: a pull request's fetch asks a local HTTP store for exactly its areas' objects, nothing
    else, and 20 areas come back in well under a second;
  - the rule: 3 of 3 repeats over 115% of the baseline regresses; 2 of 3, or fewer than 3 measurements, passes;
  - fail open: a missing object, an unreachable store, a broken object or a failing bench warns and exits 0;
  - end to end: `baselines record` writes what `for-paths --baselines` reads, and the CLI exits 1 only on the
    3-of-3 regression.
"""
from __future__ import annotations

import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/bench"))

from benchlib import baselines as bl  # noqa: E402
from benchlib import relevance as rel  # noqa: E402

CLI = ROOT / "scripts/bench/cmux-bench"
MCLASS = "test-class"


class Store:
    """A static HTTP server over a directory that records every path it was asked for."""

    def __init__(self, root: Path):
        asked: list[str] = []
        self.asked = asked

        class Handler(http.server.SimpleHTTPRequestHandler):
            def __init__(self, *a, **k):
                super().__init__(*a, directory=str(root), **k)

            def do_GET(self):  # noqa: N802
                asked.append(self.path)
                super().do_GET()

            def log_message(self, *a):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def result(cmd: str, areas: list[str], reps: list[float]) -> dict:
    return {"cmd": cmd, "areas": areas, "status": "ok", "repeats_s": reps, "seconds": sorted(reps)[len(reps) // 2]}


class Rule(unittest.TestCase):
    def test_three_of_three_over_regresses(self):
        self.assertEqual(bl.judge([1.2, 1.3, 1.16], 1.0), bl.REGRESSED)

    def test_one_fast_repeat_passes(self):
        self.assertEqual(bl.judge([1.2, 1.3, 1.10], 1.0), bl.PASSED)

    def test_exactly_fifteen_percent_passes(self):
        self.assertEqual(bl.judge([1.15, 1.15, 1.15], 1.0), bl.PASSED)

    def test_fewer_than_three_repeats_never_regresses(self):
        self.assertEqual(bl.judge([5.0, 5.0], 1.0), bl.NO_MEASURE)

    def test_no_baseline_passes(self):
        self.assertEqual(bl.judge([5.0, 5.0, 5.0], None), bl.NO_BASELINE)

    def test_tightest_area_baseline_wins(self):
        docs = bl.documents([result("a", ["X"], [2.0, 2.0, 2.0])], MCLASS, "s")
        docs.update(bl.documents([result("a", ["Y"], [1.0, 1.0, 1.0])], MCLASS, "s"))
        self.assertEqual(bl.lookup(docs, ["X", "Y"], "a"), (1.0, "Y"))


class Fetch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        results = [result(f"bench {i}", [f"Area {i}"], [1.0 + i, 1.1 + i, 1.2 + i]) for i in range(40)]
        bl.write_dir(bl.documents(results, MCLASS, "abc"), self.root)
        self.store = Store(self.root)

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()

    def test_fetches_only_its_own_areas_in_milliseconds(self):
        want = [f"Area {i}" for i in range(0, 40, 2)]
        docs, missing, took = bl.fetch(want, MCLASS, self.store.url)
        self.assertEqual(sorted(docs), sorted(want))
        self.assertEqual(missing, {})
        self.assertEqual(sorted(self.store.asked), sorted(f"/{bl.object_path(a, MCLASS)}" for a in want))
        self.assertLess(took, 1.0, f"20 areas took {took * 1000:.0f} ms")
        self.assertEqual(bl.lookup(docs, ["Area 4"], "bench 4"), (5.1, "Area 4"))

    def test_missing_area_is_a_reason_not_an_error(self):
        docs, missing, _ = bl.fetch(["Area 1", "Nope"], MCLASS, self.store.url)
        self.assertEqual(list(docs), ["Area 1"])
        self.assertEqual(missing, {"Nope": "no baseline recorded"})

    def test_unreachable_store_fails_open(self):
        docs, missing, took = bl.fetch(["Area 1"], MCLASS, "http://127.0.0.1:9", timeout=1.0)
        self.assertEqual(docs, {})
        self.assertIn("unreachable", missing["Area 1"])
        self.assertLess(took, 3.0)

    def test_broken_object_fails_open(self):
        (self.root / bl.object_path("Area 2", MCLASS)).write_text("{not json")
        docs, missing, _ = bl.fetch(["Area 2"], MCLASS, self.store.url)
        self.assertEqual(docs, {})
        self.assertEqual(missing["Area 2"], "baseline object is not JSON")

    def test_record_keeps_only_fully_measured_benches(self):
        rows = [result("full", ["A"], [1.0, 2.0, 3.0]), result("short", ["A"], [1.0])]
        doc = bl.documents(rows, MCLASS, "s")["A"]
        self.assertEqual([e["cmd"] for e in doc["benches"].values()], ["full"])
        self.assertEqual(next(iter(doc["benches"].values()))["value_s"], 2.0)


MAP = """
[[area]]
name = "Fake area"
paths = ["fake/**"]
benches = []
tests = []
run = ["python3 -I {bench} {state}"]
"""

# Prints the next value of $VALUES (comma-separated) on each call, by a counter file beside the state.
BENCH = """
import os, sys
state = sys.argv[1]
n = int(open(state).read()) if os.path.exists(state) else 0
open(state, "w").write(str(n + 1))
values = os.environ["VALUES"].split(",")
print(f"bench_seconds={values[n % len(values)]}")
"""


class EndToEnd(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        bench = self.dir / "bench.py"
        bench.write_text(BENCH)
        self.state = self.dir / "state"
        self.map = self.dir / "map.toml"
        self.map.write_text(MAP.format(bench=bench, state=self.state))
        self.store = self.dir / "store"
        self.env = {**os.environ, "CMUX_BENCH_MACHINE_CLASS": MCLASS}

    def tearDown(self):
        self.tmp.cleanup()

    def cli(self, *args: str, values: str, stdin: str = "") -> subprocess.CompletedProcess[str]:
        self.state.unlink(missing_ok=True)
        return subprocess.run([sys.executable, "-I", str(CLI), *args], input=stdin, text=True, capture_output=True,
                              env={**self.env, "VALUES": values}, cwd=ROOT, timeout=60)

    def record(self, values: str):
        res = self.cli("baselines", "record", "--out", str(self.store), "--map", str(self.map), values=values)
        self.assertEqual(res.returncode, 0, res.stderr)

    def check(self, values: str) -> subprocess.CompletedProcess[str]:
        return self.cli("for-paths", "--stdin", "--map", str(self.map), "--run", "--repeats", "3",
                        "--baselines", str(self.store), values=values, stdin="fake/x.py\n")

    def test_record_then_compare(self):
        self.record("1.0,0.9,1.1")  # median 1.0
        ok = self.check("1.10,1.05,1.12")
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        self.assertIn("within-baseline", ok.stdout)
        noise = self.check("1.5,1.4,1.10")  # one repeat inside 15%: noise, passes
        self.assertEqual(noise.returncode, 0, noise.stdout + noise.stderr)
        slow = self.check("1.3,1.25,1.2")
        self.assertEqual(slow.returncode, 1, slow.stdout + slow.stderr)
        self.assertIn("regressed", slow.stdout)
        self.assertIn("by more than 15%", slow.stderr)

    def test_missing_baseline_warns_and_passes(self):
        res = self.check("9,9,9")
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn("no baseline recorded", res.stderr)
        self.assertIn("fail open", res.stderr)

    def test_unreachable_store_warns_and_passes(self):
        res = self.cli("for-paths", "--stdin", "--map", str(self.map), "--run", "--repeats", "3",
                       "--baselines", "http://127.0.0.1:9", values="9,9,9", stdin="fake/x.py\n")
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        self.assertIn("unreachable", res.stderr)


class MacFleetLog(unittest.TestCase):
    """record-mac-fleet: SidebarChiefLagTests run 3 times in one fleet step; its log lines become the sidebar
    areas' objects under the fleet class, fetch reads them back, and a log with no bench line exits 1."""

    LINES = "\n".join(
        f"SIDEBAR-CHIEF-LAG ticks before n=1104 frames=120 p50_ms=1.0 p95_ms=9.90 max_ms=5 over16ms=0\n"
        f"SIDEBAR-CHIEF-LAG ticks after n=1104 frames=120 p50_ms=1.5 p95_ms={t} max_ms=9 over16ms=0 chiefs=5\n"
        f"SIDEBAR-CHIEF-LAG scroll after n=1104 frames=60 p50_ms=4.0 p95_ms={s} max_ms=12 over16ms=0\n"
        f"SIDEBAR-CHIEF-LAG remap after n=1104 full_pass_ms={r} avatar_calls=1104"
        for t, s, r in ((3.0, 8.0, 40.0), (3.2, 8.4, 42.0), (2.9, 8.1, 39.0)))

    def test_log_lines_become_the_sidebar_baselines(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "step.log"
            log.write_text("cmux-ci: step abcdef123 queued\n" + self.LINES + "\n")
            env = {**os.environ, "CMUX_BENCH_MACHINE_CLASS": "macos-arm64-fleet-light"}
            out = Path(tmp) / "out"
            got = subprocess.run([sys.executable, "-I", str(CLI), "baselines", "from-log", str(log), "--out", str(out),
                                  "--sha", "abc"], capture_output=True, text=True, env=env)
            self.assertEqual(got.returncode, 0, got.stderr)
            docs, missing, _ = bl.fetch(["Sidebar row feed and flush"], "macos-arm64-fleet-light", str(out))
            self.assertEqual(missing, {})
            benches = docs["Sidebar row feed and flush"]["benches"]
            ticks = benches[bl.bench_id("SidebarChiefLagTests ticks after p95_ms")]
            self.assertEqual(ticks["repeats_s"], [0.003, 0.0032, 0.0029])  # the "after" line only, in seconds
            self.assertEqual(ticks["value_s"], 0.003)
            self.assertEqual(len(benches), 3)

    def test_a_log_with_no_bench_line_is_red(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "step.log"
            log.write_text("error: build failed\n")
            got = subprocess.run([sys.executable, "-I", str(CLI), "baselines", "from-log", str(log), "--out",
                                  str(Path(tmp) / "out")], capture_output=True, text=True)
            self.assertEqual(got.returncode, 1)
            self.assertFalse((Path(tmp) / "out").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
