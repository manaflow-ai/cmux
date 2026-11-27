#!/usr/bin/env python3
"""The tab switch gate (scripts/cmux-next/tab_switch_gate.py): each budget fails, a clean report passes, and the
path scope picks tab, pane and chat-pane changes only. No app, display or CI job is needed:
    python3 -m unittest tests/test_cmux_next_tab_switch_gate.py
"""
import contextlib
import copy
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "cmux-next"))
import tab_switch_gate as gate  # noqa: E402


def switch(**over):
    base = {"to_content_ms": 6.0, "display_frame_ms": 8.33, "blank_frames": 0, "wrong_frames": 0, "shift_px": 0,
            "insert_ok": True, "anim_end_ok": None}
    base.update(over)
    return base


def clean_report():
    return {"schema": "tab-switch/v1", "build": "abc123", "display_hz": 120,
            "scenarios": [{"name": f"return-{load}", "load": load, "switches": [switch(), switch(), switch()],
                           "budget_fail": []} for load in ("idle", "cpu", "agents")],
            "pass": True}


def with_switch(**over):
    report = clean_report()
    report["scenarios"][1]["switches"][2] = switch(**over)
    return report


class BudgetTests(unittest.TestCase):
    def assert_fails(self, report, needle):
        verdict = gate.judge(report)
        self.assertFalse(verdict.ok)
        self.assertTrue(any(needle in failure for failure in verdict.failures), verdict.failures)
        # The harness said pass: true; the gate does not trust it.
        self.assertTrue(any("pass: true" in failure for failure in verdict.failures), verdict.failures)

    def test_clean_report_passes(self):
        verdict = gate.judge(clean_report())
        self.assertTrue(verdict.ok, verdict.failures)
        self.assertEqual([s.switches for s in verdict.scenarios], [3, 3, 3])

    def test_content_after_one_display_frame_fails(self):
        self.assert_fails(with_switch(to_content_ms=8.4), "after one display frame")

    def test_content_exactly_one_frame_passes(self):
        self.assertTrue(gate.judge(with_switch(to_content_ms=8.33)).ok)

    def test_frame_falls_back_to_display_hz(self):
        report = with_switch(to_content_ms=9.0, display_frame_ms=None)
        self.assert_fails(report, "after one display frame")

    def test_blank_frame_fails(self):
        self.assert_fails(with_switch(blank_frames=1), "1 blank frames")

    def test_wrong_frame_fails(self):
        self.assert_fails(with_switch(wrong_frames=2), "2 wrong frames")

    def test_shift_fails_either_direction(self):
        self.assert_fails(with_switch(shift_px=1), "1 px shift")
        self.assert_fails(with_switch(shift_px=-0.5), "0.5 px shift")

    def test_wrong_insert_fails(self):
        self.assert_fails(with_switch(insert_ok=False), "wrong place")

    def test_wrong_animation_end_fails(self):
        self.assert_fails(with_switch(anim_end_ok=False), "animations ended in the wrong place")

    def test_null_insert_and_anim_are_not_misses(self):
        self.assertTrue(gate.judge(with_switch(insert_ok=None, anim_end_ok=None)).ok)

    def test_harness_budget_fail_alone_fails(self):
        report = clean_report()
        report["scenarios"][0]["budget_fail"] = ["p95 to_content over budget"]
        report["pass"] = False
        verdict = gate.judge(report)
        self.assertFalse(verdict.ok)
        self.assertIn("harness failed it", verdict.failures[0])

    def test_harness_pass_false_alone_fails(self):
        report = clean_report()
        report["pass"] = False
        self.assertFalse(gate.judge(report).ok)

    def test_missing_load_fails(self):
        report = clean_report()
        del report["scenarios"][2]
        verdict = gate.judge(report)
        self.assertIn("no scenario ran under load agents", verdict.failures)

    def test_scenario_without_switches_fails(self):
        report = clean_report()
        report["scenarios"][0]["switches"] = []
        self.assertIn("no switch was measured", gate.judge(report).failures[0])

    def test_unreadable_reports_raise(self):
        for broken in ({"schema": "tab-switch/v0"}, {**clean_report(), "scenarios": []},
                       with_switch(blank_frames="0"), with_switch(to_content_ms=None),
                       with_switch(insert_ok="yes"), with_switch(blank_frames=1.5)):
            with self.subTest(broken=json.dumps(broken)[:80]):
                with self.assertRaises(gate.ReportError):
                    gate.judge(copy.deepcopy(broken))


