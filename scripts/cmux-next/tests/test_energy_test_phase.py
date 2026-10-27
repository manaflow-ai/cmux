#!/usr/bin/env python3
"""energy-test-phase.py (p14-energy-090, -123): D7 auto simulates 15% on battery, wants reason `battery`, always
clears, and wants the Mac's own policy and inputs back, "Turn Off for Now" included; a hung app or a failed clear is a
problem, never a crash. The D1-D17 orchestrator: --dry-run prints each step's exact command; fixture outputs of
wakeup-audit, idle-budget, cef-idle-probe, bench-typing, xbench, cargo nextest (macOS), cargo test on Linux (a
Testbox pinned to the commit, or --linux-local on a Linux host, task 131) and the Swift suite lane parse into
pass, fail or not judged; --collect-only judges a run folder; it waits for a quiet host; no workflow references it.
Not measured is never a pass: a skipped or refused step's earlier outputs, an unknown value, a failed reader, a failed
reference session, a Debug build's signed-in rows, an unreported CEF counter and a display not at 120 Hz are all
not judged; the idle rows are the median of 3 windows.

  python3 -m pytest scripts/cmux-next/tests/test_energy_test_phase.py
"""
from __future__ import annotations

import argparse
import contextlib
import importlib.util
import io
import json
import re
import shlex
import subprocess
import sys
import tempfile
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
        problems, _ = phase.run_d7_auto(app.rpc)
        self.assertEqual(problems, [])
        self.assertEqual(app.calls, [(phase.ENERGY, {}), (phase.SIMULATE, {"on_battery": True, "percent": 15}),
                                     (phase.SIMULATE, {"clear": True})])

    def test_another_reason_fails(self):
        problems, _ = phase.run_d7_auto(FakeApp(simulate_reason=None).rpc)
        self.assertIn("reason 'battery'", problems[0])

    def test_a_clear_that_does_not_restore_fails(self):
        problems = " ".join(phase.run_d7_auto(FakeApp(forget_clear=True).rpc)[0])
        self.assertIn("after clear: inputs.simulated is not false", problems)
        self.assertIn("is not the Mac's", problems)

    def test_the_simulation_is_cleared_even_when_simulate_fails(self):
        app = FakeApp(fail_simulate=True)
        problems, _ = phase.run_d7_auto(app.rpc)
        self.assertEqual(app.calls[-1], (phase.SIMULATE, {"clear": True}))
        self.assertEqual(problems, ["debug.energy.simulate: method not found"])

    def test_a_failed_clear_adds_a_problem_and_keeps_the_first(self):
        problems, _ = phase.run_d7_auto(FakeApp(fail_simulate=True, fail_clear=True).rpc)
        self.assertEqual(problems[0], "debug.energy.simulate: method not found")
        self.assertIn("simulation may still be active", problems[1])
        self.assertEqual(len(problems), 2)

    def test_a_failed_clear_after_a_good_simulation_fails(self):
        problems, _ = phase.run_d7_auto(FakeApp(fail_clear=True).rpc)
        self.assertIn("simulation may still be active", problems[0])

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

        problems, _ = phase.run_d7_auto(phase.cli_rpc("energy-sim", runner=hung))
        self.assertIn("simulation may still be active", problems[-1])

    def test_a_bench_app_error_reply_is_an_rpc_error(self):
        class App:
            def rpc(self, method, params, timeout):
                return {"error": "connection refused", "unreachable": True} if params else {"policy": {}, "error": None,
                                                                                              "inputs": {}}

        call = phase.bench_rpc(App())
        self.assertIn("inputs", call(phase.ENERGY, {}))  # a report that carries an `error` field is still a report
        with self.assertRaisesRegex(phase.RpcError, "connection refused"):
            call(phase.SIMULATE, phase.CLEAR)


SHA = "0123456789abcdef0123456789abcdef01234567"
APP = "/fleet/cmux DEV energy-p.app"


def dry_run(*args):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = phase.main(["--ref", SHA, "--out", "/tmp/etp", "--dry-run", *args])
    return code, out.getvalue()


