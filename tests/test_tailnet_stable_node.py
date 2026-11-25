"""tailnet-stable-node bench: the stats math, the rows of one run line, and the harness's syntax (no network, no root)."""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BENCH_DIR = ROOT / "scripts" / "bench"
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.tailnet_stable_node import BENCH, SCHEMA  # noqa: E402
import tailnet_bench  # noqa: E402

SCRIPT = BENCH_DIR / "tailnet-stable-node.sh"


class Stats(unittest.TestCase):
    def test_pct_nearest_rank(self):
        self.assertEqual(tailnet_bench.pct([1, 2, 3, 4], 50), 2)
        self.assertEqual(tailnet_bench.pct([1, 2, 3, 4], 95), 4)
        self.assertIsNone(tailnet_bench.pct([], 50))

    def test_stats_counts_loss_and_reconnect(self):
        # echoes at 100, 200, 300 ms; a move at 250 ms; the next echo after it at 300 ms
        ms = 1_000_000
        events = [
            {"ev": "rx", "seq": 1, "t": 100 * ms, "rtt_ms": 1.0},
            {"ev": "rx", "seq": 2, "t": 200 * ms, "rtt_ms": 2.0},
            {"ev": "rx", "seq": 3, "t": 300 * ms, "rtt_ms": 3.0},
            {"ev": "disconnect", "t": 310 * ms, "why": "idle"},
            {"ev": "end", "sent": 5},
        ]
        moves = [{"t_ns": 250 * ms}]
        s = tailnet_bench.stats(events, moves)
        self.assertEqual(s["sent"], 5)
        self.assertEqual(s["lost"], 2)
        self.assertEqual(s["disconnects"], 1)
        self.assertEqual(s["stall_ms"]["p50"], 100.0)  # last echo before the move (200) to the next (300)
        self.assertEqual(s["resume_ms"]["p50"], 50.0)  # the move (250) to the next echo (300)


class Ingest(unittest.TestCase):
    def run_line(self, **over):
        run = {
            "schema": SCHEMA,
            "meta": {"moves": 20, "connect_cmux_ms": 900, "connect_client_ms": 700, "route_visible_ms": 1200,
                     "derp_to_direct_ms": 450, "final_path": "direct", "first_pong": "pong via DERP(bench)"},
            "v1": {"tcp": {"rtt_ms": {"p50": 0.4, "p95": 0.9, "p99": 1.5, "n": 100},
                           "resume_ms": {"p50": 1100, "p95": 1200, "n": 20},
                           "stall_ms": {"p50": 1100, "p95": 1200, "n": 20},
                           "disconnects": 20, "lost": 3},
                   "udp": {"lost": 5, "resume_ms": {"p50": 40, "p95": 60, "n": 20}}},
            "v2": {"tcp": {"rtt_ms": {"p50": 0.5, "p95": 1.0, "p99": 2.0, "n": 100},
                           "resume_ms": {"p50": 12, "p95": 20, "n": 20},
                           "disconnects": 0, "lost": 1}},
            "tailnet_view_unchanged": True,
        }
        run.update(over)
        return run

    def ingest(self, text):
        with tempfile.TemporaryDirectory(prefix="tnsb-test-") as d:
            p = Path(d) / "log.txt"
            p.write_text(text, encoding="utf-8")
            ctx = Context(bench=BENCH, build={"channel": "other", "version": "test", "sha": ""}, host_role="fleet")
            BENCH.ingest(ctx, p)
            return ctx

    def test_run_line_becomes_rows(self):
        text = "2026-11-24T12:00:00.000Z setup\nTNSB-RUN " + json.dumps(self.run_line()) + "\n"
        ctx = self.ingest(text)
        by = {(r["metric"]): r for r in ctx.rows}
        self.assertEqual(by["connect_cmux_ms"]["value"], 900.0)
        self.assertEqual(by["derp_to_direct_ms"]["labels"]["final_path"], "direct")
        self.assertEqual(by["v1.tcp.rtt_ms"]["p95"], 0.9)
        self.assertEqual(by["v1.tcp.disconnects"]["value"], 20.0)
        self.assertEqual(by["v1.udp.lost"]["value"], 5.0)
        self.assertEqual(by["v2.tcp.resume_ms"]["value"], 12.0)
        self.assertEqual(by["tailnet_view_unchanged"]["value"], 1.0)
        self.assertNotIn("v2.udp.lost", by)

    def test_view_changed_is_zero(self):
        ctx = self.ingest("TNSB-RUN " + json.dumps(self.run_line(tailnet_view_unchanged=False)) + "\n")
        self.assertEqual({r["metric"]: r for r in ctx.rows}["tailnet_view_unchanged"]["value"], 0.0)

    def test_log_without_a_run_line_is_refused(self):
        with self.assertRaises(BenchError):
            self.ingest("no summary here\n")


class ClientReconnects(unittest.TestCase):
    def test_client_reconnects_after_a_server_drop(self):
        """A server that drops every connection after one echo: the client must log a disconnect and reconnect."""
        import asyncio
        import socket

        def port():
            with socket.socket() as s:
                s.bind(("127.0.0.1", 0))
                return s.getsockname()[1]

        p = port()

        async def drop(r, w):
            line = await r.readline()
            w.write(line)
            await w.drain()
            w.close()

        async def main():
            srv = await asyncio.start_server(drop, "127.0.0.1", p)
            out = Path(tempfile.mkdtemp(prefix="tnsb-recon-")) / "ev.jsonl"
            try:
                await tailnet_bench.client("tcp", "127.0.0.1", p, 1.5, str(out), 1.0)
            finally:
                srv.close()
            return [json.loads(x) for x in out.read_text().splitlines() if x.strip()]

        events = asyncio.run(main())
        self.assertGreaterEqual(sum(1 for e in events if e["ev"] == "connect"), 2)
        self.assertGreaterEqual(sum(1 for e in events if e["ev"] == "disconnect"), 1)
        self.assertEqual(events[-1]["ev"], "end")


class Harness(unittest.TestCase):
    def test_shell_syntax(self):
        subprocess.run(["bash", "-n", str(SCRIPT)], check=True)

    def test_python_compiles(self):
        for f in (BENCH_DIR / "tailnet_bench.py", BENCH_DIR / "benches" / "tailnet_stable_node.py"):
            subprocess.run([sys.executable, "-I", "-m", "py_compile", str(f)], check=True)


if __name__ == "__main__":
    unittest.main()
