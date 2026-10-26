#!/usr/bin/env python3
"""bench_memory.py threads (p07-memory-078): app threads per hidden terminal before and after, whether the hidden
terminals' renderer and IO threads woke in an idle window, and DC8's thread share per owner. Runs on any OS: the
app socket, proc_pid_rusage and the thread reads are fakes. Local only:
python3 -I scripts/cmux-next/tests/test_bench_memory_threads.py"""

from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import bench_memory as bm  # noqa: E402
from test_bench_memory_phases import FakeApp, FakeClock, report, sample  # noqa: E402

MB = 1048576


def threads(*rows):
    """A thread_times read: rows of (handle, name, cpu ns)."""
    return {handle: (name, cpu) for handle, name, cpu in rows}


# The launch workspace's terminal (shown) and two shared app threads.
BASE = threads((1, "main", 900), (2, "renderer", 50), (3, "io", 40), (4, "com.apple.NSEventThread", 10))


def hidden(cpu_renderer=(0, 0), cpu_io=(0, 0), extra=()):
    """BASE plus two hidden terminals (renderer 10/11, io 20/21) and one more app thread."""
    return {**BASE, **threads((10, "renderer", cpu_renderer[0]), (11, "renderer", cpu_renderer[1]),
                              (20, "io", cpu_io[0]), (21, "io", cpu_io[1]), (30, "cmux.lane", 5), *extra)}


class TerminalThreadsTests(unittest.TestCase):
    def test_threads_per_hidden_terminal_count_only_threads_added_since_base(self):
        result = bm.terminal_threads(BASE, hidden(), None)
        self.assertEqual(result["terminals"], 2, "no debug.memory count: one terminal per added renderer thread")
        self.assertEqual(result["app_threads_base"], 4)
        self.assertEqual(result["app_threads"], 9)
        self.assertEqual(result["threads_per_terminal"], 2.5)
        self.assertEqual(result["renderer"], {"threads": 2, "per_terminal": 1.0})
        self.assertEqual(result["io"], {"threads": 2, "per_terminal": 1.0})
        self.assertNotIn("window_s", result)

    def test_debug_memory_terminal_count_wins(self):
        result = bm.terminal_threads(BASE, hidden(), 5)
        self.assertEqual(result["terminals"], 5)
        self.assertEqual(result["threads_per_terminal"], 1.0)
        self.assertEqual(result["renderer"]["per_terminal"], 0.4)

    def test_idle_hidden_threads_did_not_wake_while_the_shown_terminal_did(self):
        start = hidden(cpu_renderer=(700, 800), cpu_io=(300, 300))
        # The shown terminal's renderer (2) blinks its cursor; the hidden ones stay parked.
        end = {**hidden(cpu_renderer=(700, 800), cpu_io=(300, 300)), 2: ("renderer", 9_000)}
        result = bm.terminal_threads(BASE, end, 2, start, 10)
        self.assertEqual(result["window_s"], 10)
        self.assertEqual(result["renderer"]["woke"], 0, "the shown terminal's renderer is not a hidden one")
        self.assertEqual(result["io"]["woke"], 0)
        self.assertEqual(result["renderer"]["cpu_us"], 0.0)

    def test_a_hidden_renderer_that_ran_in_the_window_woke(self):
        start = hidden(cpu_renderer=(700, 800))
        end = hidden(cpu_renderer=(700, 3_800))
        result = bm.terminal_threads(BASE, end, 2, start, 10)
        self.assertEqual(result["renderer"]["woke"], 1)
        self.assertEqual(result["renderer"]["cpu_us"], 3.0)

    def test_a_surface_thread_born_in_the_window_counts_from_zero(self):
        start = hidden()
        end = hidden(extra=[(12, "renderer", 2_000)])
        result = bm.terminal_threads(BASE, end, 3, start, 10)
        self.assertEqual(result["renderer"]["threads"], 3)
        self.assertEqual(result["renderer"]["woke"], 1)

    def test_a_base_handle_reused_by_a_surface_thread_of_another_name_is_an_added_terminals(self):
        # Base thread 4 (NSEventThread) exited; a hidden terminal's renderer got its pthread address.
        end = {**hidden(), 4: ("renderer", 0)}
        result = bm.terminal_threads(BASE, end, 3)
        self.assertEqual(result["renderer"]["threads"], 3)

    def test_a_start_handle_reused_by_a_surface_thread_of_another_name_counts_from_zero(self):
        # In the window thread 30 (cmux.lane, 5 ms of CPU) exited and a new renderer got its address.
        start = {**hidden(), 30: ("cmux.lane", 5_000_000)}
        end = {**hidden(), 30: ("renderer", 2_000)}
        result = bm.terminal_threads(BASE, end, 3, start, 10)
        self.assertEqual(result["renderer"]["threads"], 3)
        self.assertEqual(result["renderer"]["woke"], 1, "its CPU is its own, not a delta against the lane thread")
        self.assertEqual(result["renderer"]["cpu_us"], 2.0)

    def test_print_names_the_gpu_release_and_the_wakeups(self):
        result = bm.terminal_threads(BASE, hidden(), 2, hidden(), 10)
        with redirect_stdout(io.StringIO()) as out:
            bm.print_terminal_threads("settled", result, True)
        text = out.getvalue()
        self.assertIn("app threads settled: 9 (base 4, 2.50 per terminal of 2); GPU release on", text)
        self.assertIn("renderer threads: 2, woke in 10 s idle: 0 (0 us CPU)", text)


