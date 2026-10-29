#!/usr/bin/env python3
"""bench_memory.py phases (p07-memory-013): --hidden-workspaces gives the footprint each hidden workspace adds per
process kind, --pressure gives released_mb, release_s and the managed consumers' footprint before, and both fall
back to process footprint on a build without debug.memory. Runs on any OS: the app socket and proc_pid_rusage are
fakes. Local only: python3 -I scripts/cmux-next/tests/test_bench_memory_phases.py"""

from __future__ import annotations

import contextlib
import io
import json
import plistlib
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import bench_memory as bm  # noqa: E402

MB = 1048576

# App.call's answer for a method the build does not register (ControlRouter.methodNotFound).
NOT_FOUND = {"error": json.dumps({"code": "method_not_found", "message": "unknown method"})}


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds

    def time(self):
        return 1_700_000_000 + self.now


class FakeApp:
    """The control socket: debug.memory (when `memory` is set), the pressure override (when `override`).
    `on_pressure(level)` runs inside the override request, as the app's release does; a reply it returns
    replaces the normal one."""

    def __init__(self, memory=None, override=True, on_pressure=None):
        self.memory = memory
        self.override = override
        self.on_pressure = on_pressure
        self.calls: list[tuple[str, dict]] = []
        self.ran: list[str] = []

    def call(self, method, params=None, label=None, timeout=120):
        self.calls.append((method, params or {}))
        if method == "debug.memory":
            return self.memory() if callable(self.memory) else (self.memory or NOT_FOUND)
        if method == "debug.hibernation.pressure":
            if not self.override:
                return NOT_FOUND
            replaced = self.on_pressure(params["level"]) if self.on_pressure else None
            if replaced is not None:
                return replaced
            # DebugHibernationControl.applyOverride: the coordinator's level and the override (null for none).
            level = params["level"]
            return {"level": "normal" if level == "none" else level, "override": None if level == "none" else level}
        return {"error": "unexpected"}

    def run(self, action, target=None, **args):
        self.ran.append(action)
        return {}


def sample(label, kinds: dict[str, tuple[int, int]]) -> dict:
    """A bench_memory.sample-shaped result: kinds is {kind: (process count, footprint bytes)}."""
    processes = [{"kind": kind} for kind, (count, _) in kinds.items() for _ in range(count)]
    return {"label": label, "processes": processes,
            "kinds": {kind: {"count": count, "footprint_bytes": footprint, "footprint_mb": footprint / MB}
                      for kind, (count, footprint) in kinds.items()}}


def report(consumers, workspaces=(), terminal=None):
    """A debug.memory answer with the keys of MemoryDiagnosticsReport (p07-memory-010)."""
    return {"pressure": {"level": "normal", "kernel_level": "normal", "override": None, "since_ms": None},
            "consumers": consumers, "workspaces": list(workspaces), "terminal": terminal or {}}


def consumer(name, footprint, stateful=True, limit=True, volatile=None, entries=None):
    """One consumer exactly as MemoryDiagnosticsReport.Consumer encodes it (convertToSnakeCase, null counts)."""
    return {"name": name,
            "traits": {"estimated_usage": "medium", "data_access": "memory_only", "retention": "cache",
                       "recreate_cost": "cheap", "release_cpu_cost": "cheap", "is_stateful": stateful,
                       "supports_memory_limit": limit},
            "managed": stateful and limit, "limit_percent": 100, "footprint_bytes": footprint,
            "volatile_bytes": volatile, "entries": entries}


def workspace(mounted, parked, terminals, gpu, app_bytes):
    """One workspace row as MemoryDiagnosticsReport.WorkspaceRow encodes it."""
    return {"id": "redacted", "mounted": mounted, "parked": parked, "panes": 1, "terminal_surfaces": terminals,
            "gpu_resident_surfaces": gpu, "app_bytes": app_bytes}


def pressure_levels(app):
    return [params["level"] for method, params in app.calls if method == "debug.hibernation.pressure"]


