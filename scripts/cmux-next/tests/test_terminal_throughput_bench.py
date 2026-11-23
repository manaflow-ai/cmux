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

    def test_the_sgr_block_changes_color_on_every_character(self):
        a = tput.sgr_payload_block()
        self.assertEqual(a, tput.sgr_payload_block())
        text = a.decode()
        visible = tput.re.sub(r"\x1b\[[0-9;]*m", "", text)
        self.assertNotIn("\x1b", visible, "no escape byte is itself wrapped in a color change")
        self.assertEqual(text.count("\x1b[38;5;"), len(visible.replace("\n", "")))

    def test_the_sgr_file_is_exactly_the_asked_size(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "p")
            self.assertEqual(tput.write_payload(path, 2, "sgr"), 2 * tput.MB)
            self.assertEqual(os.path.getsize(path), 2 * tput.MB)


class Rows(unittest.TestCase):
    def test_both_rates_and_their_ratio(self):
        rows = {r["name"]: r for r in tput.report_rows(150.0, 300.0)}
        self.assertEqual(rows["terminal.throughput.next_mb_s"]["p95"], 150.0)
        self.assertEqual(rows["terminal.throughput.ghostty_mb_s"]["unit"], "MB/s")
        self.assertEqual(rows["terminal.throughput.ratio"]["p95"], 0.5)
        self.assertTrue(all(r["budget"] is None for r in rows.values()), "reporting only")

    def test_the_sgr_arm_has_its_own_row_names(self):
        names = [r["name"] for r in tput.report_rows(150.0, 300.0, None, tput.ROW_PREFIX["sgr"])]
        self.assertEqual(names, ["terminal.throughput_sgr.next_mb_s", "terminal.throughput_sgr.ghostty_mb_s",
                                 "terminal.throughput_sgr.ratio"])

    def test_no_ratio_without_ghostty(self):
        self.assertEqual([r["name"] for r in tput.report_rows(150.0, None)], ["terminal.throughput.next_mb_s"])

    def test_median_of_runs_skips_failed_ones(self):
        self.assertEqual(tput.summarize([{"mb_s": 10.0}, {"error": "no result"}, {"mb_s": 30.0}, {"mb_s": 20.0}]), 20.0)
        self.assertIsNone(tput.summarize([{"error": "no result"}]))


class Interrupt(unittest.TestCase):
    def test_a_run_is_the_key_to_the_signal_and_the_signal_to_the_drain(self):
        rec = tput.interrupt_record(1, 100.0, {"signal_at": 100.0125, "drained_at": 100.2125, "bytes": 9})
        self.assertEqual((rec["key_to_signal_ms"], rec["signal_to_drained_ms"], rec["flood_bytes"]), (12.5, 200.0, 9))

    def test_a_run_without_a_flood_or_a_result_says_so(self):
        self.assertEqual(tput.interrupt_record(2, None, None)["error"], "no flood")
        self.assertEqual(tput.interrupt_record(3, 1.0, {"signal_at": 1.1})["error"], "no result")

    def test_rows_are_the_median_and_the_worst_of_the_good_runs(self):
        runs = [{"key_to_signal_ms": 10.0, "signal_to_drained_ms": 5.0}, {"error": "no result"},
                {"key_to_signal_ms": 30.0, "signal_to_drained_ms": 50.0}, {"key_to_signal_ms": 20.0, "signal_to_drained_ms": 7.0}]
        rows = {r["name"]: r for r in tput.report_rows(150.0, 300.0, runs)}
        k = rows["terminal.interrupt.key_to_signal_ms"]
        self.assertEqual((k["p50"], k["p95"], k["n"], k["unit"], k["budget"]), (20.0, 30.0, 3, "ms", None))
        self.assertEqual(rows["terminal.interrupt.signal_to_drained_ms"]["p95"], 50.0)
        self.assertIn("terminal.throughput.ratio", rows)

    def test_no_interrupt_rows_without_a_good_run(self):
        self.assertEqual(tput.interrupt_rows([{"error": "no flood"}]), [])
        self.assertEqual(tput.interrupt_rows(None), [])

    def test_the_flooder_stops_on_ctrl_c_through_a_pty(self):
        """FLOODER on a real PTY: its line discipline turns the 0x03 byte into SIGINT, the flood stops and drains."""
        import pty, select, sys, time
        with tempfile.TemporaryDirectory() as d:
            flooder, payload, result = (os.path.join(d, n) for n in ("f.py", "p", "r.json"))
            with open(flooder, "w") as f:
                f.write(tput.FLOODER)
            tput.write_payload(payload, 2)
            pid, master = pty.fork()
            if pid == 0:
                os.execv(sys.executable, [sys.executable, "-I", flooder, payload, result])
            read = 0
            def pump(until, seconds):
                nonlocal read
                deadline = time.monotonic() + seconds
                while not until() and time.monotonic() < deadline:
                    if select.select([master], [], [], 0.05)[0]:
                        try:
                            read += len(os.read(master, 1 << 16))
                        except OSError:
                            return
            pump(lambda: os.path.exists(result + ".started"), 30)
            self.assertTrue(os.path.exists(result + ".started"))
            sent_at = time.time()
            os.write(master, b"\x03")
            pump(lambda: os.path.exists(result), 30)
            os.waitpid(pid, 0)
            os.close(master)
            with open(result) as f:
                rec = tput.interrupt_record(1, sent_at, __import__("json").load(f))
            self.assertGreaterEqual(rec["key_to_signal_ms"], 0)
            self.assertLess(rec["key_to_signal_ms"], 5000)
            self.assertGreaterEqual(rec["signal_to_drained_ms"], 0)
            self.assertGreaterEqual(rec["flood_bytes"], 1 << 20)