class CliTests(unittest.TestCase):
    def run_cli(self, path, *extra):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = gate.main(["evaluate", path, *extra])
        return code, out.getvalue()

    def test_json_and_tar_reports(self):
        with tempfile.TemporaryDirectory() as directory:
            report = os.path.join(directory, "report.json")
            with open(report, "w") as handle:
                json.dump(clean_report(), handle)
            summary = os.path.join(directory, "summary.md")
            code, text = self.run_cli(report, "--summary", summary)
            self.assertEqual(code, 0)
            self.assertIn("| return-cpu | cpu | 3 |", text)
            with open(summary) as handle:
                self.assertIn("pass", handle.readline())

            sheet = os.path.join(directory, "contact-sheet.png")
            with open(sheet, "wb") as handle:
                handle.write(b"\x89PNG")
            with open(report, "w") as handle:
                json.dump(with_switch(blank_frames=3), handle)
            # The harness's report.tgz: .build/tab-switch/report.json beside .build/tab-switch/sheets/*.png.
            bundle = os.path.join(directory, "report.tgz")
            with tarfile.open(bundle, "w:gz") as tar:
                tar.add(report, arcname=".build/tab-switch/report.json")
                tar.add(sheet, arcname=".build/tab-switch/sheets/return-cpu.png")
            code, text = self.run_cli(bundle)
            self.assertEqual(code, 1)
            self.assertIn("3 blank frames", text)
            self.assertIn("Contact sheet: .build/tab-switch/sheets/return-cpu.png", text)

    def test_missing_or_bad_report_is_no_verdict(self):
        with tempfile.TemporaryDirectory() as directory:
            code, text = self.run_cli(os.path.join(directory, "absent.json"))
            self.assertEqual(code, 1)
            self.assertIn("no verdict", text)
            bad = os.path.join(directory, "report.json")
            with open(bad, "w") as handle:
                handle.write("{not json")
            code, text = self.run_cli(bad)
            self.assertEqual(code, 1)
            self.assertIn("no verdict", text)


class ScopeTests(unittest.TestCase):
    def test_in_scope(self):
        for path in ("Packages/macOS/CmuxNext/Sources/CmuxNextApp/AgentTabs.swift",
                     "Packages/macOS/CmuxNext/Sources/CmuxNextTabs/TabStripView+Sync.swift",
                     "Packages/macOS/CmuxNext/Sources/CmuxNextTabs/Groups/Editor/X.swift",
                     "Packages/macOS/CmuxNext/Sources/CmuxNextApp/PaneContentView+Parking.swift",
                     "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPaneHost.swift",
                     "webviews/src/agent-session/acpmux/App.tsx",
                     "webviews/src/agent-session/acpmux/conversation/Rows.tsx",
                     "webviews/src/agent-session/acpmux/composer/deep/Box.tsx",
                     "webviews/src/agent-session/acpmux/ComposerBox.tsx",
                     "cmux-tui/crates/cmux-tui-core/src/state/tabs.rs",
                     ".github/workflows/cmux-next-tab-switch.yml"):
            with self.subTest(path=path):
                self.assertEqual(gate.scoped_paths([path]), [path])

    def test_out_of_scope(self):
        for path in ("README.md",
                     "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Foo.swift",
                     "Packages/macOS/CmuxNext/Tests/CmuxNextTabsTests/TabStripTests.swift",
                     "Packages/macOS/CmuxNext/Sources/CmuxNextTabs/Playground/Demo.swift",
                     "webviews/src/agent-session/acpmux/conversation/Rows.test.ts",
                     "webviews/src/agent-session/acpmux/ComposerPickers.gallery.tsx",
                     "webviews/src/agent-session/acpmux/aside/Aside.tsx",
                     "webviews/src/pages/home/Home.tsx",
                     "cmux-tui/crates/cmux-tui-core/src/state/other.rs"):
            with self.subTest(path=path):
                self.assertEqual(gate.scoped_paths([path]), [])

    def test_scope_cli(self):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as handle:
            handle.write("README.md\nwebviews/src/agent-session/acpmux/App.tsx\n")
        try:
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                self.assertEqual(gate.main(["scope", "--files-from", handle.name]), 0)
            self.assertEqual(out.getvalue().strip(), "in_scope=true")
        finally:
            os.unlink(handle.name)


