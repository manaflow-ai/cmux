#!/usr/bin/env python3
"""idle-budget.py's pure parts: process kinds, per-kind sums, the budget check, the perf cron rows and the shipping
measurement mode (launch env, Debug refusal under --gate, the five report fields)."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import shutil
import sys
import tempfile
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "perf-bench"))
if sys.platform != "darwin":
    sys.modules.setdefault("procs", types.ModuleType("procs"))  # procs loads libproc at import; the pure parts need none
spec = importlib.util.spec_from_file_location("idle_budget", HERE / "idle-budget.py")
ib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ib)

APP = "/Users/x/DerivedData/cmux-t/Build/Products/Debug/cmux DEV t.app"


def row(kind, threads, wakeups, cpu=0.0):
    return {"kind": kind, "threads": threads, "threads_ran": 0, "wakeups_per_s": wakeups, "csw_per_s": 0.0, "cpu_pct": cpu}


class IdleBudgetTests(unittest.TestCase):
    def test_kinds(self):
        self.assertEqual(ib.kind(f"{APP}/Contents/MacOS/cmux DEV"), "app")
        self.assertEqual(ib.kind(f"{APP}/Contents/Resources/bin/cmux-tui server --socket s"), "daemon")
        self.assertEqual(ib.kind(f"{APP}/Contents/Resources/bin/cmux-tui __holder --socket s"), "holder")
        self.assertEqual(ib.kind(f"{APP}/Contents/Resources/bin/cmux-tui __terminal-host --owner a@1"), "terminal-host")
        self.assertEqual(ib.kind(f"{APP}/Contents/Resources/bin/acpmux daemon"), "acpmux")
        self.assertEqual(ib.kind(f"{APP}/Contents/Frameworks/cmux Helper (Renderer).app/x --type=renderer"), "cef-renderer")
        self.assertEqual(ib.kind(f"{APP}/Contents/Frameworks/cmux Helper (GPU).app/x --type=gpu-process"), "cef-gpu")
        self.assertEqual(ib.kind("/bin/zsh -l"), "other:zsh")

    def test_aggregate_sums_and_maxes_per_kind(self):
        kinds = ib.aggregate({"processes": [row("terminal-host", 3, 0.0), row("terminal-host", 5, 0.5), row("app", 40, 2.0)],
                              "main_wakes_per_s": 1.5})
        self.assertEqual(kinds["terminal-host"]["n"], 2)
        self.assertEqual(kinds["terminal-host"]["threads"], 8)
        self.assertEqual(kinds["terminal-host"]["threads_max"], 5)
        self.assertEqual(kinds["terminal-host"]["wakeups_max"], 0.5)
        self.assertEqual(kinds["app"]["main_wakes_per_s"], 1.5)

    def test_over_budget_names_each_value_over_its_limit(self):
        budget = {"kinds": {"app": {"main_wakes_per_s": 0, "wakeups_per_s": 1.0, "threads_max": None},
                            "holder": {"wakeups_max": {"light": 0, "stress": 1}}}}
        kinds = {"app": {"main_wakes_per_s": 0.2, "wakeups_per_s": 0.9, "threads_max": 99},
                 "holder": {"wakeups_max": 0.5}}
        self.assertEqual(ib.over_budget("light", kinds, budget), [("app", "main_wakes_per_s", 0.2, 0), ("holder", "wakeups_max", 0.5, 0)])
        self.assertEqual(ib.over_budget("stress", kinds, budget), [("app", "main_wakes_per_s", 0.2, 0)])

    def test_cron_rows(self):
        report = {"sessions": {"light": {"kinds": {"app": {"wakeups_per_s": 0.4, "threads_max": 30, "main_wakes_per_s": 0}}}}}
        rows = ib.cron_rows(report, {"kinds": {"app": {"wakeups_per_s": 1.0}}})
        self.assertEqual(rows["idle_budget.light.app.wakeups_per_s"],
                         {"p50": 0.4, "p95": 0.4, "unit": "/s", "budget": 1.0, "floor": 0.5})
        self.assertEqual(rows["idle_budget.light.app.threads_max"]["unit"], "threads")
        self.assertIsNone(rows["idle_budget.light.app.threads_max"]["budget"])

    def test_checked_in_budget_parses(self):
        budget = ib.json.load(open(ib.BUDGET_FILE))
        self.assertEqual(budget["kinds"]["app"]["main_wakes_per_s"], 0)


def bundle(folder, debug):
    """A `cmux DEV t.app` with an empty main executable; `debug` adds Xcode's `.debug.dylib` beside it."""
    macos = os.path.join(folder, "cmux DEV t.app", "Contents", "MacOS")
    os.makedirs(macos)
    open(os.path.join(macos, "cmux DEV"), "wb").close()
    if debug:
        open(os.path.join(macos, "cmux DEV.debug.dylib"), "wb").close()
    return os.path.dirname(os.path.dirname(macos))


