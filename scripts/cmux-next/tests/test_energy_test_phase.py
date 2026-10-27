#!/usr/bin/env python3
"""energy-test-phase.py (p14-energy-123): D7 auto simulates 15% on battery, wants reason `battery`, always clears,
and wants the Mac's own policy and inputs back, "Turn Off for Now" included; a hung app or a failed clear is a
problem, never a crash; --dry-run prints the exact commands; no workflow references it.

  python3 -m pytest scripts/cmux-next/tests/test_energy_test_phase.py
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "energy-test-phase.py"
REPO = SCRIPT.parents[2]


def load():
    spec = importlib.util.spec_from_file_location("cmux_next_energy_test_phase", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


phase = load()


def report(saver=False, reason=None, simulated=False, on_battery=False, percent=None, feature=True, setting="auto",
           session_override=False):
    """A debug.energy report with the fields D7 auto reads."""
    return {
        "policy": {"isSaver": saver, "reason": reason},
        "inputs": {"featureEnabled": feature, "setting": setting, "simulated": simulated, "onBattery": on_battery,
                   "hasBattery": on_battery, "batteryPercent": percent, "thermal": "nominal", "lowPowerMode": False,
                   "suspended": False, "sessionOverride": session_override, "reason": reason},
    }


class FakeApp:
    """The app's two methods: debug.energy and debug.energy.simulate (which answers debug.energy)."""

    def __init__(self, simulate_reason="battery", forget_clear=False, fail_simulate=False, fail_clear=False):
        self.simulate_reason = simulate_reason
        self.forget_clear = forget_clear
        self.fail_simulate = fail_simulate
        self.fail_clear = fail_clear
        self.calls = []
        self.simulating = False

    def rpc(self, method, params):
        self.calls.append((method, params))
        if method == phase.SIMULATE:
            if params == phase.CLEAR:
                if self.fail_clear:
                    raise phase.RpcError("debug.energy.simulate: no answer in 60 s")
                self.simulating = self.simulating and self.forget_clear
            else:
                if self.fail_simulate:
                    raise phase.RpcError("debug.energy.simulate: method not found")
                self.simulating = True
        if self.simulating:
            return report(saver=self.simulate_reason is not None, reason=self.simulate_reason, simulated=True,
                          on_battery=True, percent=15)
        return report()


class D7AutoTests(unittest.TestCase):
    def test_fifteen_percent_on_battery_with_reason_battery_passes(self):
        app = FakeApp()
        results = phase.run(["D7-auto"], app.rpc)
        self.assertTrue(results["D7-auto"]["pass"], results["D7-auto"]["problems"])
        self.assertEqual(app.calls, [(phase.ENERGY, {}), (phase.SIMULATE, {"on_battery": True, "percent": 15}),
                                     (phase.SIMULATE, {"clear": True})])

    def test_another_reason_fails(self):
        results = phase.run(["D7-auto"], FakeApp(simulate_reason=None).rpc)
        self.assertFalse(results["D7-auto"]["pass"])
        self.assertIn("reason 'battery'", results["D7-auto"]["problems"][0])

    def test_a_clear_that_does_not_restore_fails(self):
        results = phase.run(["D7-auto"], FakeApp(forget_clear=True).rpc)
        problems = " ".join(results["D7-auto"]["problems"])
        self.assertIn("after clear: inputs.simulated is not false", problems)
        self.assertIn("is not the Mac's", problems)

    def test_the_simulation_is_cleared_even_when_simulate_fails(self):
        app = FakeApp(fail_simulate=True)
        results = phase.run(["D7-auto"], app.rpc)
        self.assertFalse(results["D7-auto"]["pass"])
        self.assertEqual(app.calls[-1], (phase.SIMULATE, {"clear": True}))
        self.assertEqual(results["D7-auto"]["problems"], ["debug.energy.simulate: method not found"])

    def test_a_failed_clear_adds_a_problem_and_keeps_the_first(self):
        results = phase.run(["D7-auto"], FakeApp(fail_simulate=True, fail_clear=True).rpc)
        problems = results["D7-auto"]["problems"]
        self.assertEqual(problems[0], "debug.energy.simulate: method not found")
        self.assertIn("simulation may still be active", problems[1])
        self.assertEqual(len(problems), 2)

    def test_a_failed_clear_after_a_good_simulation_fails(self):
        results = phase.run(["D7-auto"], FakeApp(fail_clear=True).rpc)
        self.assertFalse(results["D7-auto"]["pass"])
        self.assertIn("simulation may still be active", results["D7-auto"]["problems"][0])

    def test_a_clear_that_ends_turn_off_for_now_fails(self):
        problems = phase.judge_d7_auto(report(session_override=True), report(simulated=True, on_battery=True, percent=15,
                                                                             session_override=True), report())
        self.assertIn("after clear: inputs sessionOverride differ from the Mac's", problems)

    def test_turn_off_for_now_held_is_named_instead_of_a_missing_reason(self):
        held = report(session_override=True)
        problems = phase.judge_d7_auto(held, report(simulated=True, on_battery=True, percent=15, session_override=True), held)
        self.assertTrue(any("Turn Off Energy Saver for Now" in problem for problem in problems), problems)
        self.assertFalse(any("reason 'battery'" in problem for problem in problems), problems)

    def test_the_feature_off_says_how_to_fix_it(self):
        problems = phase.judge_d7_auto(report(feature=False), report(), report(feature=False))
        self.assertTrue(any("energySaver feature is off" in problem for problem in problems))

    def test_another_setting_is_named(self):
        problems = phase.judge_d7_auto(report(setting="off"), report(saver=True, reason="battery", simulated=True,
                                                                       on_battery=True, percent=15), report(setting="off"))
        self.assertEqual(problems, ["energy.saver is 'off', D7 auto needs 'auto'"])


