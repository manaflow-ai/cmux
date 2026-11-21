#!/usr/bin/env python3
"""xbench --scenario idle-tabs (perf-bench.sh suite=tabs, ask-9176875aef): the report gets an "Idle cost as tabs
grow" table with a row per tab count and metric, cmux NEXT against Microsoft Edge, from the run's own
--tab-counts, and no such section when the run had no idle-tabs samples.
Run: python3 -I scripts/perf-bench/tests/test_idle_tabs_report.py"""
import json, os, sys, tempfile, types, unittest, contextlib, io

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
_PROCS_STUB = None
try:
    import procs  # noqa: F401
except OSError:
    _PROCS_STUB = sys.modules["procs"] = types.ModuleType("procs")
try:
    import xbench  # noqa: E402
finally:
    if _PROCS_STUB is not None and sys.modules.get("procs") is _PROCS_STUB:
        del sys.modules["procs"]

MACHINE = {"chip": "Apple M4", "model": "Mac16,10", "cores": 10, "ram_gb": 16, "macos": "26.1", "build": "x",
           "host": "test"}


def run_report(samples, tab_counts):
    out = tempfile.mkdtemp()
    with open(os.path.join(out, "samples.jsonl"), "w") as handle:
        for sample in samples:
            handle.write(json.dumps(sample) + "\n")
    with open(os.path.join(out, "meta.json"), "w") as handle:
        json.dump({"machine": MACHINE, "cmux_ref": "abc", "args": {"tab_counts": tab_counts, "idle": 60, "settle": 30},
                   "browsers": {"cmux-chromium": {"name": "cmux NEXT (Chromium tab)", "version": "1"},
                                "edge": {"name": "Microsoft Edge", "version": "2"}}}, handle)
    md = os.path.join(out, "BENCH.md")
    with contextlib.redirect_stdout(io.StringIO()):
        result = xbench.report(out, md, None)
    return result, open(md).read()


def sample(browser, row, value):
    return {"browser": browser, "round": 1, "row": row, "value": value}


class IdleTabsReport(unittest.TestCase):
    def test_table_has_each_count_and_edge(self):
        samples = []
        for count, (cmux_mb, edge_mb) in {1: (300, 400), 10: (900, 1200), 50: (2500, 3000)}.items():
            samples += [sample("cmux-chromium", f"tabs{count}-memory", cmux_mb), sample("edge", f"tabs{count}-memory", edge_mb),
                        sample("cmux-chromium", f"tabs{count}-gpu-util", 1.0), sample("edge", f"tabs{count}-gpu-util", 2.0)]
        result, md = run_report(samples, "1,10,50")
        self.assertIn("## Idle cost as tabs grow", md)
        self.assertIn("Microsoft Edge", md)
        for count in (1, 10, 50):
            self.assertIn(f"tabs{count}-memory", result["rows"])
        self.assertIn("50 tabs, memory", md)
        self.assertIn("1 tab, GPU Device Utilization", md)
        line = next(l for l in md.splitlines() if l.startswith("| 50 tabs, memory"))
        self.assertIn("3,000 MB (Microsoft Edge)", line)

    def test_custom_counts_come_from_the_run(self):
        result, md = run_report([sample("edge", "tabs100-cpu", 0.5), sample("cmux-chromium", "tabs100-cpu", 0.25)], "100")
        self.assertIn("tabs100-cpu", result["rows"])
        self.assertIn("100 tabs, CPU", md)

    def test_no_section_without_idle_tab_samples(self):
        _result, md = run_report([sample("edge", "memory-1", 400)], "1,10,50")
        self.assertNotIn("Idle cost as tabs grow", md)


if __name__ == "__main__":
    unittest.main()
