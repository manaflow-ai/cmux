#!/usr/bin/env python3
"""bench_memory.py --cold-scrollback (p07-memory-112): footprint -j (a real capture and shapes) and vm_stat parsing,
the per-terminal arithmetic over the control, the go/no-go against deflate and every `not measured` case, and the
phase's order (control, fill, samples at each idle minute, pressure, the read-back last). Runs on any OS: the app,
its daemon, footprint, vm_stat and memory_pressure are fakes. Local only:
python3 -I scripts/cmux-next/tests/test_bench_memory_cold.py"""

from __future__ import annotations

import io
import json
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import bench_memory as bm  # noqa: E402
import cold_scrollback as cs  # noqa: E402

MB = 1048576
PAGE = 16384
FIXTURE = Path(__file__).resolve().parent / "fixtures" / "footprint-j-macos.json"

VM_STAT = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               12345.
Pages stored in compressor:               {stored}.
Pages occupied by compressor:             {occupied}.
"Translation faults":                     99.
"""


def vm(stored, occupied):
    return cs.parse_vm_stat(VM_STAT.format(stored=stored, occupied=occupied))


def kinds(daemon=(0, 0), holders=0, app=0):
    """group_totals-shaped kinds: the daemon's (dirty, compressed), the holder's and the app's footprint."""
    return {"tui-daemon": {"processes": 1, "dirty": daemon[0], "compressed": daemon[1],
                           "footprint": daemon[0] + daemon[1]},
            "terminal-holder": {"processes": 1, "dirty": holders, "compressed": 0, "footprint": holders},
            "app": {"processes": 1, "dirty": app, "compressed": 0, "footprint": app}}


def sample(daemon=(0, 0), holders=0, app=0, vm_pages=(1000, 500), valid=True, pids=(1,)):
    return {"kinds": kinds(daemon, holders, app), "vm": vm(*vm_pages), "valid": valid, "daemon_pids": list(pids)}


class ParserTests(unittest.TestCase):
    def test_a_real_capture_whose_dirty_includes_swapped(self):
        # fixtures/footprint-j-macos.json: `footprint -j` of chronod and sleep on a fleet Mac (macOS 27.0). chronod's
        # category dirty sum (21,136,272) is its footprint less 32 KB and already holds its 8,060,928 swapped bytes.
        parsed = cs.parse_footprint(json.loads(FIXTURE.read_text()))
        chronod = parsed[456]
        self.assertEqual((chronod["compressed"], chronod["footprint"]), (8_060_928, 21_169_040))
        self.assertEqual(chronod["dirty"], 21_136_272 - 8_060_928)
        self.assertEqual(chronod["rows"], 25)
        self.assertEqual(parsed[19532]["compressed"], 0)
        self.assertEqual(parsed[19532]["dirty"], 1_065_200)

    def test_footprint_with_dirty_apart_from_compressed(self):
        doc = {"processes": [{"pid": 7, "name": "cmux-tui", "footprint": 30 * MB,
                              "categories": {"MALLOC_LARGE": {"dirty": 18 * MB, "swapped": 10 * MB, "clean": 5},
                                             "VM_ALLOCATE": {"dirty": 2 * MB, "swapped": 0},
                                             "TOTAL": {"dirty": 20 * MB, "swapped": 10 * MB}}}]}
        got = cs.parse_footprint(doc)[7]
        self.assertEqual((got["dirty"], got["compressed"], got["footprint"], got["rows"]),
                         (20 * MB, 10 * MB, 30 * MB, 2))

    def test_footprint_of_a_list_shape(self):
        doc = [{"pid": 8, "phys_footprint": 30 * MB, "peak_footprint": 90 * MB,
                "regions": [{"category": "MALLOC_LARGE", "dirty": 30 * MB, "compressed": 12 * MB}]}]
        got = cs.parse_footprint(doc)[8]
        self.assertEqual((got["dirty"], got["compressed"], got["footprint"]), (18 * MB, 12 * MB, 30 * MB))

    def test_footprint_without_category_rows_has_no_rows(self):
        self.assertEqual(cs.parse_footprint({"processes": [{"pid": 9, "footprint": 4}]})[9]["rows"], 0)

    def test_vm_stat_compressor_rows(self):
        self.assertEqual(vm(4000, 1000), {"page_size": PAGE, "stored_pages": 4000, "occupied_pages": 1000})
        self.assertEqual(cs.parse_vm_stat("Pages free: 3.\n")["stored_pages"], None)