class HiddenPhaseThreadsTests(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        self.saved = (bm.time, bm.usage, bm.open_workspace)
        bm.time = self.clock
        bm.open_workspace = lambda app, recipe, url, index, chats=None: f"ws_{index}"

    def tearDown(self):
        bm.time, bm.usage, bm.open_workspace = self.saved

    def test_hidden_phase_reports_threads_per_hidden_terminal_and_their_wakeups_before_and_after_grace(self):
        memories = iter([
            report([], terminal={"surfaces": 1, "rendering": 1}) | {"budget": {"gpu_resident_available": True}},
            report([], terminal={"surfaces": 3, "rendering": 1}) | {"budget": {"gpu_resident_available": True}},
            # After the grace one hidden terminal was evicted from the warm set: its threads went with it.
            report([], terminal={"surfaces": 2, "rendering": 1}) | {"budget": {"gpu_resident_available": True}},
        ])
        after_grace = {handle: row for handle, row in hidden().items() if handle not in (11, 21)}
        reads = iter([BASE, hidden(), hidden(), after_grace, after_grace])
        samples = iter([sample("base", {"app": (1, 100 * MB)}), sample("settled", {"app": (1, 110 * MB)}),
                        sample("grace", {"app": (1, 104 * MB)})])
        app = FakeApp(memory=lambda: next(memories))
        with redirect_stdout(io.StringIO()) as out:
            phase = bm.hidden_workspaces_phase(app, 2, 960, ["terminal"], "about:blank", [], None,
                                               lambda label: next(samples), "holder", lambda: next(reads), 10)
        self.assertTrue(phase["gpu_release"])
        settled, grace = phase["threads_settled"], phase["threads_after_grace"]
        self.assertEqual((settled["terminals"], settled["threads_per_terminal"]), (2, 2.5))
        self.assertEqual(settled["renderer"], {"threads": 2, "per_terminal": 1.0, "woke": 0, "cpu_us": 0.0})
        self.assertEqual((grace["terminals"], grace["renderer"]["threads"], grace["renderer"]["woke"]), (1, 1, 0))
        self.assertEqual(grace["threads_per_terminal"], 3.0)
        self.assertEqual(self.clock.now, 960 + 10, "the settled window runs inside the grace, the last one after it")
        self.assertIn("app threads after grace: 7 (base 4, 3.00 per terminal of 1); GPU release on", out.getvalue())

    def test_without_a_thread_reader_the_phase_is_as_before(self):
        flat = sample("flat", {"app": (1, 100 * MB)})
        app = FakeApp()
        with redirect_stdout(io.StringIO()):
            phase = bm.hidden_workspaces_phase(app, 1, 0, ["terminal"], "about:blank", [], None,
                                               lambda label: flat, "holder")
        self.assertNotIn("threads_settled", phase)
        self.assertNotIn("gpu_release", phase)
        self.assertEqual([method for method, _ in app.calls], ["debug.memory"])

    def test_a_zero_window_counts_threads_and_waits_for_nothing(self):
        reads = iter([BASE, hidden()])
        flat = sample("flat", {"app": (1, 100 * MB)})
        with redirect_stdout(io.StringIO()):
            phase = bm.hidden_workspaces_phase(FakeApp(), 2, 0, ["terminal"], "about:blank", [], None,
                                               lambda label: flat, "holder", lambda: next(reads), 0)
        self.assertEqual(self.clock.now, 0)
        self.assertIsNone(phase["gpu_release"], "a build without debug.memory does not say")
        self.assertNotIn("woke", phase["threads_settled"]["renderer"])


class ThreadShareTests(unittest.TestCase):
    def setUp(self):
        self.saved = (bm.process_table, bm.usage, bm.thread_count, bm._responsible)

    def tearDown(self):
        bm.process_table, bm.usage, bm.thread_count, bm._responsible = self.saved

    def test_every_kind_has_the_owner_dc8_names(self):
        self.assertEqual(bm.thread_owner("app"), "PL-memory 078")
        for kind in ("tui-daemon", "tui-daemon-chief", "terminal-host", "terminal-holder"):
            self.assertEqual(bm.thread_owner(kind), "PL-daemon 095", kind)
        self.assertEqual(bm.thread_owner("cef-renderer"), "PL-cefhost")
        self.assertEqual(bm.thread_owner("acpmux-agent"), "PL-acpmux")
        self.assertEqual(bm.thread_owner("webkit-webcontent"), "PL-webui")
        self.assertEqual(bm.thread_owner("cmux-holder-helper"), "PL-memory")

    def test_sample_counts_threads_per_process_kind_and_owner(self):
        bundle = "/tmp/cmux DEV t.app"
        bm.process_table = lambda: [(100, 1, f"{bundle}/Contents/MacOS/cmux DEV"),
                                    (101, 1, f"{bundle}/Contents/Resources/bin/cmux-tui --session main server run"),
                                    (102, 100, f"{bundle}/Contents/Frameworks/cmux DEV Helper (Renderer).app/x "
                                               "--type=renderer"),
                                    (103, 100, f"{bundle}/Contents/Frameworks/cmux DEV Helper (Renderer).app/x "
                                               "--type=renderer")]
        bm._responsible = None
        bm.usage = lambda pid: (MB, MB, MB, 0, 0)
        bm.thread_count = lambda pid: {100: 91, 101: 797, 102: 20}.get(pid)  # 103 ended between the reads
        with redirect_stdout(io.StringIO()) as out:
            result = bm.sample(100, bundle, "x", 1)
            bm.print_sample(result, 3)
        self.assertEqual(result["total_threads"], 908)
        self.assertEqual(result["kinds"]["cef-renderer"]["threads"], 20)
        self.assertEqual(result["threads_by_owner"], {"PL-daemon 095": 797, "PL-memory 078": 91, "PL-cefhost": 20})
        self.assertIn("908 threads", out.getvalue())
        self.assertIn("threads by owner (DC8): PL-daemon 095 797, PL-memory 078 91, PL-cefhost 20", out.getvalue())


class ArgsTests(unittest.TestCase):
    def test_gpu_release_is_for_a_launched_app(self):
        with redirect_stderr(io.StringIO()) as err, self.assertRaises(SystemExit):
            bm.parse_args(["--app", "/tmp/x.app", "--socket", "/tmp/s", "--app-pid", "1", "--gpu-release", "on"])
        self.assertIn("--gpu-release sets memory.discard.terminalGPURelease", err.getvalue())
        args, _ = bm.parse_args(["--app", "/tmp/x.app", "--hidden-workspaces", "60", "--gpu-release", "off"])
        self.assertEqual((args.gpu_release, args.thread_window), ("off", 10))


class Launched(Exception):
    """Stops main at the launch: the test reads what the app would get."""


class GPUReleaseLaunchTests(unittest.TestCase):
    def launch(self, *flags):
        """(env, config, tunables file contents or None) that main gives BenchApp for `flags`."""
        seen = {}

        class FakeBenchApp:
            def __init__(self, bundle, **kwargs):
                seen.update(kwargs)

            def launch(self):
                raise Launched

            def stop(self):
                pass

        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        with mock.patch.object(bm.sys, "platform", "darwin"), mock.patch.object(bm, "BenchApp", FakeBenchApp), \
                mock.patch.object(bm, "note_child_launch"), \
                mock.patch.object(bm.tempfile, "mkdtemp", return_value=folder.name), self.assertRaises(Launched):
            bm.main(["--app", "/tmp/x.app", "--hidden-workspaces", "60", *flags])
        path = seen["env"].get("CMUX_NEXT_DEBUG_TUNABLES_FILE")
        if path is None:
            return seen["env"], seen["config"], None
        self.assertEqual(os.path.dirname(path), folder.name)
        with open(path) as handle:
            return seen["env"], seen["config"], json.load(handle)

    def test_gpu_release_on_goes_in_the_tunables_file_the_launch_env_names(self):
        _, config, tunables = self.launch("--gpu-release", "on")
        self.assertEqual(tunables, {"version": 1, "values": {"memory.discard.terminalGPURelease": True}})
        self.assertNotIn("memory", config, "the tunable is not a cmux.json setting")

    def test_gpu_release_off_writes_false(self):
        _, config, tunables = self.launch("--gpu-release", "off")
        self.assertEqual(tunables, {"version": 1, "values": {"memory.discard.terminalGPURelease": False}})
        self.assertNotIn("memory", config)

    def test_without_gpu_release_no_tunables_file(self):
        env, _, tunables = self.launch()
        self.assertNotIn("CMUX_NEXT_DEBUG_TUNABLES_FILE", env)
        self.assertIsNone(tunables)


if __name__ == "__main__":
    unittest.main()