class Arms(unittest.TestCase):
    def test_an_arm_is_a_label_and_app_launch_variables(self):
        self.assertEqual(tput.parse_arm("base:CMUX_NEXT_TUI_X=0,CMUX_NEXT_Y=a=b"),
                         ("base", {"CMUX_NEXT_TUI_X": "0", "CMUX_NEXT_Y": "a=b"}))

    def test_only_variables_that_reach_the_app_are_taken(self):
        for bad in ("base", "base:", ":CMUX_NEXT_X=0", "base:CMUX_TUI_X=0", "base:CMUX_NEXT_X", "a b:CMUX_NEXT_X=1"):
            with self.assertRaises(ValueError, msg=bad):
                tput.parse_arm(bad)


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


tspec = importlib.util.spec_from_file_location("tput_trace", os.path.join(HERE, "..", "terminal_throughput_trace.py"))
trace = importlib.util.module_from_spec(tspec)
tspec.loader.exec_module(trace)

MS = 1_000_000  # the fixture's times are in ms
WRITER_T = "Main Thread 0x10 (Python, pid: 50)"
READER_T = "Thread 0x20 (cmux DEV x, pid: 60)"
OTHER_T = "Thread 0x30 (Finder, pid: 70)"
# The shape `xctrace export --xpath ...table[@schema=...]` writes: the schema's columns, then rows whose cells repeat
# earlier values by ref.
STATES = f"""<?xml version="1.0"?><trace-query-result><node><schema name="thread-state">
<col><mnemonic>start</mnemonic><engineering-type>start-time</engineering-type></col>
<col><mnemonic>duration</mnemonic><engineering-type>duration</engineering-type></col>
<col><mnemonic>thread</mnemonic><engineering-type>thread</engineering-type></col>
<col><mnemonic>state</mnemonic><engineering-type>thread-state</engineering-type></col>
</schema>
<row><start-time id="1">{1000 * MS}</start-time><duration id="2">{1000 * MS}</duration><thread id="3" fmt="{WRITER_T}"><tid>16</tid></thread><thread-state id="4" fmt="Running">Running</thread-state></row>
<row><start-time>{2000 * MS}</start-time><duration>{500 * MS}</duration><thread ref="3"/><thread-state id="5" fmt="Blocked">Blocked</thread-state></row>
<row><start-time>{2500 * MS}</start-time><duration ref="2"/><thread ref="3"/><thread-state ref="4"/></row>
<row><start-time>{0 * MS}</start-time><duration>{10000 * MS}</duration><thread id="6" fmt="{READER_T}"/><thread-state ref="5"/></row>
<row><start-time>{0 * MS}</start-time><duration>{3000 * MS}</duration><thread fmt="{OTHER_T}"/><thread-state ref="4"/></row>
<row><sentinel/><sentinel/><thread ref="6"/><thread-state ref="4"/></row>
</node></trace-query-result>"""
CALLS = f"""<?xml version="1.0"?><trace-query-result><node><schema name="syscall">
<col><mnemonic>start</mnemonic><engineering-type>start-time</engineering-type></col>
<col><mnemonic>duration</mnemonic><engineering-type>duration</engineering-type></col>
<col><mnemonic>thread</mnemonic><engineering-type>thread</engineering-type></col>
<col><mnemonic>syscall</mnemonic><engineering-type>syscall</engineering-type></col>
<col><mnemonic>return</mnemonic><engineering-type>syscall-return</engineering-type></col>
</schema>
<row><start-time>{1000 * MS}</start-time><duration>{400 * MS}</duration><thread id="1" fmt="{WRITER_T}"/><syscall id="2" fmt="write">write</syscall><syscall-return fmt="65536">65536</syscall-return></row>
<row><start-time>{2600 * MS}</start-time><duration>{900 * MS}</duration><thread ref="1"/><syscall ref="2"/><syscall-return fmt="65536">65536</syscall-return></row>
<row><start-time>{1500 * MS}</start-time><duration>{1000 * MS}</duration><thread fmt="{READER_T}"/><syscall fmt="read">read</syscall><syscall-return fmt="8192 (0x2000)"/></row>
</node></trace-query-result>"""