WORKFLOW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".github", "workflows",
                        "cmux-next-tab-switch.yml")


def frames_script():
    """The frames job's run script, as the runner gets it (the YAML block, dedented)."""
    with open(WORKFLOW) as handle:
        lines = handle.read().splitlines()
    start = lines.index("      - name: Measure tab switches on a display Mac")
    run = next(i for i in range(start, len(lines)) if lines[i] == "        run: |")
    body = []
    for line in lines[run + 1:]:
        if line.strip() and not line.startswith(" " * 10):
            break
        body.append(line[10:])
    return "\n".join(body) + "\n"


FAKE_CLIENT = """#!/usr/bin/env bash
echo "$*" >> "$FAKE_CLIENT_CALLS"
[[ "$1" == run ]] || exit 1
echo "cmux-ci: step 0123456789abcdef01234567 (exclusive, key k)"
exit 75
"""


class FramesAdmissionTests(unittest.TestCase):
    """The frames job submits its background step only when the display queue would start it within QUEUE_WAIT_S;
    otherwise it ends in seconds (2026-11-17: 220 of 354 jobs waited out a 3600 s queue timeout behind 60 queued
    exclusive steps, holding a gateway token, and none returned a report)."""

    def run_frames(self, status):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        client, calls = os.path.join(tmp, "cmux-ci"), os.path.join(tmp, "calls")
        with open(client, "w") as handle:
            handle.write(FAKE_CLIENT)
        os.chmod(client, 0o755)
        controller = os.path.join(tmp, "controller")
        os.makedirs(os.path.join(controller, "v1"))
        if status is not None:
            with open(os.path.join(controller, "v1", "status"), "w") as handle:
                handle.write(status if isinstance(status, str) else json.dumps(status))
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": tmp, "RUNNER_TEMP": tmp, "RUNNER_NAME": "t",
               "CMUX_CI_CLIENT": client, "FAKE_CLIENT_CALLS": calls, "FLEET_CONTROLLER": "file://" + controller,
               "HEAD_SHA": "a" * 40, "BASE_SHA": "b" * 40, "PR": "1", "GITHUB_RUN_ATTEMPT": "1", "ROUNDS": "3",
               "LOADS": "idle,cpu,agents", "REPORT_PATH": ".build/tab-switch/report.tgz", "QUEUE_WAIT_S": "1200"}
        proc = subprocess.run(["bash", "-e", "-c", frames_script()], env=env, capture_output=True, text=True,
                              timeout=60)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        with open(os.path.join(tmp, "tab-switch", "step-exit")) as handle:
            step_exit = handle.read().strip()
        submitted = []
        if os.path.exists(calls):
            with open(calls) as handle:
                submitted = [line for line in handle.read().splitlines() if line.startswith("run ")]
        return step_exit, submitted, proc.stdout, tmp

    @staticmethod
    def hosts(queued, running, online=4):
        rows = [{"name": f"m{i}", "online": True, "queued_eligible": queued, "other_running": 0} for i in range(online)]
        for row in rows[:running]:
            row["running"] = {"id": "x", "script": "scripts/measure/split-spring.sh"}
        rows.append({"name": "off", "online": False, "queued_eligible": 999})
        return {"measure_hosts": rows}

    def test_deep_queue_skips_without_submitting(self):
        step_exit, submitted, out, tmp = self.run_frames(self.hosts(queued=63, running=5, online=20))
        self.assertEqual(step_exit, "skipped")
        self.assertEqual(submitted, [])
        with open(os.path.join(tmp, "tab-switch", "skipped")) as handle:
            self.assertIn("63 exclusive steps queued", handle.read())
        self.assertIn("not measured", out)

    def test_short_queue_submits_with_the_queue_wait(self):
        step_exit, submitted, _, tmp = self.run_frames(self.hosts(queued=1, running=2))
        self.assertEqual(step_exit, "75")
        self.assertEqual(len(submitted), 1)
        # The client refuses --background with --measurement (run 45563103560 failed on it), so the step is idle
        # priority, and the job cancels it when it stops waiting (exit 75) so it gives its queue place back.
        self.assertNotIn("--background", submitted[0])
        self.assertIn("--measurement", submitted[0])
        self.assertIn("--priority idle", submitted[0])
        self.assertIn("--queue-timeout 1200", submitted[0])
        with open(os.path.join(tmp, "calls")) as handle:
            cancels = [line for line in handle.read().splitlines() if line.startswith("cancel ")]
        self.assertEqual(len(cancels), 1)
        self.assertTrue(cancels[0].startswith("cancel 0123456789abcdef01234567 "), cancels)

    def test_empty_queue_submits_with_nothing_running(self):
        _, submitted, _, _ = self.run_frames(self.hosts(queued=0, running=0))
        self.assertEqual(len(submitted), 1)

    def test_no_online_host_skips(self):
        step_exit, submitted, _, _ = self.run_frames({"measure_hosts": [{"name": "off", "online": False}]})
        self.assertEqual((step_exit, submitted), ("skipped", []))

    def test_unreadable_table_submits(self):
        for status in (None, "not json", "[]"):
            with self.subTest(status=status):
                _, submitted, _, _ = self.run_frames(status)
                self.assertEqual(len(submitted), 1)


