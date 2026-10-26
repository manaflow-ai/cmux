#!/usr/bin/env python3
"""bench_memory.py --cold-scrollback (p07-memory-112): footprint -j and vm_stat parsing, the per-terminal arithmetic,
the go/no-go against deflate, and the phase's order (samples at each idle minute, the read-back last). Runs on any
OS: the app, its daemon, footprint and vm_stat are fakes. Local only:
python3 -I scripts/cmux-next/tests/test_bench_memory_cold.py"""

from __future__ import annotations

import io
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import bench_memory as bm  # noqa: E402
import cold_scrollback as cs  # noqa: E402

MB = 1048576
PAGE = 16384

VM_STAT = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               12345.
Pages stored in compressor:               {stored}.
Pages occupied by compressor:             {occupied}.
"Translation faults":                     99.
"""


def vm(stored, occupied):
    return cs.parse_vm_stat(VM_STAT.format(stored=stored, occupied=occupied))


def kinds(daemon=(0, 0), hosts=0, app=0):
    """group_totals-shaped kinds: the daemon's (dirty, compressed), the hosts' and the app's footprint."""
    return {"tui-daemon": {"processes": 1, "dirty": daemon[0], "compressed": daemon[1],
                           "footprint": daemon[0] + daemon[1]},
            "terminal-host": {"processes": 1, "dirty": hosts, "compressed": 0, "footprint": hosts},
            "app": {"processes": 1, "dirty": app, "compressed": 0, "footprint": app}}


class ParserTests(unittest.TestCase):
    def test_footprint_with_dirty_apart_from_compressed(self):
        doc = {"processes": [{"pid": 7, "name": "cmux-tui", "footprint": 30 * MB,
                              "categories": {"MALLOC_LARGE": {"dirty": 18 * MB, "swapped": 10 * MB, "clean": 5},
                                             "VM_ALLOCATE": {"dirty": 2 * MB, "swapped": 0},
                                             "TOTAL": {"dirty": 20 * MB, "swapped": 10 * MB}}}]}
        self.assertEqual(cs.parse_footprint(doc), {7: {"dirty": 20 * MB, "compressed": 10 * MB, "footprint": 30 * MB}})

    def test_footprint_whose_dirty_includes_compressed_gives_resident_dirty(self):
        doc = [{"pid": 8, "phys_footprint": 30 * MB, "peak_footprint": 90 * MB,
                "regions": [{"category": "MALLOC_LARGE", "dirty": 30 * MB, "compressed": 12 * MB}]}]
        self.assertEqual(cs.parse_footprint(doc), {8: {"dirty": 18 * MB, "compressed": 12 * MB, "footprint": 30 * MB}})

    def test_footprint_of_several_processes(self):
        doc = {"processes": [{"pid": 1, "footprint": 4, "categories": {"a": {"dirty": 4}}},
                             {"pid": 2, "footprint": 6, "categories": {"a": {"dirty": 5, "swapped": 1}}}]}
        self.assertEqual(sorted(cs.parse_footprint(doc)), [1, 2])
        self.assertEqual(cs.parse_footprint(doc)[2]["compressed"], 1)

    def test_vm_stat_compressor_rows(self):
        self.assertEqual(vm(4000, 1000), {"page_size": PAGE, "stored_pages": 4000, "occupied_pages": 1000})
        self.assertEqual(cs.parse_vm_stat("Pages free: 3.\n")["stored_pages"], None)


