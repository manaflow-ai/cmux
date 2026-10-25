#!/usr/bin/env python3
"""bench_memory.py phases (p07-memory-013): --hidden-workspaces gives the footprint each hidden workspace adds per
process kind, --pressure gives released_mb, release_s and the managed consumers' footprint before, and both fall
back to process footprint on a build without debug.memory. Runs on any OS: the app socket and proc_pid_rusage are
fakes. Local only: python3 -I scripts/cmux-next/tests/test_bench_memory_phases.py"""

from __future__ import annotations

import io
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import bench_memory as bm  # noqa: E402

MB = 1048576


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
    """The control socket: debug.memory (when `memory` is set), the pressure override (when `override`)."""

    def __init__(self, memory=None, override=True):
        self.memory = memory
        self.override = override
        self.calls: list[tuple[str, dict]] = []
        self.ran: list[str] = []

    def call(self, method, params=None, label=None, timeout=120):
        self.calls.append((method, params or {}))
        if method == "debug.memory":
            return self.memory() if callable(self.memory) else (self.memory or {"error": "unknown method"})
        if method == "debug.hibernation.pressure":
            return {"pressure": params["level"]} if self.override else {"error": "unknown method"}
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


def report(consumers, workspaces=()):
    return {"pressure": {"level": "normal"}, "consumers": consumers, "workspaces": list(workspaces)}


class PhaseTests(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        self.saved = (bm.time, bm.usage, bm.open_workspace)
        bm.time = self.clock

    def tearDown(self):
        bm.time, bm.usage, bm.open_workspace = self.saved

    def test_managed_consumers_follow_chromes_should_manage_consumer_and_keep_unknown_bytes(self):
        memory = bm.MemoryReport(report([
            {"name": "previews", "traits": {"isStateful": True, "supportsMemoryLimit": True}, "footprintBytes": 4 * MB},
            {"name": "home.rows", "traits": {"is_stateful": "kYes", "supports_memory_limit": "kYes"},
             "footprint_bytes": None},
            {"name": "planner", "traits": {"isStateful": False, "supportsMemoryLimit": True}, "footprintBytes": 9 * MB},
            {"name": "explicit", "managed": True, "footprintBytes": MB},
        ]))
        self.assertEqual(memory.managed(), {"previews": 4 * MB, "home.rows": None, "explicit": MB})
        self.assertEqual(memory.managed_bytes(), (5 * MB, 1))
        self.assertEqual(memory.level(), "normal")

    def test_pressure_reports_release_against_managed_footprint_and_restores_normal(self):
        footprints = iter([300 * MB] + [300 * MB - min(step, 10) * 10 * MB for step in range(1, 200)])
        bm.usage = lambda pid: (0, next(footprints), 0, 0, 0)
        app = FakeApp(memory=report([{"name": "previews", "managed": True, "footprintBytes": 120 * MB}]))
        before, after = sample("b", {"app": (1, 300 * MB)}), sample("a", {"app": (1, 200 * MB)})
        samples = iter([before, after])
        with redirect_stdout(io.StringIO()) as out:
            phase = bm.pressure_phase(app, 42, "critical", 2.0, 0.1, lambda label: next(samples))
        self.assertEqual(phase["released_mb"], 100.0)
        self.assertEqual(phase["managed_before_mb"], 120.0)
        self.assertAlmostEqual(phase["release_s"], 0.9, places=2)
        self.assertEqual(phase["released_pct_of_managed"], 83.3)
        self.assertEqual(phase["kinds_delta_mb"]["app"], -100.0)
        overrides = [params["level"] for method, params in app.calls if method == "debug.hibernation.pressure"]
        self.assertEqual(overrides, ["critical", "normal"])
        self.assertIn("released_mb 100.0", out.getvalue())

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
        with redirect_stdout(io.StringIO()):
            phase = bm.pressure_phase(FakeApp(override=False), 42, "critical", 1.0, 0.1,
                                      lambda label: sample(label, {"app": (1, 50 * MB)}))
        self.assertEqual(phase["skipped"], "no pressure override")

    def test_hidden_workspaces_give_footprint_per_hidden_workspace_per_kind(self):
        made = []
        bm.open_workspace = lambda app, recipe, url, index, chats=None: made.append(index) or f"ws_{index}"
        samples = iter([
            sample("base", {"app": (1, 100 * MB), "tui-daemon": (1, 20 * MB)}),
            sample("settled", {"app": (1, 140 * MB), "tui-daemon": (1, 40 * MB), "terminal-host": (4, 8 * MB)}),
            sample("grace", {"app": (1, 102 * MB), "tui-daemon": (1, 24 * MB)}),
        ])
        memory = report([], workspaces=[{"state": "unmounted", "attributedBytes": 1024}] * 4
                        + [{"state": "mounted", "attributedBytes": 5 * MB}])
        app, opened = FakeApp(memory=memory), []
        with redirect_stdout(io.StringIO()) as out:
            phase = bm.hidden_workspaces_phase(app, 4, 960, ["terminal"], "about:blank", opened, None,
                                               lambda label: next(samples))
        self.assertEqual(opened, ["ws_2000", "ws_2001", "ws_2002", "ws_2003"])
        self.assertEqual(app.ran, ["workspace.selectFirst", "workspace.selectFirst"])
        self.assertEqual(self.clock.now, 960)
        self.assertEqual(phase["settled"]["app"]["mb_each"], 10.0)
        self.assertEqual(phase["settled"]["terminal-host"], {"processes_added": 4, "mb_each": 2.0})
        self.assertEqual(phase["after_grace"]["app"]["mb_each"], 0.5)
        self.assertEqual(phase["after_grace"]["tui-daemon"]["mb_each"], 1.0)
        self.assertEqual(phase["after_grace"]["total"], {"processes_added": 0, "mb_each": 1.5})
        self.assertEqual(phase["debug_memory_after_grace"]["unmounted"], {"count": 4, "attributed_mb": 0.0})
        self.assertIn("terminal host model", out.getvalue())

    def test_hidden_workspaces_without_debug_memory_is_footprint_only(self):
        bm.open_workspace = lambda app, recipe, url, index, chats=None: f"ws_{index}"
        flat = sample("flat", {"app": (1, 100 * MB)})
        with redirect_stdout(io.StringIO()) as out:
            phase = bm.hidden_workspaces_phase(FakeApp(), 2, 0, ["terminal"], "about:blank", [], None,
                                               lambda label: flat)
        self.assertNotIn("debug_memory_settled", phase)
        self.assertEqual(phase["after_grace"], phase["settled"])
        self.assertIn("process footprint only", out.getvalue())


if __name__ == "__main__":
    unittest.main()
