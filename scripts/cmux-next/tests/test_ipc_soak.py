#!/usr/bin/env python3
"""ipc-soak.py without an app: the printer's pacing and report, the counter reads over either server-stats layout,
the daemon reader's socket lookup, the sampling window, the per-phase numbers and the capacity verdict (keep only
with every number, raise only with a healthy app, inconclusive otherwise), and the section 9 row.
Run: python3 -I scripts/cmux-next/tests/test_ipc_soak.py"""
import importlib.util, json, os, shlex, sys, tempfile, types, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("ipc_soak", os.path.join(HERE, "..", "ipc-soak.py"))
soak = importlib.util.module_from_spec(spec)
spec.loader.exec_module(soak)


class FakeClock:
    """A sleep advances the clock; a write takes `write_s` seconds (a terminal that reads slowly)."""

    def __init__(self, write_s=0.0):
        self.now, self.write_s, self.written = 0.0, write_s, 0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += max(seconds, 1e-6)

    def write(self, data):
        self.now += self.write_s
        self.written += len(data)
        return len(data)


def samples(rows, start=0.0, every=5.0):
    """Samples from (resyncs, laps, copied) rows, every `every` s, healthy unless a row says otherwise."""
    out = []
    for index, row in enumerate(rows):
        resyncs, laps, copied, *rest = row
        extra = rest[0] if rest else {}
        out.append({"t": start + index * every, "alive": True, "ping_ms": 3.0, "daemon_pid": 7, "daemon_error": None,
                    "ring_resyncs": resyncs, "ring_laps": laps, "ring_capacity": None, "copied_bytes": copied,
                    **extra})
    return out


def printer(rate, reached=1.0, seconds=600):
    return {"target_bytes_per_s": rate, "bytes": int(rate * reached * seconds), "seconds": seconds,
            "bytes_per_s": int(rate * reached)}


def minutes_of_zero(minutes=10, copied=0):
    return samples([(0, 0, copied)] * (minutes * 12 + 1))


class FloodTests(unittest.TestCase):
    def test_paces_to_the_rate_and_reports_it(self):
        clock = FakeClock()
        with tempfile.TemporaryDirectory() as folder:
            report = os.path.join(folder, "p.json")
            result = soak.flood(10 * soak.MB, 3, report, write=clock.write, clock=clock.monotonic, sleep=clock.sleep)
            with open(report) as handle:
                self.assertEqual(json.load(handle), result)
        # 3 s at 10 MB/s, one block of rounding at most.
        self.assertLessEqual(abs(clock.written - 30 * soak.MB), soak.BLOCK)
        self.assertGreaterEqual(result["bytes_per_s"] / result["target_bytes_per_s"], soak.RATE_FLOOR)

    def test_a_slow_terminal_shows_in_the_report(self):
        # Each 64 KiB write blocks 10 ms: at most 6.5 MB/s, under a 50 MB/s target.
        clock = FakeClock(write_s=0.01)
        with tempfile.TemporaryDirectory() as folder:
            result = soak.flood(50 * soak.MB, 2, os.path.join(folder, "p.json"), write=clock.write,
                                clock=clock.monotonic, sleep=clock.sleep)
        self.assertLess(result["bytes_per_s"] / result["target_bytes_per_s"], 0.2)

    def test_block_is_plain_text_lines(self):
        block = soak.flood_block()
        self.assertEqual(len(block), soak.BLOCK)
        self.assertNotIn(b"\x1b", block)
        self.assertTrue(all(32 <= b < 127 or b == 10 for b in block))

    def test_command_quotes_paths_and_ends_with_return(self):
        line = soak.flood_command("/opt/py thon/python3", "/repo/scripts/cmux-next/ipc-soak.py", 5e7, 610.0,
                                  "/out/stress dir/printer-0.json")
        self.assertTrue(line.endswith("\r"))
        argv = shlex.split(line[:-1])
        self.assertEqual(argv, ["/opt/py thon/python3", "-I", "/repo/scripts/cmux-next/ipc-soak.py", "flood",
                                "--rate", "50000000", "--seconds", "610", "--report", "/out/stress dir/printer-0.json"])


