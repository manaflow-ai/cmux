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


class Breakdown(unittest.TestCase):
    def test_ps_cpu_time_in_every_form(self):
        procs = tput.ps_cpu_seconds("  12 0:01.50 /A.app/Contents/MacOS/cmux\n"
                                    "  34 1:02:03.25 /A.app/Contents/Resources/bin/cmux-tui server\n"
                                    "  56 1-02:00:00.00 x\nnot a line\n")
        self.assertEqual(procs[12], (1.5, "/A.app/Contents/MacOS/cmux"))
        self.assertAlmostEqual(procs[34][0], 3723.25)
        self.assertAlmostEqual(procs[56][0], 26 * 3600)

    def test_sample_threads_and_top_of_stack(self):
        text = ("Call graph:\n"
                "    812 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)\n"
                "    + 812 start  (in dyld) + 1\n"
                "    950 Thread_2: terminal-host-parser\n"
                "\n"
                "Total number in stack (recursive counted multiple times):\n"
                "Sort by top of stack, same collapsed (when >= 5):\n"
                "        stream.Stream.nextSlice  (in cmux-tui)        640\n"
                "        mach_msg2_trap  (in libsystem_kernel.dylib)        300\n"
                "\n"
                "Binary Images:\n")
        got = tput.sample_summary(text)
        self.assertEqual(got["threads"][0], [950, "Thread_2: terminal-host-parser"])
        self.assertEqual(got["top_of_stack"][0], ["stream.Stream.nextSlice (in cmux-tui)", 640])
        self.assertEqual(len(got["top_of_stack"]), 2)


if __name__ == "__main__":
    unittest.main()
