#!/usr/bin/env python3
"""snappy-bench.py's offline halves: the perf watch's send spans to snappy-bench/v1 rows, and its perf-cron rows."""
import importlib.util, json, os, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.join(HERE, "..", "snappy-bench.py")


def span(name, ms, parts=(), detail=None):
    return {"kind": "span", "name": name, "ms": ms, "budgetMs": 16, "over": ms > 16,
            "parts": [{"name": n, "startMs": s, "ms": d} for n, s, d in parts], "detail": {"page": "agent", "detail": detail or {}}}


class Summarize(unittest.TestCase):
    def run_summary(self, events):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "perf-watch.jsonl")
            with open(path, "w") as f:
                for e in events:
                    f.write(json.dumps(e) + "\n")
                f.write("not json\n")
            out = subprocess.run([sys.executable, BENCH, "--summarize", path], capture_output=True, text=True, timeout=60)
        return out.returncode, json.loads(out.stdout.strip().splitlines()[-1])

    def test_spans_become_rows_per_transport(self):
        code, got = self.run_summary([
            span("send", 9, [("user row painted", 0, 9), ("reserved turn painted", 0, 9), ("first token", 0, 400)],
                 {"transport": "local", "shifts": 0, "sameFrame": True, "firstTokenMs": 400}),
            span("send", 30, [("user row painted", 0, 30), ("reserved turn painted", 30, 20)],
                 {"transport": "local", "shifts": 2, "sameFrame": False, "firstTokenMs": 600}),
            span("send", 12, [("user row painted", 0, 12)], {"transport": "cloud", "shifts": 1, "firstTokenMs": 41000}),
            span("chat switch", 14),
            {"kind": "note", "name": "send"},
        ])
        self.assertEqual(code, 0)
        by = {r["transport"]: r for r in got["reports"]}
        local, cloud = by["local"]["rows"], by["cloud"]["rows"]
        self.assertEqual(local["sends"], 2)
        self.assertEqual(local["send_paint_p95_ms"], 28.9)
        self.assertEqual(local["reserved_same_frame_share"], 0.5)
        self.assertEqual(local["shifts_per_send_max"], 2)
        self.assertEqual(local["chat_switch_paint_p95_ms"], 14)
        self.assertEqual(cloud["send_first_token_p50_ms"], 41000)
        self.assertEqual(by["cloud"]["surface"], "cloud")
        self.assertEqual(by["local"]["mode"], "passive")

    def test_no_spans_exits_nonzero(self):
        code, got = self.run_summary([{"kind": "meter"}])
        self.assertEqual(code, 1)
        self.assertEqual(got["reports"], [])


class CronRows(unittest.TestCase):
    def test_rows_carry_the_snappy_targets(self):
        # The module runs its bench at import; read the two pure functions out of its source instead.
        source = open(BENCH).read()
        start, end = source.index("def pct("), source.index("def git_sha(")
        scope = {"FRAME_MS": 16.0}
        exec(source[start:end], scope)  # noqa: S102 (the bench's own functions, under test)
        rows = scope["rows_of"]([{"userPaintMs": 8, "sameFrame": True, "reservedPaintMs": 8, "shifts": 0, "firstTokenMs": 300},
                                 {"userPaintMs": 20, "sameFrame": False, "reservedPaintMs": 40, "shifts": 1, "firstTokenMs": 500},
                                 {"error": "page lost"}], [{"visibleToPaintMs": 10}])
        cron = {r["name"]: r for r in scope["cron_rows"]([{"duress": "long-session", "rows": rows}])}
        self.assertEqual(cron["chat_snappy.long_session.send_paint"]["budget"], 16.0)
        self.assertEqual(cron["chat_snappy.long_session.reserved_late_sends"]["p95"], 1)
        self.assertEqual(cron["chat_snappy.long_session.shifts_per_send"]["budget"], 0)
        self.assertEqual(cron["chat_snappy.long_session.failed_sends"]["p95"], 1)
        self.assertIsNone(cron["chat_snappy.long_session.send_first_token"]["budget"])


if __name__ == "__main__":
    unittest.main()