class SampleTests(unittest.TestCase):
    def test_a_sample_is_valid_only_with_daemon_category_rows(self):
        kinds_of = {1: "tui-daemon", 2: "app"}
        self.assertEqual(cs.sample_valid({1: {"rows": 3}, 2: {"rows": 0}}, kinds_of), (True, [1]))
        self.assertEqual(cs.sample_valid({1: {"rows": 0}}, kinds_of), (False, [1]))
        self.assertEqual(cs.sample_valid({}, kinds_of), (False, [1]))
        self.assertEqual(cs.sample_valid({2: {"rows": 3}}, {2: "app"}), (False, []))

    def test_a_pid_footprint_missed_counts_as_a_process_with_no_bytes(self):
        totals = cs.group_totals({1: {"dirty": 5, "compressed": 1, "footprint": 6}},
                                 {1: "terminal-host", 2: "terminal-host"})
        self.assertEqual(totals["terminal-host"], {"processes": 2, "dirty": 5, "compressed": 1, "footprint": 6})

    def test_host_model_from_the_processes_opening_added(self):
        base = {"kinds": {"terminal-host": {"processes": 1}}}
        self.assertEqual(cs.host_model_of(base, {"kinds": {"terminal-host": {"processes": 5}}}), "hosts")
        self.assertEqual(cs.host_model_of(base, {"kinds": {"terminal-host": {"processes": 1},
                                                           "terminal-holder": {"processes": 1}}}), "holder")