class CommandLineTests(unittest.TestCase):
    def test_dry_run_prints_each_exact_command(self):
        code, text = dry_run("--tag", "energy-sim")
        self.assertEqual(code, 0)
        self.assertIn("CMUX_TAG=energy-sim scripts/cmux-debug-cli.sh rpc debug.energy.simulate "
                      "'{\"on_battery\":true,\"percent\":15}'", text)
        self.assertIn("rpc debug.energy.simulate '{\"clear\":true}'", text)
        self.assertIn("# idle-budget (D2, D3, D4, D5, D6, D7, D11, D12, D13, D14, D15, D16, D17): skipped, needs --app", text)

    def test_dry_run_with_a_bundle_prints_every_step(self):
        code, text = dry_run("--app", APP, "--debug-app", "/fleet/Debug/cmux DEV energy-p.app",
                             "--chrome-app", "/Apps/Chromium.app", "--chrome-ublock", "/cache/ublock",
                             "--linux-testbox", "tbx_energy")
        self.assertEqual(code, 0)
        self.assertNotIn("skipped", text)
        self.assertIn("python3 -I scripts/cmux-next/wakeup-audit.py --strict\n", text)
        for window in (1, 2, 3):
            self.assertIn(f"python3 scripts/cmux-next/idle-budget.py --app '/fleet/cmux DEV energy-p.app' --out "
                          f"/tmp/etp/idle-budget/w{window} --json /tmp/etp/idle-budget/w{window}/idle-budget.json --sessions "
                          "light-webkit,light,light-hidden,minimized,occluded,tabs-static,chrome-static,stress-static,home,"
                          "energy-saver,app-quit,external-churn,agent-idle,agent-working-visible,busy-hidden --settle 60 "
                          "--measure 60 --gate --chrome-app /Apps/Chromium.app --chrome-ublock /cache/ublock\n", text)
            self.assertIn(f"python3 scripts/cmux-next/cef-idle-probe.py --app '/fleet/cmux DEV energy-p.app' --out "
                          f"/tmp/etp/cef-idle/w{window} --settle 60 --window 60\n", text)
        self.assertNotIn("/w4", text)
        self.assertIn("--sessions light-hidden,signed-in,signed-in-display-sleep --settle 60 --measure 60 --chrome-app", text)
        self.assertIn("# display: VDisplay 120 28800 main 1920x1200 as the main display for the measuring steps "
                      "(scripts/perf-lab/run_story.py VirtualDisplay", text)
        self.assertIn("--surface terminal,agent-composer-chromium,chromium-page-scroll --energy-saver off,on", text)
        self.assertIn("xbench.py run --out /tmp/etp/xbench/run --app 'cmux=/fleet/cmux DEV energy-p.app' --app "
                      "chrome=/Apps/Chromium.app --chrome-extension /cache/ublock --browsers cmux-chromium,cmux-terminal,"
                      "chrome --rounds 3 --max-load 4\n", text)
        self.assertIn("python3 scripts/cmux-next/idle-budget.py --xbench /tmp/etp/xbench/results.json", text)
        self.assertIn("CMUX_TAG=energy-p scripts/cmux-debug-cli.sh rpc debug.energy '{}'", text)
        self.assertIn(f"cmux-ci run --class isolated --script scripts/ci/cmux-tui-rust-check.sh --ref {SHA} --key "
                      f"energy-test-phase-{SHA}-d9 --arg=test --arg=daemon_idle", text)
        self.assertIn("--script scripts/ci/package-test-lane.sh", text)
        self.assertIn("--arg=suite --arg=Packages/macOS/CmuxNext --arg=MainWakeUpQueueTests,DemandTimerLeewayTests,", text)

    def test_checks_select_their_steps(self):
        _, text = dry_run("--app", APP, "--checks", "D9,D1")
        self.assertEqual([line.split(":")[0] for line in text.splitlines() if line.startswith("# ")],
                         ["# audit (D1)", "# rust-idle (D9)", "# rust-idle-linux (D9)"])

    def test_the_real_display_is_named_and_static_checks_bring_up_none(self):
        _, text = dry_run("--app", APP, "--checks", "D8", "--vdisplay", "0")
        self.assertIn("# display: the real main display (--vdisplay 0)", text)
        _, text = dry_run("--app", APP, "--checks", "D1,D9")
        self.assertNotIn("# display:", text)

    def test_checks_select_the_idle_sessions_they_need(self):
        self.assertEqual(phase.idle_sessions(["D3"]), ("light", "light-hidden", "minimized", "occluded"))
        self.assertEqual(phase.idle_sessions(["D7", "D12"]), ("tabs-static", "energy-saver"))
        self.assertEqual(phase.idle_sessions(["D15"]), phase.BENCH_SESSIONS)
        _, text = dry_run("--app", APP, "--checks", "D5")
        self.assertIn("--sessions stress-static --settle 60 --measure 60 --gate", text)

    def test_d9_prints_a_linux_testbox_command_not_a_workflow(self):
        code, text = dry_run("--checks", "D9", "--linux-testbox", "tbx_energy")
        self.assertEqual(code, 0)
        linux = text.split("# rust-idle-linux (D9)\n", 1)[1].splitlines()
        pin = phase.TESTBOX_PIN.format(ref=SHA)
        self.assertEqual(linux, [
            shlex.join(["blacksmith", "testbox", "run", "--id", "tbx_energy", pin]),
            shlex.join(["blacksmith", "testbox", "run", "--id", "tbx_energy", phase.D9_LINUX_SCRIPT])])
        self.assertTrue(pin.startswith(f"set -euo pipefail; git fetch --no-tags origin {SHA}; git reset --hard {SHA};"))
        self.assertTrue(pin.endswith("bash scripts/ci/init-submodule.sh ghostty-next; git rev-parse HEAD"))
        self.assertNotIn(".github", text)
        self.assertNotIn("gh workflow", text)

    def test_without_a_linux_host_the_linux_step_is_skipped_but_printed(self):
        _, text = dry_run("--checks", "D9")
        self.assertIn("# rust-idle-linux (D9): skipped, needs --linux-testbox TBX", text)
        self.assertIn("blacksmith testbox run --id TBX 'cd cmux-tui && rc=0; { cargo test --locked -p cmux-tui", text)

    def test_linux_local_runs_cargo_only_on_a_linux_checkout_at_the_ref(self):
        saved = phase.IS_LINUX
        try:
            phase.IS_LINUX = False
            _, text = dry_run("--checks", "D9", "--linux-local")
            self.assertIn("# rust-idle-linux (D9): skipped, --linux-local runs cargo on this host, which is not Linux", text)
            self.assertIn("bash -c 'cd cmux-tui && rc=0; { cargo test --locked -p cmux-tui --test idle_wakeups --no-run", text)
            phase.IS_LINUX = True
            self.assertIn(f"not --ref {SHA[:12]}", phase.linux_local_problem(SHA))  # this checkout is not at SHA
        finally:
            phase.IS_LINUX = saved

    def test_a_testbox_id_or_ref_that_is_not_one_is_refused(self):
        for args in (["--linux-testbox", "tbx_a; rm -rf ~"], ["--linux-testbox", "box"],
                     ["--linux-testbox", "tbx_a", "--linux-local"]):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                dry_run("--checks", "D9", *args)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            phase.main(["--ref", "HEAD", "--checks", "D9", "--linux-testbox", "tbx_a", "--dry-run"])

    def test_an_unknown_check_or_bundle_is_refused_before_anything_runs(self):
        with self.assertRaises(SystemExit):
            phase.parse_checks("D7,D99")
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            phase.main(["--app", "/fleet/Other.app", "--dry-run"])

    def test_no_workflow_references_the_script(self):
        workflows = REPO / ".github" / "workflows"
        if not workflows.is_dir():
            self.skipTest("no .github/workflows in this checkout")
        for path in workflows.glob("*.y*ml"):
            self.assertNotIn("energy-test-phase", path.read_text(errors="replace"), path.name)