SHIPPING_KEYS = {"CMUX_NEXT_BENCH_SHIPPING_DRAW": "1", "CMUX_NEXT_DEV_SENTRY": "1", "CMUX_NEXT_DEV_HANG_REPORTS": "1"}


class ShippingModeTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="idle-budget-test-")
        self.addCleanup(shutil.rmtree, self.folder, True)

    def test_launch_env_holds_the_three_keys_and_drops_no_activate(self):
        env = ib.launch_env()
        for key, value in SHIPPING_KEYS.items():
            self.assertEqual(env[key], value)
        self.assertIn("CMUX_NEXT_NO_ACTIVATE", env)
        self.assertIsNone(env["CMUX_NEXT_NO_ACTIVATE"])  # None removes BASE_ENV's value
        self.assertNotIn("CMUX_NEXT_BENCH_SHIPPING_DRAW", ib.launch_env(shipping_draw=False))

    def test_the_app_is_started_with_the_three_keys(self):
        import bench_launch
        app = bench_launch.BenchApp(bundle(self.folder, debug=False), out=os.path.join(self.folder, "out"),
                                    teardown=False, env=ib.launch_env())
        env = app.environment()
        for key, value in SHIPPING_KEYS.items():
            self.assertEqual(env.get(key), value)
        self.assertNotIn("CMUX_NEXT_NO_ACTIVATE", env)
        self.assertEqual(env["CMUX_NEXT_SOCKET_MODE"], "automation")  # the bench still reaches the socket

    def test_activate_refuses_a_no_activate_launch(self):
        import bench_launch
        app = bench_launch.BenchApp(bundle(self.folder, debug=False), out=os.path.join(self.folder, "out"),
                                    teardown=False)
        app.process = types.SimpleNamespace(poll=lambda: None)
        app.launched_env = app.environment()
        result = app.activate()
        self.assertFalse(result["activated"])
        self.assertIn("CMUX_NEXT_NO_ACTIVATE=1", result["error"])

    def test_gate_on_a_debug_bundle_exits_non_zero_with_the_reason(self):
        app = bundle(self.folder, debug=True)
        self.assertEqual(ib.bundle_build_config(app), "debug")
        out = io.StringIO()
        with contextlib.redirect_stdout(out), self.assertRaises(SystemExit) as raised:
            ib.main(["--app", app, "--gate", "--out", os.path.join(self.folder, "out")])
        self.assertNotEqual(raised.exception.code, 0)
        self.assertIn("IDLE-BUDGET-REFUSED build_config=debug", out.getvalue())
        self.assertIn("refuses a Debug build", out.getvalue())

    def test_gate_accepts_release_and_bench_hooks_and_no_gate_accepts_debug(self):
        self.assertEqual(ib.bundle_build_config(bundle(self.folder, debug=False)), "release")
        self.assertIsNone(ib.gate_refusal("release", True))
        self.assertIsNone(ib.gate_refusal("bench-hooks", True))
        self.assertIsNone(ib.gate_refusal("debug", False))

    def test_the_five_fields(self):
        import bench_launch
        env = {**bench_launch.BASE_ENV, **{k: v for k, v in ib.launch_env().items() if v is not None}}
        env.pop("CMUX_NEXT_NO_ACTIVATE", None)
        fields = ib.shipping_fields("bench-hooks", env, ["main", "SentryCrash Exception Handler (Primary)"],
                                    {"installed": True}, {"activated": True, "error": ""})
        self.assertEqual(tuple(fields), ib.SHIPPING_FIELDS)
        self.assertEqual(set(ib.SHIPPING_FIELDS),
                         {"build_config", "sentry_started", "hang_reports", "draws_when_occluded", "activated"})
        self.assertEqual(fields["build_config"], "bench-hooks")
        self.assertTrue(fields["sentry_started"])
        self.assertEqual(fields["hang_reports"], {"dev_opt_in": True, "watchdog": True})
        self.assertFalse(fields["draws_when_occluded"])
        self.assertTrue(fields["activated"]["activated"])
        quiet = ib.shipping_fields("debug", {}, ["main"], {}, {"activated": False, "error": "x"})
        self.assertFalse(quiet["sentry_started"])
        self.assertEqual(quiet["hang_reports"], {"dev_opt_in": False, "watchdog": False})

    def test_draws_when_occluded_follows_window_draw_policy(self):
        automation = {"CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation"}
        self.assertTrue(ib.draws_when_occluded("debug", automation))
        self.assertFalse(ib.draws_when_occluded("debug", {**automation, "CMUX_NEXT_BENCH_SHIPPING_DRAW": "1"}))
        self.assertFalse(ib.draws_when_occluded("bench-hooks", automation))
        self.assertFalse(ib.draws_when_occluded("release", automation))
        self.assertFalse(ib.draws_when_occluded("debug", {}))


if __name__ == "__main__":
    unittest.main()