class ArithmeticTests(unittest.TestCase):
    def test_kernel_ratio_is_ours_when_our_pages_are_most_of_what_was_compressed(self):
        ratio, source = cs.kernel_ratio(vm(1000, 500), vm(1000 + 640, 500 + 160), 640 * PAGE)
        self.assertEqual((ratio, source), (4.0, "delta"))

    def test_kernel_ratio_falls_back_to_the_whole_compressor(self):
        self.assertEqual(cs.kernel_ratio(vm(1000, 500), vm(1000, 500), 0), (2.0, "system"))
        # Someone else's pages dominate what the compressor took in.
        self.assertEqual(cs.kernel_ratio(vm(1000, 500), vm(3000, 1000), PAGE)[1], "system")
        self.assertEqual(cs.kernel_ratio({}, cs.parse_vm_stat(""), 0), (None, "none"))

    def test_idle_point_counts_only_the_scrollback_against_the_kernel(self):
        # 10 terminals; each adds 12 MB to the daemon over the control: 10 MB scrollback (the limit), 2 MB other.
        control = sample(daemon=(100 * MB, 0), holders=10 * MB, app=200 * MB)
        now = sample(daemon=(100 * MB + 3 * 10 * MB, 9 * 10 * MB), holders=10 * MB + 20 * MB, app=210 * MB,
                     vm_pages=(1000 + 90 * MB // PAGE, 500 + 30 * MB // PAGE))
        point = cs.idle_point("cold-pressed-5pct-1", None, control, now, 10)
        self.assertTrue(point["valid"])
        self.assertEqual((point["dirty_bytes"], point["compressed_bytes"]), (3 * MB, 9 * MB))
        self.assertEqual((point["growth_bytes"], point["scrollback_bytes"]), (12 * MB, cs.SCROLLBACK_LIMIT_BYTES))
        self.assertEqual(point["other_bytes"], 12 * MB - cs.SCROLLBACK_LIMIT_BYTES)
        self.assertEqual(point["compressed_share"], 0.75)
        self.assertEqual((point["kernel_ratio"], point["kernel_ratio_source"]), (3.0, "delta"))
        self.assertEqual(point["kernel_now_bytes"], 6 * MB)
        self.assertEqual(point["kernel_cold_bytes"], round(cs.SCROLLBACK_LIMIT_BYTES / 3))
        self.assertEqual((point["holder_footprint_bytes"], point["app_footprint_bytes"]), (2 * MB, MB))

    def test_a_daemon_restart_or_a_failed_sample_is_invalid(self):
        control = sample(daemon=(100 * MB, 0))
        self.assertFalse(cs.idle_point("x", 0, control, sample(daemon=(100 * MB, 0), pids=(2,)), 1)["valid"])
        self.assertFalse(cs.idle_point("x", 0, control, sample(valid=False), 1)["valid"])
        self.assertFalse(cs.idle_point("x", 0, dict(control, valid=False), sample(), 1)["valid"])


def measured_phase(codec=(2 * MB,), **pressed):
    """A phase whose pressed sample keeps 9.54 MB of scrollback at ratio 2 (4.77 MB): every check passes."""
    point = {"label": "cold-pressed-5pct-1", "idle_min": None, "valid": True, "growth_bytes": 12 * MB,
             "kernel_cold_bytes": cs.SCROLLBACK_LIMIT_BYTES // 2, "kernel_ratio_source": "delta",
             "compressed_share": 0.9}
    point.update(pressed)
    return {"errors": [], "terminal_host_model": "holder", "control": {"valid": True},
            "points": [dict(point, label="cold-30min", idle_min=30, compressed_share=0.0)], "pressed": point,
            "codec": [{"rows": 10, "deflate_bytes": size} for size in codec]}


class DecisionTests(unittest.TestCase):
    def test_decision_needs_a_gain_of_two_on_the_pressed_sample(self):
        go = cs.decide(measured_phase(codec=(2_000_000,)))
        self.assertEqual((go["go"], go["gain"], go["measured"], go["sample"]), (True, 2.5, True, "cold-pressed-5pct-1"))
        no = cs.decide(measured_phase(codec=(3 * MB, 3 * MB)))
        self.assertEqual((no["go"], no["gain"], no["codec_samples"]), (False, 1.59, 2))
        self.assertTrue(no["reason"].startswith("no-go: deflate keeps"))

    def test_every_doubt_is_not_measured_and_never_a_gain(self):
        cases = {
            "terminal errors": dict(errors=["terminal 3: no COLD-DONE-3 within 1800 s"]),
            "second VT copy": dict(terminal_host_model="hosts"),
            "no daemon category rows": dict(control={"valid": False}),
        }
        for why, change in cases.items():
            with self.subTest(why):
                decision = cs.decide(dict(measured_phase(), **change))
                self.assertEqual((decision["go"], decision["measured"], decision["gain"]), (False, False, None))
                self.assertIn(why, decision["reason"])
        for why, change in {"no daemon category rows": dict(valid=False),
                            "under 5000000": dict(growth_bytes=0),
                            "no kernel compressor ratio": dict(kernel_cold_bytes=None)}.items():
            with self.subTest(why):
                decision = cs.decide(measured_phase(**change))
                self.assertEqual((decision["go"], decision["measured"]), (False, False))
                self.assertIn(why, decision["reason"])
        unread = cs.decide(measured_phase(codec=()))
        self.assertIn("no read-back", unread["reason"])

    def test_a_footprint_with_no_rows_never_gives_a_confident_no_go(self):
        # Before: dirty=compressed=0 gave "no-go: ... at best 0 (0.00x)".
        decision = cs.decide(measured_phase(growth_bytes=0, kernel_cold_bytes=0))
        self.assertFalse(decision["measured"])
        self.assertIn("not measured", decision["reason"])

    def test_no_go_when_the_compressor_did_not_take_the_pages(self):
        for change in (dict(kernel_ratio_source="system"), dict(compressed_share=0.1)):
            with self.subTest(change):
                decision = cs.decide(measured_phase(codec=(MB,), **change))
                self.assertEqual((decision["go"], decision["gain"]), (False, None))
                self.assertIn("compressor did not take the cold pages", decision["reason"])

    def test_without_pressure_the_last_idle_sample_decides(self):
        phase = measured_phase()
        del phase["pressed"]
        decision = cs.decide(phase)
        self.assertEqual(decision["sample"], "cold-30min")
        self.assertIn("compressor did not take", decision["reason"])

    def test_codec_size_deflates_styled_rows(self):
        rows = [{"row": i, "runs": [{"text": "12:00:00.000 ", "fg": None, "bg": None, "attrs": 0},
                                    {"text": "INFO ", "fg": "#00ff00", "bg": None, "attrs": 0},
                                    {"text": f"build step {i}", "fg": None, "bg": None, "attrs": 0}]}
                for i in range(500)]
        size = cs.codec_size(rows)
        self.assertEqual(size["rows"], 500)
        self.assertLess(size["deflate_bytes"] * 4, size["raw_bytes"])
        self.assertIn(b"#00ff00,,0,\x1fINFO ", cs.serialize_rows(rows[:1]))


class EmitTests(unittest.TestCase):
    def test_emit_is_seeded_and_every_line_fits_80_columns(self):
        first, again, other = io.BytesIO(), io.BytesIO(), io.BytesIO()
        written = cs.emit(200_000, 3, first)
        cs.emit(200_000, 3, again)
        cs.emit(200_000, 4, other)
        self.assertEqual(first.getvalue(), again.getvalue())
        self.assertNotEqual(first.getvalue(), other.getvalue())
        self.assertEqual(written, len(first.getvalue()))
        self.assertGreaterEqual(written, 200_000)
        visible = [re.sub(r"\x1b\[[0-9;]*m", "", line) for line in first.getvalue().decode().splitlines()]
        self.assertLess(max(map(len, visible)), 80)

    def test_the_echoed_command_line_never_matches_the_done_marker(self):
        command = cs.fill_command("/usr/bin/python3", 1024, 7)
        pattern = re.compile(f"(?m)^{cs.done_marker(7)}$")
        self.assertIsNone(pattern.search(command))
        self.assertIsNotNone(pattern.search(f"{command}\nlog\nCOLD-DONE-7\n$ "))
        self.assertTrue(command.endswith("\r"))


class FakeApp:
    def __init__(self):
        self.ran = []

    def run(self, action, target=None, **args):
        self.ran.append(action)
        return {}


class FakeEnv:
    """The app and daemon on the holder model: an open terminal costs the daemon 1 MB; printing adds 12 MB (10 MB of
    scrollback, 2 MB of allocator slack). Idle, nothing is compressed; after memory pressure 90% of it is, and
    vm_stat follows at ratio 2."""

    python = "/usr/bin/python3"

    def __init__(self, missing=(), footprint_fails_at=None):
        self.app = FakeApp()
        self.now = 0.0
        self.terminals = 0
        self.filled = 0
        self.pressed = False
        self.missing = set(missing)
        self.footprint_fails_at = footprint_fails_at
        self.opened = 0
        self.calls = []
        self.said = []
        self.events = []

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds

    def say(self, text):
        self.said.append(text)

    def open_workspace(self):
        self.opened += 1
        return f"ws_{self.opened}"

    def terminal_surface(self, workspace):
        index = int(workspace.split("_")[1]) - 1
        if index in self.missing:
            return None
        self.terminals += 1
        return 100 + index

    def compressed(self):
        return int(self.filled * 12 * MB * 0.9) if self.pressed else 0

    def columns(self):
        self.events.append(("sample", self.now))
        if len([e for e in self.events if e[0] == "sample"]) == self.footprint_fails_at:
            return {}, {1: "tui-daemon", 2: "terminal-holder"}
        daemon = 50 * MB + self.terminals * MB + self.filled * 12 * MB
        compressed = self.compressed()
        return ({1: {"dirty": daemon - compressed, "compressed": compressed, "footprint": daemon, "rows": 20},
                 2: {"dirty": MB * (1 + self.terminals), "compressed": 0, "footprint": MB * (1 + self.terminals),
                     "rows": 10}},
                {1: "tui-daemon", 2: "terminal-holder"})

    def vm_stat(self):
        compressed = self.compressed()
        return VM_STAT.format(stored=10_000 + compressed // PAGE, occupied=5_000 + compressed // PAGE // 2)

    def press(self, free_pct, hold_s):
        self.events.append(("press", free_pct))
        self.pressed = True
        return {"ok": True}

    def daemon(self, cmd, params, timeout):
        self.calls.append((cmd, params))
        if cmd == "send":
            return {"ok": True}
        if cmd == "wait-for":
            self.filled += 1
            self.now += 1
            return {"ok": True, "data": {"matched": True}}
        if cmd == "read-scrollback":
            self.events.append(("read", params["surface"]))
            total = 25_000
            if params["count"] == 0:
                return {"ok": True, "data": {"rows": [], "start": 0, "total": total}}
            count = min(params["count"], total - params["start"])
            rows = [{"row": i, "runs": [{"text": f"line {params['start'] + i} of a build log", "attrs": 0}]}
                    for i in range(count)]
            return {"ok": True, "data": {"rows": rows, "start": params["start"], "total": total}}
        return {"ok": False, "error": "unexpected"}


class PhaseTests(unittest.TestCase):
    def test_phase_order_control_fill_idle_pressure_then_read_back(self):
        env = FakeEnv()
        phase = cs.cold_scrollback_phase(env, 4, 1024, [0, 10, 30], 2)
        self.assertEqual(env.app.ran, ["workspace.selectFirst", "workspace.selectFirst"])
        self.assertEqual((phase["terminals"], phase["finished"], phase["terminal_host_model"]), (4, 4, "holder"))
        self.assertEqual(phase["terminal_overhead_bytes"], MB)
        cold_at = 4.0  # four 1 s waits for the done markers
        samples = [t for kind, t in env.events if kind == "sample"]
        self.assertEqual(samples, [0.0, 0.0, cold_at, cold_at + 600, cold_at + 1800, cold_at + 1800])
        kinds_order = [kind for kind, _ in env.events]
        self.assertEqual(kinds_order.index("press"), 5)
        self.assertGreater(kinds_order.index("read"), kinds_order.index("press"))
        first = phase["points"][0]
        self.assertEqual((first["growth_bytes"], first["compressed_bytes"]), (12 * MB, 0))
        self.assertEqual(first["holder_footprint_bytes"], 0)
        pressed = phase["pressed"]
        self.assertEqual((pressed["kernel_ratio_source"], pressed["compressed_share"]), ("delta", 0.9))
        self.assertAlmostEqual(pressed["kernel_ratio"], 2.0, places=1)
        reads = [params for cmd, params in env.calls if cmd == "read-scrollback"]
        self.assertEqual([p["count"] for p in reads], [0, 10_000, 10_000, 10_000] * 2)
        self.assertEqual({p["surface"] for p in reads}, {100, 101})
        decision = phase["decision"]
        self.assertTrue(decision["measured"])
        self.assertEqual(decision["kernel_cold_bytes"], pressed["kernel_cold_bytes"])
        self.assertEqual(decision["go"], decision["gain"] >= 2.0)
        self.assertTrue(any(line.startswith("COLD-SCROLLBACK-DECISION go=") for line in env.said))
        self.assertTrue(any("| sample | valid |" in line for line in env.said))

    def test_a_workspace_without_a_terminal_is_not_measured(self):
        env = FakeEnv(missing={1})
        phase = cs.cold_scrollback_phase(env, 3, 1024, [0], 1)
        self.assertEqual(phase["terminals"], 2)
        self.assertIn("terminal 1", phase["errors"][0])
        sent = [params["surface"] for cmd, params in env.calls if cmd == "send"]
        self.assertEqual(sent, [100, 102])
        self.assertFalse(phase["decision"]["measured"])

    def test_a_terminal_that_times_out_still_counts_in_the_divisor_and_voids_the_run(self):
        env = FakeEnv()
        original = env.daemon

        def slow_second(cmd, params, timeout):
            if cmd == "wait-for" and params["surface"] == 101:
                env.now += params["timeout_ms"] / 1000
                return {"ok": False, "error": {"message": "timeout waiting for pattern"}}
            return original(cmd, params, timeout)

        env.daemon = slow_second
        phase = cs.cold_scrollback_phase(env, 2, 1024, [0], 1, wait_s=120)
        self.assertEqual((phase["terminals"], phase["finished"]), (2, 1))
        self.assertIn("no COLD-DONE-1 within 120 s", phase["errors"][0])
        self.assertEqual(phase["points"][0]["terminals"], 2)
        self.assertFalse(phase["decision"]["measured"])
        self.assertIn("terminal errors", phase["decision"]["reason"])

    def test_a_failed_footprint_sample_voids_the_run(self):
        env = FakeEnv(footprint_fails_at=2)  # the control sample
        phase = cs.cold_scrollback_phase(env, 2, 1024, [0], 1)
        self.assertFalse(phase["control"]["valid"])
        self.assertFalse(phase["decision"]["measured"])

    def test_without_pressure_the_idle_compressor_decides_no_go(self):
        env = FakeEnv()
        phase = cs.cold_scrollback_phase(env, 2, 1024, [0], 1, pressure=0)
        self.assertNotIn("press", [kind for kind, _ in env.events])
        self.assertFalse(phase["decision"]["go"])
        self.assertIn("compressor did not take", phase["decision"]["reason"])

    def test_pressure_that_cannot_run_is_reported(self):
        env = FakeEnv()
        env.press = lambda free_pct, hold: {"ok": False, "error": "/usr/bin/memory_pressure not found"}
        phase = cs.cold_scrollback_phase(env, 2, 1024, [0], 1)
        self.assertIsNone(phase["pressed"])
        self.assertTrue(any("did not run" in line for line in env.said))
        self.assertFalse(phase["decision"]["go"])


class BenchWiringTests(unittest.TestCase):
    def test_cold_scrollback_is_a_run_of_its_own_on_the_holder_model(self):
        args, _ = bm.parse_args(["--app", "/tmp/cmux DEV t.app", "--cold-scrollback", "100"])
        self.assertEqual(args.cold_idle_minutes, [0.0, 10.0, 30.0])
        self.assertEqual((args.cold_scrollback_mb, args.cold_codec_samples), (10, 5))
        self.assertEqual((args.cold_pressure, args.terminal_host_model), (5, "holder"))
        for extra in (["--tabs", "1"], ["--hidden-slope"], ["--workspaces", "1,10"], ["--pressure", "warning"],
                      ["--cold-idle", "x"], ["--cold-idle", "-1"], ["--terminal-host-model", "hosts"], ["--cold-pressure", "100"]):
            with self.subTest(extra):
                with self.assertRaises(SystemExit):
                    bm.parse_args(["--app", "/tmp/cmux DEV t.app", "--cold-scrollback", "100", *extra])

    def test_launch_budget_holds_every_full_scrollback(self):
        config = bm.cold_scrollback_config(100)
        self.assertEqual(config["terminal"]["scrollback"]["maxTotalMemoryBytes"], 2_000_000_000)

    def test_workspace_terminal_reads_the_snapshot(self):
        topology = {"workspaces": [
            {"id": "ws_a", "screens": [{"panes": [{"tabs": [{"kind": "terminal", "surface": 4}]}]}]},
            {"id": "ws_b", "screens": [{"panes": [{"tabs": [{"kind": "chromium"},
                                                            {"kind": "terminal", "surface": "9"}]}]}]}]}
        self.assertEqual(bm.workspace_terminal(topology, "ws_b"), 9)
        self.assertIsNone(bm.workspace_terminal(topology, "ws_c"))

    def test_a_footprint_timeout_is_an_invalid_sample_not_a_crash(self):
        env = bm.ColdScrollbackEnv.__new__(bm.ColdScrollbackEnv)
        env.app_pid, env.bundle = 1, "/tmp/x.app"
        saved_owned, saved_run = bm.owned, bm.subprocess.run

        def timeout(*_args, **_kwargs):
            raise bm.subprocess.TimeoutExpired("footprint", 300)

        bm.owned = lambda pid, bundle: {5: ("tui-daemon", None)}
        bm.subprocess.run = timeout
        try:
            stderr, sys.stderr = sys.stderr, io.StringIO()
            try:
                columns, kinds_of = env.columns()
            finally:
                sys.stderr = stderr
        finally:
            bm.owned, bm.subprocess.run = saved_owned, saved_run
        self.assertEqual((columns, kinds_of), ({}, {5: "tui-daemon"}))
        self.assertFalse(cs.sample_valid(columns, kinds_of)[0])


if __name__ == "__main__":
    unittest.main()