BUDGET = {"assertions_allowed_when": ["sessions.keepAwake", "phone.keepAwake"],
          "allowed_periodic": [{"owner": "GitHubFeedSource.refresh", "period_s": 120}],
          "sessions": {"agent-idle": {"kinds": {"agent-harness": {
              "hidden_wakeups_max": None, "_hidden_wakeups_max": "task 140 turns it on"}}}}}


def renderer(pid, hidden=True, wakeups=0.0):
    return {"pid": pid, "kind": "cef-renderer", "hidden": hidden, "wakeups_per_s": wakeups}


def idle_report(over=(), exits=None, refused=(), ledger=None, renderers=None, not_judged=None, readers_failed=None,
                cross_not_judged=(), sessions=phase.BENCH_SESSIONS):
    """An idle-budget.py --json report: every one of `sessions` ran, with these overs and session results."""
    exits = {session: 0 for session in sessions} if exits is None else exits
    entries = {session: {"exit": code, "not_judged": (not_judged or {}).get(session, []),
                         "readers_failed": (readers_failed or {}).get(session, []), "result": {
        "processes": (renderers or {}).get(session, [renderer(100)]),
        **({"ledger": ledger} if session == "tabs-static" and ledger is not None else {})}}
        for session, code in exits.items()}
    return {"over": [list(o) for o in over], "refused": list(refused), "session_exits": exits, "sessions": entries,
            "not_judged": list(cross_not_judged)}


def cef_window(early=0, reported=True):
    """One cef-idle-probe.py window's cef-idle.json; `reported`: the app's debug.cef pump had the counter."""
    return {"early_passes": early, "pump_per_s": {"requests": 0.4, **({"early_passes": 0.0} if reported else {})}}


QUIET_LEDGER = {"owners": [{"owner": "CEFMessagePump", "reason": "delayed", "per_s": 1.2},
                           {"owner": "GitHubFeedSource", "reason": "refresh", "per_s": 0.4},
                           {"owner": "FrameScheduler", "reason": "tick", "per_s": 0.05}]}
AUDIT_OK = "wakeup-audit swift: escaped 120, hit 0 (unescaped by rule: none)\n"
AUDIT_RED = AUDIT_OK + ("wakeup-audit: webviews/src/ui/wave.css:29: css-infinite (loop) hit\n"
                        "wakeup-audit: Packages/macOS/CmuxNext/CEFShim/src/shim_proxy.mm:96: spin-loop (loop) hit\n")
XBENCH_OK = "IDLE-BUDGET over=0 xbench=/tmp/etp/xbench/results.json\n"
XBENCH_RED = ("IDLE-BUDGET-OVER xbench cmux-chromium idle-wakeups-20/chrome 0.8 > 0.5\n"
              "IDLE-BUDGET-NOT-JUDGED xbench cmux-chromium power-idle-hidden: not judged: chrome not measured\n"
              "IDLE-BUDGET over=1 xbench=/tmp/etp/xbench/results.json\n")
NEXTEST_OK = """    Starting 10 tests across 2 binaries
        PASS [  31.002s] (1/10) acpmux::daemon_idle acpmux_daemon_idle_has_no_periodic_wakeups
        PASS [  32.120s] (2/10) cmux-tui::idle_wakeups cmux_next_daemon_idle_holder_mode
     Summary [  64.000s] 10 tests run: 10 passed, 0 skipped
cmux-ci: step 0123456789abcdef succeeded on aws-m4pro-3
"""
NEXTEST_RED = NEXTEST_OK.replace("        PASS [  32.120s] (2/10) cmux-tui::idle_wakeups",
                                 "        FAIL [  32.120s] (2/10) cmux-tui::idle_wakeups")
LIBTEST_OK = (REPO / "scripts" / "cmux-next" / "tests" / "fixtures" / "energy-test-phase-linux-d9.log").read_text()
LIBTEST_RED = LIBTEST_OK.replace("test cmux_next_daemon_idle_holder_mode ... ok",
                                 "test cmux_next_daemon_idle_holder_mode ... FAILED")
LIBTEST_BROKEN = """   Compiling acpmux v0.1.0 (/home/runner/cmux/cmux-tui/crates/acpmux)
error[E0425]: cannot find value `clock` in this scope
error: could not compile `acpmux` (test "daemon_idle") due to 1 previous error
"""
SUITES = ("Swift suite results (Packages/macOS/CmuxNext):\n"
          "suite                                            result                time\n"
          + "".join(f"{suite:<48} {'passed':<18} {12:6}s\n" for suite in phase.D10_SUITES))
D8_PASS = {"d8": {surface: {"verdict": "pass", "on": 8.1, "off": 8.0} for surface in phase.D8_SURFACES}}
VDISPLAY_120 = {"requested_hz": 120.0, "vdisplay": True, "refresh_ms": 8.33, "line": "ready 5 8.33 main=5"}
REAL_60 = {"requested_hz": 120.0, "vdisplay": False, "refresh_ms": None, "line": "error: CGVirtualDisplay unavailable",
           "probe": "main 1 16.67"}


def three(report):
    return [report] * phase.WINDOWS


