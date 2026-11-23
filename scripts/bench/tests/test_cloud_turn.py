"""cloud-turn: a real turn_overhead.rs run of both routes back to back (lane VM, 100 turns, 2026-11-19) -> rows."""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.cloud_turn import BENCH  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "cloud-turn"
TURN = ["send", "harness", "store", "deliver", "render", "turn", "shown"]
ATTACH = ["attach_connect", "attach_first_frame"]


def ingest(path):
    ctx = Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "d" * 40}, host_role="fleet",
                  timestamp="2026-11-19T00:00:00Z")
    BENCH.ingest(ctx, path)
    return ctx


def by_route(ctx):
    rows = {}
    for row in ctx.rows:
        rows.setdefault(row["labels"]["route"], {})[row["metric"]] = row
    return rows


class CloudTurnTest(unittest.TestCase):
    def test_both_routes_every_stage_in_ms(self):
        rows = by_route(ingest(FIXTURES / "cloud-turn.log"))
        self.assertEqual(list(rows), ["local", "relay"])
        self.assertEqual(list(rows["local"]), TURN + ATTACH)
        self.assertEqual(list(rows["relay"]),
                         ["send", "relay_in", "harness", "store", "relay_out", "deliver", "render", "turn", "shown",
                          "attach_connect", "attach_handshake", "attach_first_frame"])
        for route in rows.values():
            self.assertEqual(route["turn"]["n"], 100)
            self.assertEqual(route["turn"]["unit"], "ms")
        self.assertEqual(rows["relay"]["attach_handshake"]["n"], 20)

    def test_an_actions_log_line_keeps_its_time_stamp(self):
        lines = [l for l in (FIXTURES / "cloud-turn.log").read_text().splitlines() if l.startswith("CLOUD-TURN ")]
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / "job.log"
            log.write_text("".join(f"2026-11-19T10:00:00.1234567Z {line}\n" for line in lines))
            self.assertEqual(set(by_route(ingest(log))), {"local", "relay"})

    def test_a_log_without_the_line_says_so(self):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / "empty.log"
            log.write_text("error: could not compile\n")
            with self.assertRaises(BenchError):
                ingest(log)


if __name__ == "__main__":
    unittest.main()
