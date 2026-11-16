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

    def test_sample_top_of_stack_leaves_the_idle_waits_out(self):
        text = ("Call graph:\n"
                "    800 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)\n"
                "    + 800 start  (in dyld) + 1\n"
                "    800 Thread_2: terminal-host-parser\n"
                "\n"
                "Total number in stack (recursive counted multiple times):\n"
                "Sort by top of stack, same collapsed (when >= 5):\n"
                "        mach_msg2_trap  (in libsystem_kernel.dylib)        900\n"
                "        stream.Stream.nextSlice  (in cmux-tui)        600\n"
                "        __psynch_cvwait  (in libsystem_kernel.dylib)        300\n"
                "        writev  (in libsystem_kernel.dylib)        200\n"
                "\n"
                "Binary Images:\n")
        got = tput.sample_summary(text)
        self.assertEqual(got["top_of_stack"], [["stream.Stream.nextSlice (in cmux-tui)", 600],
                                               ["writev (in libsystem_kernel.dylib)", 200]])
        self.assertEqual(got["samples_per_thread"], 800)
        self.assertEqual(got["busy_cores"], 1.0)

    def test_thread_times_from_ps_m(self):
        text = ("USER   PID   TT  %CPU STAT PRI     STIME     UTIME COMMAND\n"
                "ci   69881   ??  98.0 R    47T   0:01.20   0:10.30 /A b.app/Contents/MacOS/cmux -x\n"
                "            69881         0.0 S    31T   0:00.01   0:00.02\n"
                "            69881        12.0 S    46T   1:00.50   0:00.50\n")
        self.assertEqual([round(t, 2) for t in tput.ps_thread_seconds(text)], [11.5, 0.03, 61.0])

    def test_labels_cut_at_the_bundle_not_the_first_space(self):
        app = "/Library/Application Support/w/Release/cmux DEV perf.app/Contents/"
        self.assertEqual(tput.process_label(7, app + "MacOS/cmux"), "MacOS/cmux [7]")
        self.assertEqual(tput.process_label(8, app + "Resources/bin/cmux-tui __terminal-host --fd 3"),
                         "Resources/bin/cmux-tui __terminal-host [8]")
        self.assertEqual(tput.process_label(9, "/usr/bin/python3 -I /tmp/w.py"), "python3 /tmp/w.py [9]")


if __name__ == "__main__":
    unittest.main()