class IdleBudgetJudgeTests(unittest.TestCase):
    def test_a_clean_run_passes_every_idle_check(self):
        checks = phase.judge_idle(idle_report(), BUDGET)
        self.assertEqual({check: result["status"] for check, result in checks.items()},
                         dict.fromkeys(("D2", "D3", "D4", "D5", "D6", "D7", "D11", "D13", "D14", "D15", "D16"), "pass"))

    def test_overs_go_to_their_d_rows(self):
        checks = phase.judge_idle(idle_report(over=[
            ("tabs-static", "app", "main_wakes_per_s", 0.8, 0.5),
            ("light-hidden", "cef-renderer", "role", "default", "best-effort"),
            ("light", "assertions", "held", 1, 0),
            ("signed-in", "session", "phone.keepAwake", "on", "off"),
            ("light", "app", "disk_bytes_per_s", 68.3, 0),
            ("energy-saver", "session", "page_raf_per_s", 60.0, 31)]), BUDGET)
        failed = {check for check, result in checks.items() if result["status"] == "fail"}
        self.assertEqual(failed, {"D4", "D7", "D11", "D15", "D16"})
        self.assertEqual(checks["D4"]["problems"], ["IDLE-BUDGET-OVER tabs-static app main_wakes_per_s 0.8 0.5"])
        self.assertEqual(len(checks["D11"]["problems"]), 2)

    def test_a_hidden_renderer_over_is_its_session_check_and_never_d17(self):
        over = ("minimized", "cef-renderer", "threads_max", 31, 24)
        self.assertEqual(phase.over_checks(over, set()), ["D3"])
        self.assertEqual(phase.judge_idle(idle_report(over=[over]), BUDGET)["D3"]["status"], "fail")
        self.assertEqual(phase.judge_d17(three(idle_report(over=[over])))["status"], "pass")

    def test_a_session_not_run_failed_or_refused_is_not_judged(self):
        exits = {session: 0 for session in phase.BENCH_SESSIONS}
        del exits["stress-static"]
        exits["agent-idle"] = 1
        checks = phase.judge_idle(idle_report(exits=exits, refused=["energy-saver"]), BUDGET)
        self.assertEqual(checks["D5"], phase.verdict(missing=["stress-static: not run"]))
        self.assertEqual(checks["D14"]["status"], "not judged")
        self.assertIn("energy-saver: refused (IDLE-BUDGET-REFUSED)", checks["D7"]["missing"])
        self.assertEqual(phase.judge_idle(None, BUDGET)["D2"]["missing"], ["idle-budget did not run (no report)"])

    def test_a_deferred_row_rides_along_without_changing_the_verdict(self):
        note = "agent-idle agent-harness hidden_wakeups_max: not judged: 0.4 measured; task 140 turns it on"
        checks = phase.judge_idle(idle_report(not_judged={"agent-idle": [note]}), BUDGET)
        self.assertEqual(checks["D14"]["status"], "pass")
        self.assertEqual(checks["D14"]["notes"], [note])

    def test_an_unknown_value_is_not_judged(self):
        note = "agent-idle agent-harness wakeups_per_s: not judged: unknown"
        checks = phase.judge_idle(idle_report(not_judged={"agent-idle": [note]}), BUDGET)
        self.assertEqual(checks["D14"], phase.verdict(missing=[note]))

    def test_a_failed_reader_makes_d15_not_judged(self):
        notes = {"light": ["light app network_bytes: not judged: unknown"]}
        checks = phase.judge_idle(idle_report(readers_failed={"light": ["network"]}, not_judged=notes), BUDGET)
        self.assertEqual(checks["D15"]["status"], "not judged")
        self.assertEqual(checks["D15"]["missing"], ["light app network_bytes: not judged: unknown",
                                                    "light: the network reader failed (not measured)"])
        self.assertEqual(checks["D2"]["status"], "pass")  # the D15 field is D15's alone
        alone = phase.judge_idle(idle_report(readers_failed={"tabs-static": ["log"]}), BUDGET)["D15"]
        self.assertEqual(alone["missing"], ["tabs-static: the log reader failed (not measured)"])

    def test_a_renderer_of_unknown_visibility_makes_d16_not_judged(self):
        note = "minimized cef-renderer role: not judged: visibility unknown pids=41,42"
        checks = phase.judge_idle(idle_report(not_judged={"minimized": [note]}), BUDGET)
        self.assertEqual(checks["D16"], phase.verdict(missing=[note]))
        self.assertEqual(checks["D3"]["status"], "pass")

    def test_a_failed_reference_session_makes_its_relative_rows_not_judged(self):
        exits = {session: 0 for session in phase.BENCH_SESSIONS}
        exits["light"] = 1
        cross = ["light-hidden app main_wakes_per_s/light: not judged: reference session light not measured",
                 "energy-saver app+daemon wakeups_per_s/tabs-static: not judged: app wakeups_per_s unknown",
                 "tabs-static cef-gpu wakeups_per_s/chrome:cef-gpu: not judged: unequal: no uBlock Origin"]
        checks = phase.judge_idle(idle_report(exits=exits, cross_not_judged=cross), BUDGET)
        self.assertEqual(checks["D3"]["status"], "not judged")
        self.assertEqual(checks["D3"]["missing"], ["light: failed (exit 1): None", cross[0]])
        self.assertEqual(checks["D7"]["missing"], [cross[1]])
        self.assertEqual(checks["D4"]["missing"], [cross[2]])
        only_light = {session: 0 for session in phase.BENCH_SESSIONS if session != "light"}
        self.assertIn("light: not run", phase.judge_idle(idle_report(exits=only_light), BUDGET)["D3"]["missing"])


class WindowTests(unittest.TestCase):
    def test_an_over_in_most_windows_is_over_at_the_median(self):
        over = lambda value: ("light", "app", "wakeups_per_s", value, 1.0)  # noqa: E731
        once = phase.merge_windows([idle_report(over=[over(1.6)]), idle_report(), idle_report()])
        self.assertEqual(once["over"], [])
        twice = phase.merge_windows([idle_report(over=[over(1.6)]), idle_report(over=[over(1.2)]), idle_report()])
        self.assertEqual(twice["over"], [["light", "app", "wakeups_per_s", 1.2, 1.0, "(over in 2 of 3 windows)"]])
        always = phase.merge_windows([idle_report(over=[over(v)]) for v in (1.6, 1.2, 3.0)])
        self.assertEqual(always["over"][0][3], 1.6)
        self.assertEqual(phase.judge_idle(twice, BUDGET)["D2"]["status"], "fail")

    def test_a_session_counts_only_when_it_ran_in_every_window(self):
        exits = {session: 0 for session in phase.BENCH_SESSIONS if session != "home"}
        merged = phase.merge_windows([idle_report(), idle_report(exits=exits), None])
        self.assertEqual(merged["session_exits"]["home"], None)
        self.assertEqual(phase.judge_idle(merged, BUDGET)["D6"]["missing"], ["home: not run (not run in window 2,3)"])
        self.assertIsNone(phase.merge_windows([None, None, None]))
        refused = phase.merge_windows([idle_report(), idle_report(refused=["energy-saver"]), idle_report()])
        self.assertIn("energy-saver: refused (IDLE-BUDGET-REFUSED)", phase.judge_idle(refused, BUDGET)["D7"]["missing"])

    def test_a_note_or_failed_reader_of_any_window_counts(self):
        merged = phase.merge_windows([idle_report(), idle_report(readers_failed={"light": ["log"]}), idle_report()])
        self.assertEqual(phase.judge_idle(merged, BUDGET)["D15"]["status"], "not judged")