def verdict_script():
    """The verdict job's Judge step script, as the runner gets it, with the expressions it holds filled in."""
    with open(WORKFLOW) as handle:
        lines = handle.read().splitlines()
    start = lines.index("      - name: Judge the budgets")
    run = next(i for i in range(start, len(lines)) if lines[i] == "        run: |")
    body = []
    for line in lines[run + 1:]:
        if line.strip() and not line.startswith(" " * 10):
            break
        body.append(line[10:])
    return re.sub(r"\$\{\{[^}]*\}\}", "1", "\n".join(body)) + "\n"


REPO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


class VerdictTests(unittest.TestCase):
    """The verdict fails only for the change it judges: a budget miss or a failed frames job (enforce), or the scope
    job's gate tests failing. A run with nothing measured (the scope job cancelled by a newer push, the report
    artifact missing, the display queue busy, the harness unable to measure) reads "not measured" and stays green in
    either mode (2026-11-19: 22% of verdicts were red, from a cancelled scope or "Artifact not found:
    tab-switch-45078-1", with GATE_MODE report)."""

    def run_verdict(self, gate_mode="report", scope="success", in_scope="true", frames="success", step_exit=None,
                    report=None, draft="false"):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        folder = os.path.join(tmp, "tab-switch")
        os.makedirs(folder)
        if step_exit is not None:
            with open(os.path.join(folder, "step-exit"), "w") as handle:
                handle.write(step_exit + "\n")
        if report is not None:
            with open(os.path.join(tmp, "report.json"), "w") as handle:
                json.dump(report, handle)
            with tarfile.open(os.path.join(folder, "report.tgz"), "w:gz") as tar:
                tar.add(os.path.join(tmp, "report.json"), arcname="report.json")
        summary = os.path.join(tmp, "summary.md")
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "RUNNER_TEMP": tmp, "GITHUB_STEP_SUMMARY": summary,
               "GATE_MODE": gate_mode, "LOADS": "idle,cpu,agents", "REPORT_PATH": ".build/tab-switch/report.tgz",
               "CANNOT_MEASURE_EXIT": "3", "SCOPE_RESULT": scope, "IN_SCOPE": in_scope, "FRAMES_RESULT": frames,
               "DRAFT": draft, "PR": "1", "GITHUB_RUN_ATTEMPT": "1", "ARTIFACTS_URL": "https://example.invalid/a"}
        proc = subprocess.run(["bash", "-e", "-c", verdict_script()], env=env, cwd=REPO, capture_output=True,
                              text=True, timeout=60)
        text = ""
        if os.path.exists(summary):
            with open(summary) as handle:
                text = handle.read()
        return proc.returncode, text, proc.stdout + proc.stderr

    def assert_not_measured(self, **kwargs):
        for mode in ("report", "enforce"):
            with self.subTest(mode=mode, **kwargs):
                code, text, out = self.run_verdict(gate_mode=mode, **kwargs)
                self.assertEqual(code, 0, out + text)
                self.assertIn("not measured", text)
                self.assertNotIn("::error", out)

    def test_cancelled_scope_is_not_measured(self):
        # A newer push cancels the run (concurrency cancel-in-progress); the verdict still runs (if: always()).
        self.assert_not_measured(scope="cancelled", in_scope="", frames="skipped")

    def test_skipped_scope_is_not_measured(self):
        self.assert_not_measured(scope="skipped", in_scope="", frames="skipped")

    def test_missing_report_artifact_is_not_measured(self):
        # frames succeeded but uploaded nothing: "Artifact not found: tab-switch-45078-1".
        self.assert_not_measured(frames="success")

    def test_step_that_returned_no_report_is_not_measured(self):
        self.assert_not_measured(frames="success", step_exit="75")

    def test_cancelled_or_skipped_frames_is_not_measured(self):
        self.assert_not_measured(frames="cancelled")
        self.assert_not_measured(frames="skipped")

    def test_busy_display_queue_is_not_measured(self):
        self.assert_not_measured(frames="success", step_exit="skipped")

    def test_harness_unable_to_measure_is_not_measured(self):
        self.assert_not_measured(frames="success", step_exit="3", report=with_switch(blank_frames=1))

    def test_out_of_scope_and_draft_stay_green(self):
        self.assertEqual(self.run_verdict(gate_mode="enforce", in_scope="false", frames="skipped")[0], 0)
        self.assertEqual(self.run_verdict(gate_mode="enforce", draft="true", frames="skipped")[0], 0)

    def test_failed_scope_job_fails_in_either_mode(self):
        # Its gate tests failed or the diff could not be read: that judges this change.
        for mode in ("report", "enforce"):
            with self.subTest(mode=mode):
                code, _, out = self.run_verdict(gate_mode=mode, scope="failure", in_scope="", frames="skipped")
                self.assertEqual(code, 1, out)

    def test_failed_frames_job_fails_when_enforced_and_warns_in_report(self):
        code, _, out = self.run_verdict(gate_mode="enforce", frames="failure")
        self.assertEqual(code, 1, out)
        code, _, out = self.run_verdict(gate_mode="report", frames="failure")
        self.assertEqual(code, 0, out)
        self.assertIn("::warning", out)

    def test_budget_miss_fails_when_enforced_and_warns_in_report(self):
        miss = with_switch(blank_frames=1)
        code, text, out = self.run_verdict(gate_mode="enforce", step_exit="1", report=miss)
        self.assertEqual(code, 1, out)
        self.assertIn(": fail", text)
        code, _, out = self.run_verdict(gate_mode="report", step_exit="1", report=miss)
        self.assertEqual(code, 0, out)
        self.assertIn("::warning", out)

    def test_clean_report_passes(self):
        code, text, out = self.run_verdict(gate_mode="enforce", step_exit="0", report=clean_report())
        self.assertEqual(code, 0, out)
        self.assertIn(": pass", text)


if __name__ == "__main__":
    unittest.main()
