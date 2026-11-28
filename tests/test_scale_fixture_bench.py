#!/usr/bin/env python3
"""scripts/cmux-next/scale-fixture-bench.py: its verdict and its config fixture, without a Mac.

Leo, 2026-11-27: "Scale fixtures. Seed one profile with about 1,000 workspaces, several Chiefs and a big cmux.json,
run the sidebar and switch flows, and fail if the main thread is blocked for more than ~250 ms."

  - pass / fail at the 250 ms budget, on either the watchdog's longest gap or its longest record;
  - blind (exit 2, never a pass) when the watchdog missed the probe stall or the rows did not ask for avatars;
  - skipped (exit 0, fail open) when the run measured nothing for a reason outside the change;
  - the config fixture is the RFD's 160 KB.
"""
from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/scale-fixture-bench.py"
sys.path.insert(0, str(SCRIPT.parent))
spec = importlib.util.spec_from_file_location("scale_fixture_bench", SCRIPT)
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


def report(**over):
    base = {
        "probe": {"seen_ms": 410},
        "fixture": {"owned": 1100},
        "workspaces_wanted": 1100,
        "flows": {"flush": {"max_gap_ms": 40, "max_ms": 0}, "scroll": {"max_gap_ms": 60, "max_ms": 0},
                  "switch": {"max_gap_ms": 120, "max_ms": 0}},
    }
    base.update(over)
    return base


class Verdict(unittest.TestCase):
    def test_pass_under_budget(self):
        self.assertEqual(bench.verdict(report())[:2], ("pass", 0))

    def test_fail_on_gap_over_budget(self):
        flows = report()["flows"]
        flows["flush"] = {"max_gap_ms": 2400, "max_ms": 0}
        name, code, reasons = bench.verdict(report(flows=flows))
        self.assertEqual((name, code), ("fail", 1))
        self.assertIn("flush", reasons[0])

    def test_fail_on_recorded_hang_over_budget(self):
        flows = report()["flows"]
        flows["switch"] = {"max_gap_ms": 0, "max_ms": 300}
        self.assertEqual(bench.verdict(report(flows=flows))[:2], ("fail", 1))

    def test_blind_when_probe_unseen(self):
        name, code, _ = bench.verdict(report(probe={"seen_ms": 0}))
        self.assertEqual((name, code), ("blind", 2))

    def test_blind_when_rows_ask_for_no_avatar(self):
        name, code, _ = bench.verdict(report(fixture={"owned": 10}))
        self.assertEqual((name, code), ("blind", 2))

    def test_blind_beats_a_quiet_pass(self):
        # A run that saw nothing must not read as green.
        self.assertNotEqual(bench.verdict(report(probe={}, fixture={}))[1], 0)

    def test_skipped_fails_open(self):
        self.assertEqual(bench.verdict({"skipped": "no GUI session"}), ("skipped", 0, ["no GUI session"]))

    def test_launch_crash_fails(self):
        # Run 6f5a0818 (da330185): the app crashed on a debug assertion at launch and the gate read it as a skip.
        name, code, reasons = bench.verdict({"crashed": "app crashed at launch: exit -5", "skipped": "x"})
        self.assertEqual((name, code), ("crashed", 1))
        self.assertIn("crashed", reasons[0])

    def test_run_reports_a_launch_crash_with_its_fatal_line(self):
        import tempfile
        import types

        class FakeLaunchError(Exception):
            def __init__(self, reason, report):
                super().__init__(reason)
                self.reason, self.report = reason, report

        class FakeApp:
            def __init__(self, *args, **kwargs):
                pass

            def launch(self, timeout):
                raise FakeLaunchError("crashed", {
                    "detail": "the app ended (exit -5) before its socket answered",
                    "log_tail": "CmuxNextHostedChief/HostedChiefRules.swift:15: Fatal error: home rules op chiefs_tab: unknownOp\n"})

        fake = types.ModuleType("bench_launch")
        fake.BenchApp, fake.LaunchError, fake.gui_session = FakeApp, FakeLaunchError, lambda: {"ok": True}
        saved = sys.modules.get("bench_launch")
        sys.modules["bench_launch"] = fake
        try:
            with tempfile.TemporaryDirectory() as tmp:
                code = bench.main(["--app", "x.app", "--out", tmp, "--json", f"{tmp}/r.json"])
                written = json.loads(Path(f"{tmp}/r.json").read_text())
        finally:
            if saved is None:
                sys.modules.pop("bench_launch", None)
            else:
                sys.modules["bench_launch"] = saved
        self.assertEqual((code, written["verdict"]), (1, "crashed"))
        self.assertIn("chiefs_tab: unknownOp", written["reasons"][0])

    def test_workflow_fails_a_crash(self):
        text = (ROOT / ".github/workflows/cmux-next-scale-fixture.yml").read_text()
        self.assertIn('if v == "crashed":', text)