class OtherJudgeTests(unittest.TestCase):
    def test_d1_from_the_audit(self):
        self.assertEqual(phase.judge_audit(0, AUDIT_OK)["status"], "pass")
        red = phase.judge_audit(1, AUDIT_RED)
        self.assertEqual(red["status"], "fail")
        self.assertEqual(red["problems"][:2], ["2 open hit(s)", "webviews/src/ui/wave.css:29: css-infinite (loop) hit"])
        self.assertEqual(phase.judge_audit(2, "Traceback")["status"], "not judged")

    def test_d12_ledger_and_early_passes_at_the_median(self):
        self.assertEqual(phase.judge_d12(three(idle_report(ledger=QUIET_LEDGER)), three(cef_window()), BUDGET)["status"],
                         "pass")
        busy = {"owners": [{"owner": "SidebarModel", "reason": "deadline", "per_s": 0.5},
                           {"owner": "BusyWatchdog", "reason": "window", "per_s": 0.02}]}
        result = phase.judge_d12(three(idle_report(ledger=busy)), three(cef_window(early=3)), BUDGET)
        self.assertEqual(result["problems"], ["ledger owner SidebarModel deadline at 0.5/s > 0.1",
                                              "BusyWatchdog.window at 0.02/s (want 0)",
                                              "cef-idle: a median of 3 early CEF pump passes in 3 windows (want 0)"])
        once = [idle_report(ledger=busy), idle_report(ledger=QUIET_LEDGER), idle_report(ledger=QUIET_LEDGER)]
        self.assertEqual(phase.judge_d12(once, [cef_window(early=2), cef_window(), cef_window()], BUDGET)["status"], "pass")

    def test_d12_is_not_judged_without_the_counter_or_a_ledger(self):
        missing = phase.judge_d12(three(idle_report()), [{"error": "launch"}, cef_window(), cef_window()], BUDGET)["missing"]
        self.assertEqual(missing, ["tabs-static has no debug.wakeups ledger in every window (a build without it)",
                                   "cef-idle window 1: no early-pass count from the app (launch)"])

    def test_d12_is_not_judged_when_the_app_did_not_report_early_passes(self):
        # cef-idle-probe counts a counter the app did not report as 0: only pump_per_s says it was read.
        result = phase.judge_d12(three(idle_report(ledger=QUIET_LEDGER)), three(cef_window(reported=False)), BUDGET)
        self.assertEqual(result["status"], "not judged")
        self.assertEqual(len(result["missing"]), 3)
        self.assertEqual(phase.judge_d12(three(idle_report(ledger=QUIET_LEDGER)), None, BUDGET)["missing"],
                         ["cef-idle: not run"])

    def test_d17_every_hidden_renderer_is_hidden_and_quiet(self):
        self.assertEqual(phase.judge_d17(three(idle_report()))["status"], "pass")
        bad = idle_report(renderers={"occluded": [renderer(7, hidden=False), renderer(8, wakeups=2.5)], "minimized": []})
        result = phase.judge_d17(three(bad))
        self.assertEqual(result["problems"], ["occluded: renderers not reported hidden: window 1 pid 7; window 2 pid 7; "
                                              "window 3 pid 7",
                                              "occluded: the busiest renderer at a median 2.5/s > 1.0"])
        self.assertEqual(result["missing"], ["minimized: no Chromium renderer measured (window 1,2,3)"])
        once = [bad, idle_report(), idle_report()]
        self.assertEqual(phase.judge_d17(once)["missing"], ["minimized: no Chromium renderer measured (window 1)"])
        self.assertEqual(phase.judge_d17(None)["missing"], ["idle-budget did not run (no report)"])

    def test_d8_from_bench_typing_verdicts_and_split_spring_not_measured(self):
        passed = phase.judge_d8(D8_PASS)
        self.assertEqual(passed, phase.verdict(missing=[phase.D8_SPLIT_SPRING]))
        d8 = {"d8": {**D8_PASS["d8"], "terminal": {"verdict": "fail", "check": "key->frame p95", "on": 9.1, "off": 8.0},
                     "chromium-page-scroll": {"verdict": "unscored", "why": ["refresh 60 Hz"]}}}
        result = phase.judge_d8(d8)
        self.assertEqual(result["status"], "fail")
        self.assertEqual(result["missing"], ["chromium-page-scroll: unscored: refresh 60 Hz", phase.D8_SPLIT_SPRING])
        self.assertEqual(phase.judge_d8(None)["status"], "not judged")

    def test_the_display_rate_decides_the_frame_rows(self):
        self.assertEqual(phase.display_hz(VDISPLAY_120), 120.0)
        self.assertEqual(phase.display_missing(VDISPLAY_120), [])
        self.assertEqual(phase.display_hz(REAL_60), 60.0)
        self.assertEqual(phase.display_missing(REAL_60),
                         ["display: measured at 60 Hz, not 120 Hz; rows defined at 120 Hz not judged"])
        self.assertIn("refresh not measured", phase.display_missing(None)[0])
        self.assertIn("refresh not measured", phase.display_missing({**REAL_60, "probe": "main 1 0.00"})[0])

    def test_d6_xbench_rows(self):
        self.assertEqual(phase.judge_xbench(0, XBENCH_OK)["status"], "pass")
        red = phase.judge_xbench(0, XBENCH_RED)
        self.assertEqual(red["problems"], ["IDLE-BUDGET-OVER xbench cmux-chromium idle-wakeups-20/chrome 0.8 > 0.5"])
        self.assertEqual(phase.judge_xbench(1, "Traceback: results.json")["status"], "not judged")

    def test_d9_needs_both_idle_binaries_to_pass(self):
        self.assertEqual(phase.judge_d9(0, NEXTEST_OK)["status"], "pass")
        self.assertEqual(phase.judge_d9(1, NEXTEST_RED)["problems"],
                         ["FAIL cmux-tui::idle_wakeups cmux_next_daemon_idle_holder_mode"])
        only_acpmux = "\n".join(line for line in NEXTEST_OK.splitlines() if "idle_wakeups" not in line)
        self.assertEqual(phase.judge_d9(0, only_acpmux)["missing"], ["no passing idle_wakeups test"])
        self.assertEqual(phase.judge_d9(75, "")["status"], "not judged")

    def test_d9_on_linux_needs_every_test_of_both_binaries_to_pass(self):
        self.assertEqual(phase.judge_d9_linux([0], None, LIBTEST_OK)["status"], "pass")
        results = phase.libtest_results(LIBTEST_OK)
        self.assertEqual(sorted(results), ["daemon_idle", "idle_wakeups"])
        self.assertIn(("cmux_next_daemon_idle_holder_mode", "ok"), results["idle_wakeups"])
        self.assertIn(("acpmux_daemon_idle_has_no_periodic_wakeups", "ok"), results["daemon_idle"])
        self.assertEqual(phase.judge_d9_linux([101], None, LIBTEST_RED)["problems"],
                         ["Linux: FAILED idle_wakeups cmux_next_daemon_idle_holder_mode"])
        self.assertEqual(phase.judge_d9_linux([0, 101], None, LIBTEST_BROKEN)["problems"],
                         ["Linux: error[E0425]: cannot find value `clock` in this scope",
                          "Linux: error: could not compile `acpmux` (test \"daemon_idle\") due to 1 previous error"])
        only_tui = LIBTEST_OK.split("Running tests/daemon_idle.rs")[0]
        self.assertEqual(phase.judge_d9_linux([0, 0], None, only_tui)["missing"], ["Linux: no passing daemon_idle test"])
        ignored = re.sub(r"(?m)^(test acpmux_\S+ \.\.\.) ok$", r"\1 ignored", LIBTEST_OK)
        self.assertEqual(phase.judge_d9_linux([0, 0], None, ignored)["missing"], ["Linux: no passing daemon_idle test"])

    def test_d9_on_linux_is_not_judged_when_the_box_never_ran_the_commit(self):
        self.assertEqual(phase.judge_d9_linux([], None, None)["status"], "not judged")
        pin = phase.judge_d9_linux([128], "command 1 exited 128: the 1 after it did not run", "fatal: not our ref")
        self.assertEqual(pin["missing"], ["Linux: the Testbox was not pinned to the commit (exit 128; is it pushed?): rerun"])
        gone = phase.judge_d9_linux([0, 1], None, "error: testbox tbx_energy not found")
        self.assertEqual(gone["status"], "fail")  # an error line with no test result: red, never a pass
        lost = phase.judge_d9_linux([0, 255], None, "Connection closed by remote host")
        self.assertEqual(lost["missing"], ["Linux: no test result (exit 255): see rust-idle-linux.log"])

    def test_d9_on_linux_names_the_tests_that_hung_past_the_bound(self):
        hung = LIBTEST_OK.split("test cmux_next_daemon_idle_twenty_terminals ... ok")[0] + (
            "test cmux_next_daemon_idle_holder_mode has been running for over 60 seconds\n"
            "test cmux_next_daemon_idle_idle_verdict_x ... ok\n")
        result = phase.judge_d9_linux([124], None, hung)
        self.assertEqual(result["problems"], [f"Linux: hung past {phase.D9_LINUX_TIMEOUT_S} s: idle_wakeups "
                                              "cmux_next_daemon_idle_holder_mode"])
        self.assertEqual(phase.judge_d9_linux([137], None, "")["problems"],
                         [f"Linux: a test binary hung past {phase.D9_LINUX_TIMEOUT_S} s (exit 137)"])
        self.assertIn(f"timeout -k 30 {phase.D9_LINUX_TIMEOUT_S} cargo test --locked -p acpmux --test daemon_idle;",
                      phase.D9_LINUX_SCRIPT)

    def test_d10_every_suite_passes(self):
        self.assertEqual(phase.judge_d10(0, SUITES)["status"], "pass")
        red = SUITES.replace(f"{'SuspendWatchTests':<48} {'passed':<18}", f"{'SuspendWatchTests':<48} {'failed (exit 1)':<18}")
        self.assertEqual(phase.judge_d10(1, red)["problems"], ["SuspendWatchTests: failed (exit 1)"])
        short = "\n".join(line for line in SUITES.splitlines() if not line.startswith("BatteryLevelTests"))
        self.assertEqual(phase.judge_d10(0, short)["missing"], ["BatteryLevelTests: no result"])
        self.assertEqual(phase.judge_d10(2, "")["status"], "not judged")