class ArithmeticTests(unittest.TestCase):
    def test_kernel_ratio_is_ours_when_our_pages_are_most_of_what_was_compressed(self):
        ratio, source = cs.kernel_ratio(vm(1000, 500), vm(1000 + 640, 500 + 160), 640 * PAGE)
        self.assertEqual((ratio, source), (4.0, "delta"))

    def test_kernel_ratio_falls_back_to_the_whole_compressor(self):
        self.assertEqual(cs.kernel_ratio(vm(1000, 500), vm(1000, 500), 0), (2.0, "system"))
        # Someone else's pages dominate what the compressor took in.
        self.assertEqual(cs.kernel_ratio(vm(1000, 500), vm(3000, 1000), PAGE)[1], "system")
        self.assertEqual(cs.kernel_ratio({}, cs.parse_vm_stat(""), 0), (None, "none"))

    def test_idle_point_is_per_terminal_over_the_base_and_gates_on_the_daemon(self):
        base = {"kinds": kinds(daemon=(100 * MB, 0), hosts=10 * MB, app=200 * MB), "vm": vm(1000, 500)}
        now = {"kinds": kinds(daemon=(100 * MB + 6 * 10 * MB, 4 * 10 * MB), hosts=10 * MB + 20 * MB,
                              app=200 * MB + 10 * MB),
               "vm": vm(1000 + 40 * MB // PAGE, 500 + 10 * MB // PAGE)}
        point = cs.idle_point("cold-10min", 10, base, now, 10)
        self.assertEqual(point["dirty_bytes"], 6 * MB)
        self.assertEqual(point["compressed_bytes"], 4 * MB)
        self.assertEqual((point["kernel_ratio"], point["kernel_ratio_source"]), (4.0, "delta"))
        self.assertEqual(point["kernel_now_bytes"], 7 * MB)
        self.assertEqual(point["kernel_cold_bytes"], round(10 * MB / 4))
        self.assertEqual(point["holder_footprint_bytes"], 2 * MB)
        self.assertEqual(point["app_footprint_bytes"], MB)

    def test_decision_needs_a_gain_of_two(self):
        point = {"idle_min": 30, "kernel_cold_bytes": 4 * MB}
        go = cs.decide([point], [{"rows": 10, "deflate_bytes": 2 * MB}])
        self.assertEqual((go["go"], go["gain"]), (True, 2.0))
        no = cs.decide([point], [{"rows": 10, "deflate_bytes": 3 * MB}, {"rows": 10, "deflate_bytes": 3 * MB}])
        self.assertEqual((no["go"], no["gain"], no["codec_samples"]), (False, 1.33, 2))
        self.assertTrue(no["reason"].startswith("no-go: deflate keeps"))

    def test_decision_without_a_measurement_keeps_the_codec_off(self):
        unmeasured = cs.decide([{"idle_min": 30, "kernel_cold_bytes": None}], [{"rows": 3, "deflate_bytes": 5}])
        self.assertFalse(unmeasured["go"])
        self.assertIn("ratio not measured", unmeasured["reason"])
        empty = cs.decide([{"idle_min": 30, "kernel_cold_bytes": 9}], [{"rows": 0, "deflate_bytes": 0}])
        self.assertIn("codec's bytes not measured", empty["reason"])

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
    """The app and daemon: the daemon's dirty bytes grow by 12 MB per filled terminal and move into the compressor
    after 10 idle minutes; vm_stat follows at ratio 3."""

    python = "/usr/bin/python3"

    def __init__(self, missing=()):
        self.app = FakeApp()
        self.now = 0.0
        self.filled = 0
        self.missing = set(missing)
        self.opened = 0
        self.calls = []
        self.said = []
        self.sample_times = []

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
        return None if index in self.missing else 100 + index

    def compressed_share(self):
        return 0.0 if self.now < 600 else 0.75

    def columns(self):
        self.sample_times.append(self.now)
        grown = self.filled * 12 * MB
        compressed = int(grown * self.compressed_share())
        return ({1: {"dirty": 50 * MB + grown - compressed, "compressed": compressed, "footprint": 50 * MB + grown},
                 2: {"dirty": MB * (1 + self.filled), "compressed": 0, "footprint": MB * (1 + self.filled)}},
                {1: "tui-daemon", 2: "terminal-host"})

    def vm_stat(self):
        compressed = int(self.filled * 12 * MB * self.compressed_share())
        return VM_STAT.format(stored=10_000 + compressed // PAGE, occupied=5_000 + compressed // PAGE // 3)

    def daemon(self, cmd, params, timeout):
        self.calls.append((cmd, params))
        if cmd == "send":
            return {"ok": True}
        if cmd == "wait-for":
            self.filled += 1
            self.now += 1
            return {"ok": True, "data": {"matched": True}}
        if cmd == "read-scrollback":
            total = 25_000
            if params["count"] == 0:
                return {"ok": True, "data": {"rows": [], "start": 0, "total": total}}
            count = min(params["count"], total - params["start"])
            rows = [{"row": i, "runs": [{"text": f"line {params['start'] + i} of a build log", "attrs": 0}]}
                    for i in range(count)]
            return {"ok": True, "data": {"rows": rows, "start": params["start"], "total": total}}
        return {"ok": False, "error": "unexpected"}


class PhaseTests(unittest.TestCase):
    def test_phase_samples_at_each_idle_minute_then_reads_back_last(self):
        env = FakeEnv()
        phase = cs.cold_scrollback_phase(env, 4, 1024, [0, 10, 30], 2)
        self.assertEqual(env.app.ran, ["workspace.selectFirst", "workspace.selectFirst"])
        self.assertEqual(phase["terminals"], 4)
        cold_at = 4.0  # four 1 s waits for the done markers
        self.assertEqual(env.sample_times, [0.0, cold_at, cold_at + 600, cold_at + 1800])
        self.assertEqual([p["idle_min"] for p in phase["points"]], [0, 10, 30])
        self.assertEqual(phase["points"][0]["dirty_bytes"], 12 * MB)
        self.assertEqual(phase["points"][0]["compressed_bytes"], 0)
        self.assertEqual(phase["points"][0]["holder_footprint_bytes"], MB)
        last = phase["points"][-1]
        self.assertEqual((last["dirty_bytes"], last["compressed_bytes"]), (3 * MB, 9 * MB))
        self.assertEqual(last["kernel_ratio_source"], "delta")
        self.assertAlmostEqual(last["kernel_ratio"], 3.0, places=1)
        # The read-back pages in the rows, so it runs after the last sample, 10,000 rows a request.
        reads = [(i, params) for i, (cmd, params) in enumerate(env.calls) if cmd == "read-scrollback"]
        self.assertEqual([p["count"] for _, p in reads], [0, 10_000, 10_000, 10_000] * 2)
        self.assertEqual({p["surface"] for _, p in reads}, {100, 101})
        self.assertEqual([c["rows"] for c in phase["codec"]], [25_000, 25_000])
        decision = phase["decision"]
        self.assertEqual(decision["kernel_cold_bytes"], last["kernel_cold_bytes"])
        self.assertEqual(decision["go"], decision["gain"] >= 2.0)
        self.assertTrue(any(line.startswith("COLD-SCROLLBACK-DECISION go=") for line in env.said))
        self.assertTrue(any(line.startswith("| idle min |") for line in env.said))

    def test_a_workspace_without_a_terminal_is_an_error_and_not_counted(self):
        env = FakeEnv(missing={1})
        phase = cs.cold_scrollback_phase(env, 3, 1024, [0], 1)
        self.assertEqual(phase["terminals"], 2)
        self.assertEqual(len(phase["errors"]), 1)
        self.assertIn("terminal 1", phase["errors"][0])
        sent = [params["surface"] for cmd, params in env.calls if cmd == "send"]
        self.assertEqual(sent, [100, 102])

    def test_a_terminal_that_never_finishes_is_reported(self):
        env = FakeEnv()
        original = env.daemon

        def slow(cmd, params, timeout):
            if cmd == "wait-for":
                env.now += params["timeout_ms"] / 1000
                return {"ok": False, "error": {"message": "timeout waiting for pattern"}}
            return original(cmd, params, timeout)

        env.daemon = slow
        surfaces, errors = cs.fill(env, 2, 1024, 120)
        self.assertEqual(surfaces, [])
        self.assertEqual(len(errors), 2)
        self.assertIn("no COLD-DONE-0 within 120 s", errors[0])


class BenchWiringTests(unittest.TestCase):
    def test_cold_scrollback_is_a_run_of_its_own(self):
        args, _ = bm.parse_args(["--app", "/tmp/cmux DEV t.app", "--cold-scrollback", "100"])
        self.assertEqual(args.cold_idle_minutes, [0.0, 10.0, 30.0])
        self.assertEqual((args.cold_scrollback_mb, args.cold_codec_samples), (10, 5))
        for extra in (["--tabs", "1"], ["--hidden-slope"], ["--workspaces", "1,10"], ["--pressure", "warning"],
                      ["--cold-idle", "x"], ["--cold-idle", "-1"]):
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


if __name__ == "__main__":
    unittest.main()