class PhaseTests(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        self.saved = (bm.time, bm.usage, bm.open_workspace)
        bm.time = self.clock

    def tearDown(self):
        bm.time, bm.usage, bm.open_workspace = self.saved

    def test_managed_consumers_are_the_ones_the_report_marks_managed_and_keep_unknown_bytes(self):
        memory = bm.MemoryReport(report([
            consumer("previews", 4 * MB, volatile=2 * MB, entries=3),
            consumer("home.rows", None),
            consumer("planner", 9 * MB, stateful=False),
            consumer("thumbnails", MB, limit=False),
        ]))
        self.assertEqual(memory.managed(), {
            "previews": {"instances": 1, "footprint_bytes": 4 * MB, "unknown": 0},
            "home.rows": {"instances": 1, "footprint_bytes": 0, "unknown": 1}})
        self.assertEqual(memory.managed_bytes(), (4 * MB, 1))
        self.assertEqual(memory.level(), "normal")

    def test_managed_consumers_of_one_name_all_count(self):
        # One tab-hover-cards consumer per tab strip, and every name that is not a plain token is redacted.
        memory = bm.MemoryReport(report([consumer("tab-hover-cards", 3 * MB), consumer("tab-hover-cards", 5 * MB),
                                         consumer("tab-hover-cards", None), consumer("redacted", 2 * MB),
                                         consumer("redacted", 7 * MB)]))
        self.assertEqual(memory.managed_bytes(), (17 * MB, 1))
        self.assertEqual(memory.managed()["tab-hover-cards"], {"instances": 3, "footprint_bytes": 8 * MB, "unknown": 1})
        self.assertEqual(memory.managed()["redacted"], {"instances": 2, "footprint_bytes": 9 * MB, "unknown": 0})

    def test_pressure_share_of_managed_counts_every_consumer_of_a_name(self):
        bm.usage = lambda pid: (0, 300 * MB if self.clock.now == 0 else 220 * MB, 0, 0, 0)
        reports = iter([report([consumer("tab-hover-cards", 50 * MB), consumer("tab-hover-cards", 50 * MB)]),
                        report([consumer("tab-hover-cards", 10 * MB), consumer("tab-hover-cards", 10 * MB)])])

        def release(level):
            if level != "none":
                self.clock.sleep(0.01)

        app = FakeApp(memory=lambda: next(reports), on_pressure=release)
        samples = iter([sample("b", {"app": (1, 300 * MB)}), sample("a", {"app": (1, 220 * MB)})])
        with redirect_stdout(io.StringIO()) as out:
            phase = bm.pressure_phase(app, 42, "critical", 1.0, 0.1, lambda label: next(samples))
        self.assertEqual(phase["managed_before_mb"], 100.0)
        self.assertEqual(phase["managed_after_mb"], 20.0)
        self.assertEqual(phase["released_pct_of_managed"], 80.0)
        self.assertIn("tab-hover-cards (x2 -> x2)", out.getvalue())

    def test_pressure_reports_release_against_managed_footprint_and_restores_normal(self):
        footprints = iter([300 * MB] + [300 * MB - min(step, 10) * 10 * MB for step in range(1, 200)])
        bm.usage = lambda pid: (0, next(footprints), 0, 0, 0)
        app = FakeApp(memory=report([consumer("previews", 120 * MB)]))
        before, after = sample("b", {"app": (1, 300 * MB)}), sample("a", {"app": (1, 200 * MB)})
        samples = iter([before, after])
        with redirect_stdout(io.StringIO()) as out:
            phase = bm.pressure_phase(app, 42, "critical", 2.0, 0.1, lambda label: next(samples))
        self.assertEqual(phase["released_mb"], 100.0)
        self.assertEqual(phase["managed_before_mb"], 120.0)
        # The first sample right after the reply (10 MB down), then one per 0.1 s: 90 MB down at 0.8 s.
        self.assertAlmostEqual(phase["release_s"], 0.8, places=2)
        self.assertEqual(phase["released_pct_of_managed"], 83.3)
        self.assertEqual(phase["kinds_delta_mb"]["app"], -100.0)
        self.assertEqual(pressure_levels(app), ["critical", "none"])
        self.assertIn("released_mb 100.0", out.getvalue())

    def test_release_s_counts_the_release_inside_the_override_request(self):
        # MemoryCoordinator applies the limits in the request's own main-actor turn: 1.5 s of release there.
        footprint = {"bytes": 300 * MB}
        bm.usage = lambda pid: (0, footprint["bytes"], 0, 0, 0)

        def release(level):
            if level != "none":
                self.clock.sleep(1.5)
                footprint["bytes"] = 200 * MB

        samples = iter([sample("b", {"app": (1, 300 * MB)}), sample("a", {"app": (1, 200 * MB)})])
        with redirect_stdout(io.StringIO()):
            phase = bm.pressure_phase(FakeApp(on_pressure=release), 42, "critical", 3.0, 0.1,
                                      lambda label: next(samples))
        self.assertEqual(phase["released_mb"], 100.0)
        self.assertAlmostEqual(phase["release_s"], 1.5, places=2)
        self.assertEqual(phase["timeline"][:2], [(0.0, 300.0), (1.5, 200.0)])

    def test_pressure_without_debug_memory_is_footprint_only(self):
        bm.usage = lambda pid: (0, 50 * MB, 0, 0, 0)
        samples = iter([sample("b", {"app": (1, 50 * MB)}), sample("a", {"app": (1, 50 * MB)})])
        with redirect_stdout(io.StringIO()) as out:
            phase = bm.pressure_phase(FakeApp(), 42, "warning", 1.0, 0.1, lambda label: next(samples))
        self.assertNotIn("managed_before_mb", phase)
        self.assertEqual(phase["released_mb"], 0.0)
        self.assertIsNone(phase["release_s"])
        self.assertIn("process footprint only", out.getvalue())

    def test_pressure_without_override_is_skipped(self):
        bm.usage = lambda pid: (0, 50 * MB, 0, 0, 0)
        app = FakeApp(override=False)
        with redirect_stdout(io.StringIO()):
            phase = bm.pressure_phase(app, 42, "critical", 1.0, 0.1,
                                      lambda label: sample(label, {"app": (1, 50 * MB)}))
        self.assertEqual(phase["skipped"], "no pressure override")
        self.assertEqual(pressure_levels(app), ["critical"])

    def test_a_failed_override_request_is_reported_and_still_cleared(self):
        bm.usage = lambda pid: (0, 50 * MB, 0, 0, 0)

        def timed_out(level):
            return {"error": "debug.hibernation.pressure: timed out"} if level != "none" else None

        app = FakeApp(on_pressure=timed_out)
        with redirect_stdout(io.StringIO()) as out:
            phase = bm.pressure_phase(app, 42, "critical", 1.0, 0.1,
                                      lambda label: sample(label, {"app": (1, 50 * MB)}))
        self.assertNotIn("skipped", phase)
        self.assertEqual(phase["error"], "debug.hibernation.pressure: timed out")
        self.assertIn("timed out", out.getvalue())
        self.assertEqual(pressure_levels(app), ["critical", "none"])

    def test_set_pressure_tells_a_missing_method_from_a_failed_request(self):
        self.assertEqual(bm.set_pressure(FakeApp(), "critical"), ("set", None))
        self.assertEqual(bm.set_pressure(FakeApp(), "none"), ("set", None))
        self.assertEqual(bm.set_pressure(FakeApp(override=False), "critical")[0], "missing")
        refused = FakeApp(on_pressure=lambda level: {"error": "level must be normal, warning, critical or none"})
        self.assertEqual(bm.set_pressure(refused, "critical")[0], "failed")
        other = FakeApp(on_pressure=lambda level: {"level": "warning", "override": "warning"})
        self.assertEqual(bm.set_pressure(other, "critical")[0], "failed")
        gone = FakeApp(on_pressure=lambda level: {"value": None})
        self.assertEqual(bm.set_pressure(gone, "critical")[0], "failed")

    def test_hidden_workspaces_give_footprint_per_hidden_workspace_per_kind(self):
        made = []
        bm.open_workspace = lambda app, recipe, url, index, chats=None: made.append(index) or f"ws_{index}"
        samples = iter([
            sample("base", {"app": (1, 100 * MB), "tui-daemon": (1, 20 * MB)}),
            sample("settled", {"app": (1, 140 * MB), "tui-daemon": (1, 40 * MB), "cmux-holder": (1, 8 * MB)}),
            sample("grace", {"app": (1, 102 * MB), "tui-daemon": (1, 24 * MB)}),
        ])
        memory = report([], workspaces=[workspace(False, False, 1, 0, 1024)] * 3
                        + [workspace(True, True, 1, 1, 2 * MB)]
                        + [workspace(True, False, 2, 2, 5 * MB)],
                        terminal={"warm_capacity": 4, "warm_count": 1, "gpu_resident_count": 3,
                                  "hidden_nonvolatile_iosurface_bytes": 3 * MB, "last_frames": 0})
        app, opened = FakeApp(memory=memory), []
        with redirect_stdout(io.StringIO()) as out:
            phase = bm.hidden_workspaces_phase(app, 4, 960, ["terminal"], "about:blank", opened, None,
                                               lambda label: next(samples), "holder")
        self.assertEqual(opened, ["ws_2000", "ws_2001", "ws_2002", "ws_2003"])
        self.assertEqual(app.ran, ["workspace.selectFirst", "workspace.selectFirst"])
        self.assertEqual(self.clock.now, 960)
        self.assertEqual(phase["settled"]["app"]["mb_each"], 10.0)
        self.assertEqual(phase["settled"]["cmux-holder"], {"processes_added": 1, "mb_each": 2.0})
        self.assertEqual(phase["after_grace"]["app"]["mb_each"], 0.5)
        self.assertEqual(phase["after_grace"]["tui-daemon"]["mb_each"], 1.0)
        self.assertEqual(phase["after_grace"]["total"], {"processes_added": 0, "mb_each": 1.5})
        states = phase["debug_memory_after_grace"]
        self.assertEqual(states["unmounted"], {"count": 3, "attributed_mb": 0.0, "terminal_surfaces": 3,
                                               "gpu_resident_surfaces": 0})
        self.assertEqual(states["parked"]["count"], 1)
        self.assertEqual(states["mounted"]["attributed_mb"], 5.0)
        self.assertEqual(phase["hidden_iosurface_mb_after_grace"], 3.0)
        self.assertEqual(phase["terminal_host_model"], "holder")
        self.assertIn("hidden terminal IOSurface (non-volatile): 3.00 MB", out.getvalue())
        self.assertIn("terminal host model holder", out.getvalue())

    def test_hidden_workspaces_without_debug_memory_is_footprint_only(self):
        bm.open_workspace = lambda app, recipe, url, index, chats=None: f"ws_{index}"
        flat = sample("flat", {"app": (1, 100 * MB)})
        with redirect_stdout(io.StringIO()) as out:
            phase = bm.hidden_workspaces_phase(FakeApp(), 2, 0, ["terminal"], "about:blank", [], None,
                                               lambda label: flat, "unknown-attach")
        self.assertNotIn("debug_memory_settled", phase)
        self.assertEqual(phase["after_grace"], phase["settled"])
        self.assertEqual(phase["terminal_host_model"], "unknown-attach")
        self.assertIn("process footprint only", out.getvalue())

    def test_holder_requested_but_terminal_hosts_started_says_hosts(self):
        bm.open_workspace = lambda app, recipe, url, index, chats=None: f"ws_{index}"
        samples = iter([sample("base", {"app": (1, 100 * MB)}),
                        sample("settled", {"app": (1, 100 * MB), "terminal-host": (2, 4 * MB)})])
        with redirect_stdout(io.StringIO()) as out:
            phase = bm.hidden_workspaces_phase(FakeApp(), 2, 0, ["terminal"], "about:blank", [], None,
                                               lambda label: next(samples), "holder")
        self.assertEqual(phase["terminal_host_model"], "hosts")
        self.assertEqual(phase["terminal_host_model_requested"], "holder")
        self.assertIn("requested holder; the daemon started terminal hosts", out.getvalue())


class NavigateTests(unittest.TestCase):
    """navigate-N (p07-memory-101): the local pages chain N same-site navigations, and the phase samples the
    renderers hidden, frozen and at the warning override, which it clears."""

    def setUp(self):
        self.clock = FakeClock()
        self.saved = bm.time
        bm.time = self.clock

    def tearDown(self):
        bm.time = self.saved

    def test_a_local_navigate_page_goes_on_to_the_next_step_and_the_last_one_stops(self):
        import urllib.request
        visits = set()
        urls = bm.local_sites(2, navigate=5, visits=visits)
        self.assertTrue(urls[1].endswith("/nav/5"), urls)
        port = urls[0].split(":")[2].split("/")[0]

        def page(site, step):
            request = urllib.request.Request(f"http://127.0.0.1:{port}/nav/{step}", headers={"Host": f"site{site}.localhost"})
            with urllib.request.urlopen(request, timeout=10) as reply:
                return reply.read().decode()

        self.assertIn("location.href='/nav/4'", page(1, 5))
        self.assertNotIn("location.href", page(1, 0))
        self.assertEqual(visits, {(1, 5), (1, 0)})
        self.assertTrue(bm.local_sites(1)[0].endswith("/"), "a plain local site gained a chain")

    def run_phase(self, app, visits, tabs=2, freeze_wait=30.0, hidden=True):
        renderers = iter([(tabs * 6, 600 * MB), (tabs * 6, 590 * MB), (tabs, 100 * MB)])

        def settle_and_sample(label):
            count, footprint = next(renderers)
            return sample(label, {"app": (1, 200 * MB), "cef-renderer": (count, footprint)})

        hides = []
        with redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(io.StringIO()):
            phase = bm.navigate_phase(app, 5, tabs, visits, lambda: hides.append(1) or ("ws_1" if hidden else None),
                                      settle_and_sample, freeze_wait, 10.0)
        return phase, hides, out.getvalue()

    def test_the_phase_samples_hidden_frozen_and_at_warning_and_clears_the_override(self):
        class Features(FakeApp):
            def call(self, method, params=None, label=None, timeout=120):
                if method == "features.list":
                    return {"features": [{"name": bm.BFCACHE_FEATURE, "state": "on", "source": "local"}]}
                return super().call(method, params, label, timeout)

        app = Features()
        phase, hides, out = self.run_phase(app, {(0, 0), (1, 0)})
        self.assertEqual(hides, [1])
        self.assertEqual(phase["bfcache_flush"], "on")
        self.assertEqual(phase["navigated"], 2)
        self.assertEqual(phase["points"]["hidden"], {"renderers": 12, "renderer_mb": 600.0, "total_mb": 800.0})
        self.assertEqual(phase["deltas"]["frozen"]["renderer_mb"], -10.0)
        self.assertEqual(phase["deltas"]["warning"], {"renderers": -10, "renderer_mb": -500.0, "total_mb": -500.0})
        self.assertEqual(pressure_levels(app), ["warning", "none"])
        self.assertEqual(self.clock.now, 40.0)
        self.assertIn("navigate-5: 2 tabs, 2 walked their chain, memoryBackForwardCacheFlush on", out)

    def test_tabs_that_never_finish_their_chain_are_waited_for_then_counted(self):
        phase, _, _ = self.run_phase(FakeApp(), {(0, 0), (1, 3)}, freeze_wait=0)
        self.assertEqual(phase["navigated"], 1)
        self.assertIsNone(phase["bfcache_flush"])
        self.assertNotIn("frozen", phase["points"])
        self.assertGreaterEqual(self.clock.now, bm.NAVIGATE_WAIT_S)

    def test_without_the_override_the_warning_sample_is_skipped(self):
        app = FakeApp(override=False)
        phase, _, _ = self.run_phase(app, {(0, 0), (1, 0)}, freeze_wait=0)
        self.assertEqual(phase["skipped"], "no pressure override")
        self.assertEqual(list(phase["points"]), ["hidden"])
        self.assertEqual(pressure_levels(app), ["warning", "none"])

    def test_no_workspace_to_show_is_an_error_and_sets_no_pressure(self):
        app = FakeApp()
        phase, _, _ = self.run_phase(app, {(0, 0), (1, 0)}, hidden=False)
        self.assertIn("never went hidden", phase["error"])
        self.assertEqual(pressure_levels(app), [])

    def test_the_options_need_local_tabs_and_a_launch(self):
        with redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            for argv in (["--navigate", "5"], ["--tabs", "20", "--navigate", "0"],
                         ["--tabs", "20", "--navigate", "5", "--urls", "real"],
                         ["--tabs", "20", "--bfcache-flush", "on"],
                         ["--tabs", "20", "--navigate", "5", "--bfcache-flush", "on", "--socket", "/tmp/s",
                          "--app-pid", "1"]):
                with self.assertRaises(SystemExit, msg=argv):
                    bm.parse_args(["--app", "/tmp/x.app", *argv])
        args, _ = bm.parse_args(["--app", "/tmp/x.app", "--tabs", "20", "--navigate", "5", "--bfcache-flush", "off"])
        self.assertEqual((args.navigate, args.bfcache_flush), (5, "off"))


class LaunchTests(unittest.TestCase):
    """The host model reaches the launched app under its CMUX_NEXT_ name (the app strips inherited CMUX_TUI_*)."""

    def test_launch_env_carries_the_terminal_host_model(self):
        self.assertEqual(bm.launch_env("", "holder"), {"CMUX_NEXT_TUI_TERMINAL_HOST_MODEL": "holder"})
        self.assertEqual(bm.launch_env("--a:--b", None), {"CMUX_NEXT_CEF_EXTRA_SWITCHES": "--a:--b"})

    def test_the_launched_app_gets_the_terminal_host_model(self):
        with tempfile.TemporaryDirectory() as root:
            bundle = Path(root, "cmux DEV.app")
            Path(bundle, "Contents/MacOS").mkdir(parents=True)
            with open(Path(bundle, "Contents/Info.plist"), "wb") as handle:
                plistlib.dump({"CFBundleExecutable": "cmux DEV"}, handle)
            binary = str(Path(bundle, "Contents/MacOS/cmux DEV"))
            started = {}

            def popen(argv, env, **kwargs):
                started.update(argv=argv, env=env)

            saved = (bm.bundle_pids, bm.process_table, bm.control_socket, bm.subprocess.Popen)
            bm.bundle_pids = lambda bundle: set()
            bm.process_table = lambda: [(77, 1, binary)] if started else []
            bm.control_socket = lambda bundle, pid, dirs: "/tmp/fake.sock"
            bm.subprocess.Popen = popen
            try:
                pid, socket_path, scratch = bm.launch(str(bundle), {}, bm.launch_env("", "holder"), direct=True)
            finally:
                bm.bundle_pids, bm.process_table, bm.control_socket, bm.subprocess.Popen = saved
            bm.shutil.rmtree(scratch, ignore_errors=True)
        self.assertEqual((pid, socket_path), (77, "/tmp/fake.sock"))
        self.assertEqual(started["argv"], [binary])
        self.assertEqual(started["env"]["CMUX_NEXT_TUI_TERMINAL_HOST_MODEL"], "holder")
        self.assertNotIn("CMUX_TUI_TERMINAL_HOST_MODEL", started["env"])


if __name__ == "__main__":
    unittest.main()