SIGNED_ALL = idle_report(sessions=phase.SIGNED_IN_SESSIONS)
DEBUG_NOTES = {"signed-in": ["signed-in: own rows not judged on a Debug build (not the code users run)",
                             "signed-in assertions held: 1 over 0 on a Debug build",
                             "signed-in app disk_bytes_per_s: 120.0 over 0 on a Debug build"]}


class SignedInTests(unittest.TestCase):
    def judge(self, signed_in):
        data = {"idle": three(idle_report(ledger=QUIET_LEDGER)), "signed_in": signed_in}
        return phase.judge_all(data, BUDGET)

    def test_signed_in_rows_of_a_debug_build_are_not_judged(self):
        # idle-budget's unjudged_on_debug empties a Debug signed-in session's overs into not_judged.
        checks = self.judge(three(idle_report(sessions=phase.SIGNED_IN_SESSIONS, not_judged=DEBUG_NOTES)))
        for check in ("D11", "D13", "D15"):
            self.assertEqual(checks[check]["status"], "not judged", check)
            self.assertIn(DEBUG_NOTES["signed-in"][0], checks[check]["missing"])
        self.assertIn(DEBUG_NOTES["signed-in"][1], checks["D11"]["missing"])
        self.assertIn(DEBUG_NOTES["signed-in"][2], checks["D15"]["missing"])

    def test_no_signed_in_run_leaves_d11_d13_and_d15_not_judged(self):
        checks = self.judge(None)
        for check in ("D11", "D13", "D15"):
            self.assertIn("signed-in sessions: not run (--debug-app)", checks[check]["missing"], check)
        self.assertEqual(self.judge(three(SIGNED_ALL))["D13"]["status"], "pass")