class CounterTests(unittest.TestCase):
    def test_top_level_wins_over_nested(self):
        section = {"ring_resyncs": 4, "connections": [{"ring_resyncs": 1}, {"ring_resyncs": 3}]}
        self.assertEqual(soak.read_counter(section, "ring_resyncs"), 4)

    def test_sums_per_connection_and_per_stream(self):
        section = {"connections": [{"streams": [{"ring_resyncs": 1}, {"ring_resyncs": 2}]}, {"ring_resyncs": 5},
                                   {"other": 9}]}
        self.assertEqual(soak.read_counter(section, "ring_resyncs"), 8)

    def test_missing_is_none_not_zero(self):
        self.assertIsNone(soak.read_counter({"connections": [{"frames": 3}]}, "ring_resyncs"))
        self.assertIsNone(soak.read_counter(None, "ring_resyncs"))
        self.assertIsNone(soak.read_counter({"ring_resyncs": True}, "ring_resyncs"))

    def test_daemon_reader_finds_the_socket_again_after_a_failure(self):
        calls = []
        sockets = iter(["/s1", "/s2"])

        def status(binary, tag):
            calls.append(("status", binary, tag))
            return {"socket": next(sockets)}

        broken = {"once": True}

        def request(path, body, timeout):
            calls.append((path, body["cmd"]))
            if body["cmd"] == "identify":
                return {"ok": True, "data": {"pid": 11 if path == "/s1" else 12}}
            if path == "/s1" and broken.pop("once", False):
                raise ConnectionError("closed")
            return {"ok": True, "data": {"ipc": {"ring_resyncs": 2}}}

        read = soak.daemon_reader("/b/cmux-tui", "t", status=status, request=request)
        self.assertEqual(read(), {"error": "closed"})
        self.assertEqual(read(), {"pid": 12, "ipc": {"ring_resyncs": 2}})
        self.assertEqual([c for c in calls if c[0] == "status"], [("status", "/b/cmux-tui", "t")] * 2)
        self.assertIn(("/s2", "server-stats"), calls)

    def test_sample_reads_both_sides_and_a_failed_ping_is_none(self):
        clock = FakeClock()

        def rpc(method, timeout=60):
            clock.now += 0.004
            if method == "system.ping":
                return {"error": "timeout"}
            return {"connections": [{"outputBytesCopiedApp": 10}, {"outputBytesCopiedApp": 5}]}
        row = soak.sample(rpc, lambda: {"pid": 3, "ipc": {"ring_resyncs": 1, "ring_laps": 0, "ring_capacity": 1 << 20}},
                          lambda: True, clock=clock.monotonic)
        self.assertIsNone(row["ping_ms"])
        self.assertEqual((row["ring_resyncs"], row["ring_laps"], row["ring_capacity"], row["copied_bytes"]),
                         (1, 0, 1 << 20, 15))

    def test_sample_for_covers_the_window_and_stops_when_the_app_exits(self):
        clock = FakeClock()
        rows = soak.sample_for(60, 5, lambda: {"t": clock.now, "alive": True}, clock=clock.monotonic, sleep=clock.sleep)
        self.assertEqual(rows[0]["t"], 0)
        self.assertAlmostEqual(rows[-1]["t"], 60, places=3)
        self.assertEqual(len(rows), 13)
        clock = FakeClock()
        rows = soak.sample_for(60, 5, lambda: {"t": clock.now, "alive": clock.now < 12}, clock=clock.monotonic,
                               sleep=clock.sleep)
        self.assertFalse(rows[-1]["alive"])
        self.assertLess(rows[-1]["t"], 60)