class ReplyTests(unittest.TestCase):
    def test_the_result_of_an_ok_reply(self):
        self.assertEqual(phase.parse_reply("m", '{"id":1,"ok":true,"result":{"a":1}}\n'), {"a": 1})

    def test_an_error_reply_or_no_json_raises(self):
        with self.assertRaises(phase.RpcError):
            phase.parse_reply("m", json.dumps({"id": 1, "ok": False, "error": {"code": "invalid_params"}}))
        with self.assertRaises(phase.RpcError):
            phase.parse_reply("m", "")

    def test_a_hung_app_or_a_cli_that_does_not_run_is_an_rpc_error(self):
        def hung(command, **kwargs):
            raise subprocess.TimeoutExpired(command, kwargs["timeout"])

        def missing(command, **kwargs):
            raise FileNotFoundError(2, "No such file or directory", command[0])

        with self.assertRaisesRegex(phase.RpcError, "no answer in 60 s"):
            phase.cli_rpc("energy-sim", runner=hung)(phase.ENERGY, {})
        with self.assertRaisesRegex(phase.RpcError, "did not run"):
            phase.cli_rpc("energy-sim", runner=missing)(phase.ENERGY, {})

    def test_a_hung_app_still_gets_a_report(self):
        def hung(command, **kwargs):
            raise subprocess.TimeoutExpired(command, kwargs["timeout"])

        results = phase.run(["D7-auto"], phase.cli_rpc("energy-sim", runner=hung))
        self.assertFalse(results["D7-auto"]["pass"])
        self.assertIn("simulation may still be active", results["D7-auto"]["problems"][-1])
        self.assertIn("D7-auto", phase.markdown(results))


class CommandLineTests(unittest.TestCase):
    def test_dry_run_prints_each_exact_command(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(phase.main(["--tag", "energy-sim", "--dry-run"]), 0)
        self.assertIn("CMUX_TAG=energy-sim scripts/cmux-debug-cli.sh rpc debug.energy.simulate "
                      "'{\"on_battery\":true,\"percent\":15}'", out.getvalue())
        self.assertIn("rpc debug.energy.simulate '{\"clear\":true}'", out.getvalue())

    def test_an_unknown_check_is_refused_before_anything_runs(self):
        with self.assertRaises(SystemExit):
            phase.parse_checks("D7-auto,D99")

    def test_no_workflow_references_the_script(self):
        workflows = REPO / ".github" / "workflows"
        if not workflows.is_dir():
            self.skipTest("no .github/workflows in this checkout")
        for path in workflows.glob("*.y*ml"):
            self.assertNotIn("energy-test-phase", path.read_text(errors="replace"), path.name)


if __name__ == "__main__":
    unittest.main()