class FakeDisplay:
    def __init__(self, display=VDISPLAY_120, dies=False):
        self.display, self.dies, self.started, self.stopped = display, dies, [], 0

    def start(self, work, hz):
        self.started.append(hz)
        return dict(self.display), self

    def alive(self):
        return not self.dies

    def stop(self):
        self.stopped += 1


def write_run(out, idle=None, d7_problems=(), steps=None, display=VDISPLAY_120):
    """A run folder as main() leaves it, every output passing unless overridden."""
    out = Path(out)
    files = {"cef-idle/w{n}/cef-idle.json": cef_window(), "idle-budget/w{n}/idle-budget.json":
             idle or idle_report(ledger=QUIET_LEDGER)}
    for name, data in [(name.format(n=n), data) for name, data in files.items() for n in (1, 2, 3)] + [
            ("bench-typing/d8.json", D8_PASS), ("d7-auto.log", {"problems": list(d7_problems), "reports": {}})]:
        (out / name).parent.mkdir(parents=True, exist_ok=True)
        (out / name).write_text(json.dumps(data))
    for name, text in (("audit", AUDIT_OK), ("xbench", XBENCH_OK), ("rust-idle", NEXTEST_OK),
                       ("rust-idle-linux", LIBTEST_OK), ("swift-suites", SUITES)):
        (out / f"{name}.log").write_text(text)
    ran = {name: {"exits": [0], "load": 1.5} for name in ("audit", "xbench", "rust-idle", "swift-suites", "d7-auto")}
    ran["rust-idle-linux"] = {"exits": [0, 0], "load": None}
    ran.update({name: {"exits": [0, 0, 0], "load": 1.5, "display": display}
                for name in ("idle-budget", "cef-idle", "bench-typing")})
    (out / "steps.json").write_text(json.dumps({**ran, **(steps or {})}))