class Config(unittest.TestCase):
    def test_big_config_is_160_kb(self):
        size = len(json.dumps(bench.big_config()))
        self.assertGreaterEqual(size, 160_000)
        self.assertLess(size, 200_000)

    def test_big_config_names_a_chief_mascot(self):
        self.assertEqual(bench.big_config(1_000)["home"]["chiefPetMascot"], "fox")


class GateStep(unittest.TestCase):
    """The workflow's measure step, run as Actions runs it (bash -e), with a stub fleet client."""

    def run_step(self, client_body, **extra):
        import os, re, subprocess, tempfile
        wf = (ROOT / ".github/workflows/cmux-next-scale-fixture.yml").read_text()
        m = re.search(r"        run: \|\n((?:          .*\n|\n)+?)(?=      - |\Z)", wf[wf.index("Scale fixture on a fleet GUI Mac"):])
        script = "\n".join(l[10:] for l in m.group(1).splitlines())
        with tempfile.TemporaryDirectory() as d:
            client = Path(d, "cmux-ci")
            client.write_text("#!/usr/bin/env bash\n" + client_body)
            client.chmod(0o755)
            summary = Path(d, "summary")
            env = dict(os.environ, CMUX_CI_CLIENT=str(client), RUNNER_TEMP=d, RUNNER_NAME="t",
                       GITHUB_STEP_SUMMARY=str(summary), GITHUB_RUN_ID="1", GITHUB_RUN_ATTEMPT="1",
                       SHA="a" * 40, WORKSPACES="1100", GITHUB_REPOSITORY="manaflow-ai/cmux",
                       DETACH="1", REPORT_CHECK="cmux-next scale fixture (fleet)", CONTROLLER="",
                       LOCAL_CLIENT_ONLY="0", ARGS_FILE=str(Path(d, "args")))
            env.update(extra)
            r = subprocess.run(["bash", "-e", "-c", script], env=env, capture_output=True, text=True)
            return r, summary.read_text() if summary.exists() else ""

    def test_queue_timeout_passes_open(self):
        # run 46101042567: no GUI Mac took the step in 30 min; the client exits 75.
        r, summary = self.run_step(
            'if [ "$1" = run ]; then echo "cmux-ci: step 743efa36842a32ca8dfdeaca (exclusive)"; exit 75; fi\nexit 0\n')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("still queued after 30 min", summary)

    DETACHING = ('if [ "$1" = run ] && [ "$2" = --help ]; then echo "usage: run ... --report-check NAME --detach"; exit 0; fi\n'
                 'if [ "$1" = run ]; then echo "$@" > "$ARGS_FILE"; '
                 'echo "cmux-ci: step 743efa36842a32ca8dfdeaca (exclusive) detached; check run posts later"; exit 0; fi\n'
                 'echo "unexpected $*" >&2; exit 3\n')

    def test_detached_submits_and_ends(self):
        # 11-28 15-19Z: every waiting run held its gateway runner 30-31 min, most passing open with no result.
        r, summary = self.run_step(self.DETACHING)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("detached", summary)
        self.assertNotIn("unexpected", r.stderr)  # no artifact fetch, no cancel: nothing waits

    def test_detached_names_the_check(self):
        import os, tempfile
        with tempfile.TemporaryDirectory() as d:
            args = Path(d, "args")
            r, _ = self.run_step(self.DETACHING, ARGS_FILE=str(args))
            sent = args.read_text()
        self.assertIn("--report-check cmux-next scale fixture (fleet) --detach", sent)
        self.assertIn("--repo manaflow-ai/cmux", sent)

    def test_detach_off_waits_as_before(self):
        import tempfile
        waiting = ('if [ "$1" = run ] && [ "$2" = --help ]; then echo "usage: run ... --detach"; exit 0; fi\n'
                   'if [ "$1" = run ]; then echo "$@" > "$ARGS_FILE"; echo "cmux-ci: step 743efa36842a32ca8dfdeaca"; exit 75; fi\n'
                   'exit 0\n')
        with tempfile.TemporaryDirectory() as d:
            args = Path(d, "args")
            r, summary = self.run_step(waiting, DETACH="0", ARGS_FILE=str(args))
            sent = args.read_text()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("--detach", sent)
        self.assertIn("still queued after 30 min", summary)


if __name__ == "__main__":
    unittest.main()
