"""terminal-throughput-quick: the quick script's report becomes MB/s and ratio rows, plus the trace's split rows."""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import Context  # noqa: E402
from benchlib.registry import load_all  # noqa: E402


def call(b):
    return {"count": 1, "wall_ms": 1.0, "blocked_pct": 10.0, "bytes": b, "mb_s": b / 1e6}


REPORT = {"payload": "mixed", "rows": [
    {"name": "terminal.throughput.next_mb_s", "p50": 100.0, "unit": "MB/s"},
    {"name": "terminal.throughput.ghostty_mb_s", "p50": 213.0, "unit": "MB/s"},
    {"name": "terminal.throughput.ratio", "p50": 0.469, "unit": "x"},
    {"name": "terminal.interrupt.key_to_signal_ms", "p50": 4.0, "unit": "ms"}],
    "next": {"trace": {"window_s": 2.0, "writer_pid": 1, "threads": [
        {"thread": "Main Thread 0x1 (Python, pid: 1)", "pid": 1, "running_pct": 50.0, "calls": {"write": call(9)}},
        {"thread": "Thread 0x2 (cmux-tui, pid: 2)", "pid": 2, "running_pct": 92.0, "calls": {"read": call(9)}},
        {"thread": "renderer 0x3 (cmux, pid: 3)", "pid": 3, "running_pct": 40.0, "calls": {}}]}},
    "ghostty": {}}


class Quick(unittest.TestCase):
    def test_registered_on_the_fleet(self):
        bench = load_all()["terminal-throughput-quick"]
        self.assertEqual(bench.hosts, ("fleet",))
        self.assertEqual(bench.harness, "scripts/measure/terminal-throughput-quick.sh")

    def test_report_rows_and_split(self):
        bench = load_all()["terminal-throughput-quick"]
        ctx = Context(bench=bench, build={"channel": "nightly", "version": "1", "sha": "a" * 40}, host_role="fleet",
                      host={"name": "mac", "role": "fleet", "os": "macOS", "chip": "arm64"})
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "report.json"
            path.write_text(json.dumps(REPORT))
            bench.ingest(ctx, path)
        got = {(r["metric"], r["labels"].get("terminal")): r for r in ctx.rows}
        self.assertEqual(got[("ratio", None)]["value"], 0.469)
        self.assertEqual(got[("next_mb_s", None)]["better"], "higher")
        self.assertNotIn(("key_to_signal_ms", None), got)
        self.assertEqual(got[("pty_read_running_pct", "next")]["value"], 92.0)
        self.assertEqual(got[("pty_read_running_pct", "next")]["labels"]["bound"], "pty-read")
        self.assertEqual(got[("render_running_pct", "next")]["value"], 40.0)
        self.assertFalse([k for k in got if k[1] == "ghostty"], "an untraced terminal adds no split rows")


if __name__ == "__main__":
    unittest.main()