class RunTests(unittest.TestCase):
    def collect_only(self, out, *args):
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            code = phase.main(["--ref", SHA, "--out", out, "--collect-only", *args])
        return code, json.loads((Path(out) / "report.json").read_text()), stdout.getvalue()

    def run_main(self, out, *args, runner=None, display=None):
        stdout = io.StringIO()
        display = display or FakeDisplay()
        with contextlib.redirect_stdout(stdout):
            code = phase.main(["--ref", SHA, "--out", out, "--quiet-wait", "0", "--max-load", "1000", *args],
                              runner=runner, start_display=display.start)
        return code, json.loads((Path(out) / "report.json").read_text())

    def test_collect_only_judges_a_run_folder(self):
        with tempfile.TemporaryDirectory() as out:
            write_run(out)
            code, report, text = self.collect_only(out, "--checks", "D1,D2,D6,D7,D9,D10,D12,D17")
            self.assertEqual(code, 0, text)
            self.assertEqual({check: result["status"] for check, result in report["checks"].items()},
                             dict.fromkeys(["D1", "D2", "D6", "D7", "D9", "D10", "D12", "D17"], "pass"))
            self.assertIn("| D7 | energy saver: energy-saver session and auto at 15% on battery | pass |", text)
            self.assertIn("| p14-energy test phase (energy-test-phase.py, ", text)
            self.assertIn(f"| {SHA[:11]} | D9 Rust idle tests on fleet macOS and Linux | - | pass |", text)
            self.assertIn("Display of each measuring step: idle-budget 120 Hz virtual display, cef-idle 120 Hz", text)

    def test_a_failing_or_unmeasured_check_exits_one(self):
        with tempfile.TemporaryDirectory() as out:
            write_run(out, d7_problems=["simulated 15% on battery: inputs.simulated is not true"])
            code, report, _ = self.collect_only(out, "--checks", "D7,D13")
            self.assertEqual(code, 1)
            self.assertEqual(report["checks"]["D7"]["problems"],
                             ["D7 auto: simulated 15% on battery: inputs.simulated is not true"])
            self.assertEqual(report["checks"]["D13"]["status"], "not judged")  # no --debug-app: signed-in not run
            self.assertIn("signed-in sessions: not run (--debug-app)", report["checks"]["D13"]["missing"])

    def test_frame_rows_on_a_display_not_at_120_hz_are_not_judged(self):
        with tempfile.TemporaryDirectory() as out:
            write_run(out, display=REAL_60)
            _, report, _ = self.collect_only(out, "--checks", "D2,D7,D14")
            self.assertEqual(report["checks"]["D2"]["status"], "pass")
            for check in ("D7", "D14"):
                self.assertEqual(report["checks"][check]["missing"],
                                 ["idle-budget display: measured at 60 Hz, not 120 Hz; rows defined at 120 Hz not judged"])

    def test_collect_only_never_reads_a_skipped_steps_files(self):
        with tempfile.TemporaryDirectory() as out:
            write_run(out, steps={"idle-budget": {"skipped": "needs --app"}})
            _, report, _ = self.collect_only(out, "--checks", "D2")
            self.assertEqual(report["checks"]["D2"]["missing"], ["idle-budget did not run (no report)"])

    def test_a_skipped_step_deletes_an_earlier_runs_outputs(self):
        with tempfile.TemporaryDirectory() as out:
            write_run(out)  # an earlier run of this commit, every output passing
            code, report = self.run_main(out, "--checks", "D2,D12")  # no --app: idle-budget and cef-idle skip
            self.assertEqual(code, 1)
            self.assertEqual(report["checks"]["D2"]["status"], "not judged")
            self.assertEqual(report["checks"]["D12"]["status"], "not judged")
            self.assertFalse((Path(out) / "idle-budget").exists())
            self.assertEqual(report["steps"]["idle-budget"], {"skipped": "needs --app (a Release + CMUX_BENCH_HOOKS bundle)"})
            self.assertEqual(report["steps"]["rust-idle"]["exits"], [0])  # a step of another check keeps its record

    def test_a_refused_idle_budget_is_not_judged_from_an_earlier_report(self):
        with tempfile.TemporaryDirectory() as out:
            write_run(out)
            calls = []

            def refused(argv, cwd, stdout, stderr):  # IDLE-BUDGET-REFUSED, sys.exit(2), before any JSON
                calls.append(argv)
                stdout.write("IDLE-BUDGET-REFUSED build_config=debug: --gate needs a release build\n")
                return subprocess.CompletedProcess(argv, 2)

            display = FakeDisplay()
            code, report = self.run_main(out, "--app", APP, "--checks", "D2", runner=refused, display=display)
            self.assertEqual(code, 1)
            self.assertEqual(report["checks"]["D2"]["missing"], ["idle-budget did not run (no report)"])
            self.assertEqual(len(calls), 1)  # windows 2 and 3 do not run after a refused window
            self.assertIn("command 1 exited 2", report["steps"]["idle-budget"]["stopped"])
            self.assertEqual((display.started, display.stopped), ([120.0], 1))
            self.assertEqual(report["steps"]["idle-budget"]["display"], VDISPLAY_120)

    def test_a_display_lost_during_a_step_is_recorded(self):
        with tempfile.TemporaryDirectory() as out:
            ok = lambda argv, cwd, stdout, stderr: subprocess.CompletedProcess(argv, 0)  # noqa: E731
            _, report = self.run_main(out, "--app", APP, "--checks", "D8", runner=ok, display=FakeDisplay(dies=True))
            self.assertIn("refresh not measured (the virtual display helper exited during the step)",
                          " ".join(report["checks"]["D8"]["missing"]))

    def test_d9_needs_the_linux_run_and_names_each_platforms_problem(self):
        with tempfile.TemporaryDirectory() as out:
            write_run(out, steps={"rust-idle-linux": {"skipped": "needs --linux-testbox TBX"}})
            _, report, _ = self.collect_only(out, "--checks", "D9")
            self.assertEqual(report["checks"]["D9"]["missing"],
                             ["Linux: the Rust idle tests did not run (--linux-testbox TBX or --linux-local)"])
            write_run(out, steps={"rust-idle": {"exits": [75]}})
            _, report, _ = self.collect_only(out, "--checks", "D9")
            self.assertEqual(report["checks"]["D9"]["missing"], ["macOS: cmux-ci: queue timeout (exit 75): rerun"])

    def test_a_testbox_run_pins_the_box_then_runs_both_tests(self):
        with tempfile.TemporaryDirectory() as out:
            calls = []

            def testbox(argv, cwd, stdout, stderr):
                calls.append(argv)
                tests = "cargo test" in argv[-1]
                stdout.write(LIBTEST_RED if tests else f"{SHA}\n")
                return subprocess.CompletedProcess(argv, 101 if tests else 0)

            code, report = self.run_main(out, "--checks", "D9", "--linux-testbox", "tbx_energy", runner=testbox)
            self.assertEqual(code, 1)
            linux = [argv for argv in calls if argv[0] == "blacksmith"]
            self.assertEqual([argv[:5] for argv in linux], [["blacksmith", "testbox", "run", "--id", "tbx_energy"]] * 2)
            self.assertIn(f"git reset --hard {SHA}", linux[0][5])
            self.assertEqual(report["steps"]["rust-idle-linux"]["exits"], [0, 101])
            self.assertIn("Linux: FAILED idle_wakeups cmux_next_daemon_idle_holder_mode", report["checks"]["D9"]["problems"])

    def test_a_step_that_started_on_a_busy_host_says_so(self):
        with tempfile.TemporaryDirectory() as out:
            write_run(out, steps={"xbench": {"exits": [0], "load": 7.25}})
            _, report, _ = self.collect_only(out, "--checks", "D6")
            self.assertIn("xbench started at load 7.25 (not under 4)", report["checks"]["D6"]["notes"])

    def test_run_step_logs_each_command_and_stops_after_a_failed_one(self):
        with tempfile.TemporaryDirectory() as out:
            calls = []

            def runner(argv, cwd, stdout, stderr):
                calls.append(argv)
                stdout.write("IDLE-BUDGET over=0\n")
                return subprocess.CompletedProcess(argv, 3 if "run" in argv else 0)

            opts = argparse.Namespace(out=out, max_load=4, quiet_wait=0)
            step = phase.Step("xbench", ("D6",), (("python3", "a.py", "run"), ("python3", "a.py", "report"),
                                                  ("python3", "b.py", "--xbench")), quiet=False)
            evidence = phase.run_step(step, opts, runner)
            self.assertEqual(evidence["exits"], [3])
            self.assertEqual(len(calls), 1)
            self.assertIn("$ python3 a.py run\nIDLE-BUDGET over=0\n# command 1 exited 3: the 2 after it did not run\n",
                          (Path(out) / "xbench.log").read_text())
            gated = phase.Step("idle-budget", ("D2",), (("i", "1"), ("i", "2")), quiet=False, ok_exits=(0, 1))
            overs = lambda argv, cwd, stdout, stderr: subprocess.CompletedProcess(argv, 1)  # noqa: E731
            self.assertEqual(phase.run_step(gated, opts, overs)["exits"], [1, 1])  # overs are a result: go on

    def test_it_waits_for_a_quiet_host_and_gives_up_at_the_deadline(self):
        loads, now, slept = iter([9.0, 6.0, 3.5, 3.5]), [0.0], []

        def sleep(seconds):
            slept.append(seconds)
            now[0] += seconds

        self.assertEqual(phase.wait_quiet(4, 60, load=lambda: next(loads), sleep=sleep, clock=lambda: now[0]), 3.5)
        self.assertEqual(slept, [5, 5])
        self.assertEqual(phase.wait_quiet(4, 10, load=lambda: 8.0, sleep=sleep, clock=lambda: now[0]), 8.0)


if __name__ == "__main__":
    unittest.main()