class Trace(unittest.TestCase):
    def summary(self):
        with tempfile.TemporaryDirectory() as d:
            paths = {}
            for schema, text in (("thread-state", STATES), ("syscall", CALLS)):
                paths[schema] = os.path.join(d, schema + ".xml")
                with open(paths[schema], "w") as f:
                    f.write(text)
            return trace.summarize_exports(paths, lambda name: "cmux" in name or tput.is_python(name), tput.is_python)

    def test_the_window_is_the_writers_first_to_last_run(self):
        got = self.summary()
        self.assertEqual(got["writer_pid"], 50)
        self.assertEqual(got["window_s"], 2.5)  # 1000..3500 ms
        self.assertEqual(got["rows"], {"thread_state": 4, "syscall": 3, "samples": 0})  # Finder and the sentinel row out

    def test_states_and_calls_are_clipped_to_the_window_per_thread(self):
        threads = {t["thread"]: t for t in self.summary()["threads"]}
        self.assertNotIn(OTHER_T, threads, "processes outside the terminal are left out")
        writer = threads[WRITER_T]
        self.assertEqual(writer["running_pct"], 80.0)
        self.assertEqual(writer["calls"]["write"], {"count": 2, "wall_ms": 1300.0, "blocked_pct": 52.0,
                                                    "bytes": 131072, "mb_s": 0.1, "bytes_per_call": 65536})
        reader = threads[READER_T]
        self.assertEqual(reader["states_ms"], {"Blocked": 2500.0})
        self.assertEqual(reader["calls"]["read"]["bytes_per_call"], 8192, "a return read from its fmt")
        self.assertEqual(reader["calls"]["read"]["blocked_pct"], 40.0)

    def test_hop_lines_list_each_io_row_with_bytes(self):
        lines = trace.hop_lines(self.summary())
        self.assertEqual(len(lines), 2)
        self.assertIn("| write |", lines[0])
        self.assertIn("8192 B/call", lines[1])

    def test_thread_names(self):
        self.assertEqual(trace.thread_process(READER_T), "cmux DEV x")
        self.assertEqual(trace.thread_pid(READER_T), 60)

class Installed(unittest.TestCase):
    """--installed (terminal-throughput-quick.sh): a side copy of an installed app, remade only when needed."""

    def test_a_copy_of_the_same_app_and_version_is_reused(self):
        with tempfile.TemporaryDirectory() as d:
            marker = {"app": d, "from": "/Applications/cmux NIGHTLY.app", "version": "571", "socket": "/x.sock"}
            self.assertTrue(tput.side_copy_current(marker, "/Applications/cmux NIGHTLY.app", "571"))
            self.assertFalse(tput.side_copy_current(marker, "/Applications/cmux NIGHTLY.app", "572"), "a new nightly")
            self.assertFalse(tput.side_copy_current(marker, "/Applications/cmux NEXT.app", "571"), "another app")
            self.assertFalse(tput.side_copy_current(dict(marker, app=d + "/gone"), "/Applications/cmux NIGHTLY.app", "571"))
            self.assertFalse(tput.side_copy_current({}, "/Applications/cmux NIGHTLY.app", "571"), "no copy yet")
            self.assertFalse(tput.side_copy_current(marker, "/Applications/cmux NIGHTLY.app", None), "no version read")

    def test_the_marker_is_read_from_the_side_root(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "tt-bench"))
            with open(os.path.join(d, "tt-bench", ".side-instance"), "w") as f:
                f.write("app=/r/cmux tt-bench.app\nfrom=/Applications/cmux NIGHTLY.app\nversion=9\nsocket=/r/c.sock\n")
            old = os.environ.get("CMUX_SIDE_ROOT")
            os.environ["CMUX_SIDE_ROOT"] = d
            try:
                got = tput.side_marker("tt-bench")
                self.assertEqual((got["app"], got["version"], got["socket"]), ("/r/cmux tt-bench.app", "9", "/r/c.sock"))
                self.assertEqual(tput.side_marker("none"), {})
            finally:
                if old is None:
                    del os.environ["CMUX_SIDE_ROOT"]
                else:
                    os.environ["CMUX_SIDE_ROOT"] = old

    def refused(self, argv):
        with self.assertRaises(SystemExit) as raised, open(os.devnull, "w") as null:
            import contextlib
            with contextlib.redirect_stderr(null):
                tput.main(argv)
        return raised.exception.code

    def test_one_of_app_or_installed(self):
        self.assertEqual(self.refused(["--out", "/tmp/x"]), 2)
        self.assertEqual(self.refused(["--app", "a", "--installed", "b", "--out", "/tmp/x"]), 2)

    def test_installed_refuses_an_arm_and_a_missing_app(self):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, "x.app", "Contents"))
            open(os.path.join(d, "x.app", "Contents", "Info.plist"), "w").close()
            self.assertEqual(self.refused(["--installed", os.path.join(d, "x.app"), "--out", d,
                                           "--next-arm", "a:CMUX_NEXT_X=0"]), 2)
            self.assertEqual(self.refused(["--installed", os.path.join(d, "none.app"), "--out", d]), 2)


if __name__ == "__main__":
    unittest.main()
