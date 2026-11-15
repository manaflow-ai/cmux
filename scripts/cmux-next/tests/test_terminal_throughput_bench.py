#!/usr/bin/env python3
"""terminal-throughput-bench.py's pure parts: the payload is the same every run, and the rows the perf cron stores.
Run: python3 -I scripts/cmux-next/tests/test_terminal_throughput_bench.py (not a CI job)."""
import importlib.util, os, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("tput", os.path.join(HERE, "..", "terminal-throughput-bench.py"))
tput = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tput)


class Payload(unittest.TestCase):
    def test_the_block_is_deterministic_and_terminal_text(self):
        a, b = tput.payload_block(), tput.payload_block()
        self.assertEqual(a, b)
        self.assertIn(b"\x1b[38;5;", a)
        self.assertIn("→".encode(), a)
        self.assertTrue(a.endswith(b"\n"))

    def test_the_file_is_exactly_the_asked_size(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "p")
            self.assertEqual(tput.write_payload(path, 3), 3 * tput.MB)
            self.assertEqual(os.path.getsize(path), 3 * tput.MB)


class Rows(unittest.TestCase):
    def test_both_rates_and_their_ratio(self):
        rows = {r["name"]: r for r in tput.report_rows(150.0, 300.0)}
        self.assertEqual(rows["terminal.throughput.next_mb_s"]["p95"], 150.0)
        self.assertEqual(rows["terminal.throughput.ghostty_mb_s"]["unit"], "MB/s")
        self.assertEqual(rows["terminal.throughput.ratio"]["p95"], 0.5)
        self.assertTrue(all(r["budget"] is None for r in rows.values()), "reporting only")

    def test_no_ratio_without_ghostty(self):
        self.assertEqual([r["name"] for r in tput.report_rows(150.0, None)], ["terminal.throughput.next_mb_s"])

    def test_median_of_runs_skips_failed_ones(self):
        self.assertEqual(tput.summarize([{"mb_s": 10.0}, {"error": "no result"}, {"mb_s": 30.0}, {"mb_s": 20.0}]), 20.0)
        self.assertIsNone(tput.summarize([{"error": "no result"}]))


if __name__ == "__main__":
    unittest.main()