class VerdictTests(unittest.TestCase):
    def phase(self, name, rows, printers):
        return soak.phase_summary(name, rows, printers, 250)

    def test_zero_resyncs_everywhere_keeps_the_capacity(self):
        phases = [self.phase("stress", minutes_of_zero(), [printer(10 * soak.MB)] * 10),
                  self.phase("cat", minutes_of_zero(), [printer(50 * soak.MB)])]
        self.assertEqual(phases[0]["resyncs_per_min"], 0)
        self.assertEqual(phases[0]["minutes"], 10)
        self.assertEqual(soak.capacity_verdict(phases)["capacity"], "keep")

    def test_resyncs_with_a_healthy_app_raise_with_the_number(self):
        rows = samples([(0, 0, 0)] * 13 + [(3, 1, 0)] * 12)  # 3 resyncs between 60 s and 65 s: minute 2 of 2
        stress = self.phase("stress", rows, [printer(10 * soak.MB)] * 10)
        self.assertEqual(stress["ring_resyncs"], 3)
        self.assertEqual(stress["resyncs_per_min"], 1.5)
        self.assertEqual(stress["resyncs_by_minute"], [0, 3])
        verdict = soak.capacity_verdict([stress, self.phase("cat", minutes_of_zero(2), [printer(50 * soak.MB)])])
        self.assertEqual(verdict["capacity"], "raise")
        self.assertIn("1.5 ring resyncs/min in stress", verdict["reason"])

    def test_resyncs_while_the_app_hangs_change_nothing(self):
        rows = samples([(0, 0, 0)] * 6 + [(5, 0, 0, {"ping_ms": 900.0})] + [(5, 0, 0)] * 6)
        verdict = soak.capacity_verdict([self.phase("stress", rows, [printer(10 * soak.MB)])])
        self.assertEqual(verdict["capacity"], "inconclusive")
        self.assertIn("1 pings over 250 ms", verdict["reason"])

    def test_missing_counters_never_read_as_zero(self):
        rows = samples([(None, None, None)] * 13)
        phase = self.phase("cat", rows, [printer(50 * soak.MB)])
        self.assertIsNone(phase["resyncs_per_min"])
        verdict = soak.capacity_verdict([phase])
        self.assertEqual(verdict["capacity"], "inconclusive")
        self.assertIn("ring_resyncs", verdict["reason"])
        self.assertIn("outputBytesCopiedApp", verdict["reason"])

    def test_copied_output_means_the_floods_missed_the_ring(self):
        flood = printer(50 * soak.MB)
        rows = samples([(0, 0, 0)] * 12 + [(0, 0, flood["bytes"] // 2)])
        verdict = soak.capacity_verdict([self.phase("cat", rows, [flood])])
        self.assertEqual(verdict["capacity"], "inconclusive")
        self.assertIn("did not go through the ring", verdict["reason"])

    def test_a_daemon_restart_or_a_counter_reset_is_a_failed_run(self):
        rows = samples([(4, 0, 0)] * 6 + [(0, 0, 0, {"daemon_pid": 8})] * 7)
        phase = self.phase("stress", rows, [printer(10 * soak.MB)])
        self.assertIsNone(phase["ring_resyncs"])
        reason = soak.capacity_verdict([phase])["reason"]
        self.assertIn("daemon restarted", reason)
        self.assertIn("went back", reason)

    def test_a_slow_printer_cannot_keep_but_resyncs_still_raise(self):
        slow = [printer(50 * soak.MB, reached=0.5)]
        verdict = soak.capacity_verdict([self.phase("cat", minutes_of_zero(), slow)])
        self.assertEqual(verdict["capacity"], "inconclusive")
        self.assertIn("0.5 of their rate", verdict["reason"])
        rows = samples([(0, 0, 0)] * 12 + [(2, 0, 0)])
        self.assertEqual(soak.capacity_verdict([self.phase("cat", rows, slow)])["capacity"], "raise")

    def test_a_printer_without_a_report_counts_as_not_at_rate(self):
        phase = self.phase("stress", minutes_of_zero(), [printer(10 * soak.MB), None])
        self.assertEqual(phase["rate_reached"], [1.0, 0.0])
        self.assertFalse(phase["rates_ok"])


class RowTests(unittest.TestCase):
    def test_row_has_host_sha_hz_both_phases_and_the_command(self):
        opts = types.SimpleNamespace(cat_mb=50.0, flood_mb=10.0, flood=10)
        phases = [soak.phase_summary("stress", minutes_of_zero(), [printer(10 * soak.MB)] * 10, 250),
                  soak.phase_summary("cat", minutes_of_zero(), [printer(50 * soak.MB)], 250)]
        host = {"chip": "Apple M4 Pro", "macos": "26.5", "macos_build": "25F71", "display_hz": 120}
        command = soak.shown_command(["--app", "/x/cmux DEV t.app", "--out=/tmp/o", "--minutes", "10", "--flood", "10"])
        self.assertEqual(command, "python3 scripts/cmux-next/ipc-soak.py --app $APP --out=$OUT --minutes 10 --flood 10")
        row = soak.section9_row("2026-10-26", host, "0123456789abcdef" * 2, phases, soak.capacity_verdict(phases),
                                opts, command)
        cells = [c.strip() for c in row.strip("|").split("|")]
        self.assertEqual(len(cells), 6)
        self.assertEqual(cells[0], "2026-10-26")
        self.assertEqual(cells[2], "Apple M4 Pro, macOS 26.5 (25F71) / 0123456789a / 120 Hz")
        self.assertTrue(cells[3].startswith("50 MB/s: 0.0 ring resyncs/min over 10.0 min"))
        self.assertTrue(cells[4].startswith("10 x 10 MB/s: 0.0 ring resyncs/min"))
        self.assertIn("capacity 1 MiB: keep", cells[5])
        self.assertIn(command, cells[5])

    def test_options_refuse_unknown_phases(self):
        with open(os.devnull, "w") as quiet:
            stderr, sys.stderr = sys.stderr, quiet
            try:
                with self.assertRaises(SystemExit):
                    soak.parse(["--app", "/a", "--phases", "stress,typing", "--out", tempfile.gettempdir()])
            finally:
                sys.stderr = stderr
        opts = soak.parse(["--app", "/a", "--out", tempfile.gettempdir(), "--app-env", "CMUX_X=1"])
        self.assertEqual((opts.phases, opts.minutes, opts.flood, opts.app_env), (["stress", "cat"], 10, 10, [("CMUX_X", "1")]))


if __name__ == "__main__":
    unittest.main()
