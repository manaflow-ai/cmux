"""Measured base flakes may waive their exact quarantined diagnostic, never an unreadable or new failure."""
import copy
import importlib.util
import json
import os
import tempfile
import subprocess
import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


reds = module("tap_reds", "scripts/ci/test_reds.py")
web_results = module("tap_web_results", "scripts/ci/webviews_test_results.py")
base = module("tap_base", "tests/test_base_red_excuse.py")
excuse = base.excuse
NOW = datetime.now(timezone.utc)
ISSUE = "https://github.com/manaflow-ai/cmux/issues/123"
SUMMARY = "✔ Test run with 40 tests in 3 suites passed after 1.0 seconds."
FAIL = "✘ Test sometimes() recorded an issue at A.swift:1:2: Expectation failed: ready == true"
HEAD = FAIL + "\n" + SUMMARY
JOB = "cmux-next swift test"
WORKFLOW = "cmux-next"


def state(log=HEAD, job=JOB, workflow=WORKFLOW):
    failed = next(row for row in reds.observations(log) if row["outcome"] == "fail")
    return {"schema": "tap-tests/v1", "generated_at": NOW.isoformat(), "tests": [
        {"workflow": workflow, "job": job, "test": failed["test"], "observations": 10,
         "last_observed_at": NOW.isoformat(),
         "passes": 6, "failures": 4, "flips": 4, "flip_rate": 4 / 9,
         "failure_signatures": [failed["signature"]],
         "quarantine": {"issue": ISSUE, "until": (NOW + timedelta(days=1)).isoformat(),
                        "signatures": [failed["signature"]]}}]}


class PositiveObservations(unittest.TestCase):
    def test_records_explicit_results_across_readers_never_skips_or_absences(self):
        text = "\n".join([HEAD, "✔ Test works() passed after 0.01 seconds.",
                          "Test Case '-[Suite testExample]' passed (0.01 seconds).",
                          "test crate::works ... ok", "test crate::ignored ... ignored",
                          "test_works (test_module.Suite.test_works) ... ok", "Ran 1 test in 0.1s",
                          "test_file.py::test_works PASSED [100%]", "test_file.py::test_skip SKIPPED [100%]"])
        got = {row["test"]: row for row in reds.observations(text)}
        self.assertEqual(set(got), {"sometimes()", "works()", "Suite testExample", "crate::works",
                                   "test_works (test_module.Suite.test_works)", "test_file.py::test_works"})
        self.assertEqual(got["sometimes()"], {"test": "sometimes()", "outcome": "fail", "signature": FAIL})
        self.assertTrue(all(row["outcome"] == "pass" for name, row in got.items() if name != "sometimes()"))

    def test_whole_bun_runs_and_retries_use_classifier_names_and_diagnostics(self):
        log = "\n".join(["bun test v1.3.0", "test/a.test.ts:", "error: Expected ready",
                         "(fail) first [1.2ms]", "(pass) other [0.2ms]", "1 pass", "1 fail",
                         "--- retry, alone ---", "bun test v1.3.0", "test/a.test.ts:",
                         "(pass) first [0.2ms]", "(pass) other [0.1ms]", "2 pass", "0 fail"])
        got = reds.observations(log)
        self.assertEqual(got, [{"test": "test/a.test.ts > first", "outcome": "pass", "signature": ""},
                               {"test": "test/a.test.ts > other", "outcome": "pass", "signature": ""}])

    def test_crash_truncation_runner_loss_and_echoed_scripts_supply_no_samples(self):
        for tail in ["error: exited with unexpected signal code 6", "##[error]The operation was canceled",
                     "The runner has received a shutdown signal", "◇ Test unfinished() started."]:
            with self.subTest(tail=tail):
                self.assertEqual(reds.observations(HEAD + "\n" + tail), [])
        self.assertEqual(reds.observations("\n".join(["##[group]Run echo results", FAIL,
                          "✔ Test works() passed after 1s.", "shell: /bin/bash -e {0}", "##[endgroup]"])), [])


class WebPositiveExport(unittest.TestCase):
    def test_real_runner_exports_green_names_by_default_with_a_kill_switch(self):
        with tempfile.TemporaryDirectory() as folder:
            repo = Path(folder)
            (repo / "webviews/test").mkdir(parents=True)
            (repo / "webviews/test/a.test.ts").write_text("// fixture\n")
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
            tools = repo / "bin"
            tools.mkdir()
            bun = tools / "bun"
            bun.write_text("#!/bin/sh\nprintf '%s\\n' 'bun test v1.3.0' 'test/a.test.ts:' '(pass) first [1ms]' '1 pass' '0 fail' 'Ran 1 test across 1 file.'\n")
            bun.chmod(0o755)
            env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                       CMUX_WEB_TEST_JOBS="1", CMUX_WEB_TEST_RETRIES="0", GITHUB_ACTIONS="true")
            env.pop("CMUX_BROWSER_TESTS", None)
            env.pop("TAP_CI_ENABLED", None)
            for enabled, expected in [("0", 0), ("1", 1)]:
                if enabled == "0":
                    env["TAP_CI_ENABLED"] = "0"
                else:
                    env.pop("TAP_CI_ENABLED", None)
                done = subprocess.run(["bash", str(ROOT / "scripts/ci/run-webviews-tests.sh")],
                                       cwd=repo / "webviews", env=env, capture_output=True, text=True, timeout=30)
                self.assertEqual(done.returncode, 0, done.stderr + done.stdout)
                self.assertEqual(len(reds.observations(done.stdout)), expected)

    def export(self, text, outcome="PASS"):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "test.log"
            path.write_text(text)
            summary = Path(folder) / "summary"
            summary.write_text(f"{outcome} test/a.test.ts {path}\n")
            done = subprocess.run([sys.executable, str(ROOT / "scripts/ci/webviews_test_results.py"),
                                   "--tap-markers", str(summary)], capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, done.stderr)
            return done.stdout

    def test_green_names_are_emitted_and_round_trip_without_raw_green_output(self):
        raw = "bun test v1.3.0\ntest/a.test.ts:\nsecret diagnostic noise\n(pass) first [1ms]\n1 pass\n0 fail\nRan 1 test across 1 file."
        exported = self.export(raw)
        self.assertNotIn("secret diagnostic noise", exported)
        self.assertEqual(reds.observations(exported), [{"test": "test/a.test.ts > first", "outcome": "pass", "signature": ""}])

    def test_final_retry_only_has_canonical_failure_signatures(self):
        first = "bun test v1.3.0\ntest/a.test.ts:\nerror: old\n(fail) old [1ms]\n0 pass\n1 fail\nRan 1 test across 1 file."
        final = "bun test v1.3.0\ntest/a.test.ts:\nerror: new\n(fail) new [1ms]\n(pass) worked [1ms]\n1 pass\n1 fail\nRan 2 tests across 1 file."
        exported = self.export(first + "\n--- retry, alone ---\n" + final, "FAIL")
        self.assertEqual(reds.observations(exported), reds.observations(final))
        self.assertEqual(len(reds.observations(exported)), 2)

    def test_skips_crashes_timeout_partial_and_oversized_diagnostics(self):
        whole = "bun test v1.3.0\ntest/a.test.ts:\n(pass) worked [1ms]\n1 pass\n0 fail\nRan 1 test across 1 file."
        for raw, outcome in [(whole, "TIMEOUT"), (whole + "\npanic(main thread): crash", "FAIL"),
                             (whole + "\n##[error]Process completed with exit code 134.", "FAIL"),
                             (whole + "\nThe runner has received a shutdown signal", "FAIL"),
                             (whole + "\nbun test v1.3.0\n(pass) partial", "PASS"),
                             ("X" * (web_results.MAX_LINE_BYTES + 1) + "\n" + whole, "PASS")]:
            with self.subTest(outcome=outcome, length=len(raw)):
                self.assertEqual(reds.observations(self.export(raw, outcome)), [])

    def test_incomplete_export_and_conflicting_duplicate_ids_supply_no_evidence(self):
        row = {"schema": "tap-test/v1", "file": "test/a.test.ts", "test": "test/a.test.ts > first",
               "outcome": "pass", "signature": ""}
        header = "::group::TAP final named results\n"
        line = "tap-test/v1 " + json.dumps(row) + "\n"
        self.assertEqual(reds.observations(header + line), [])
        other = dict(row, outcome="fail", signature="different")
        self.assertEqual(reds.observations(header + line + "tap-test/v1 " + json.dumps(other) + "\n::endgroup::"), [])

    def test_structured_diagnostics_do_not_become_raw_crashes_or_extra_error_lines(self):
        row = {"schema": "tap-test/v1", "file": "test/a.test.ts", "test": "test/a.test.ts > first",
               "outcome": "fail", "signature": "error: expected EXC_BAD_ACCESS; ✘ Test ghost() failed"}
        marker = "tap-test/v1 " + json.dumps(row)
        self.assertEqual(reds.read(marker).crashes, [])
        self.assertEqual(reds.read(marker).failed, set())
        self.assertEqual(excuse.signature(base.failed_job(1, 10, base.HEAD), marker)[2], set())


class QuarantineEvidence(unittest.TestCase):
    def test_same_harness_before_after_replay(self):
        self.assertTrue(reds.classify(HEAD, SUMMARY, JOB).own)
        result = reds.classify(HEAD, SUMMARY, JOB, flake_state=state(), workflow=WORKFLOW)
        self.assertFalse(result.own, result.reasons)
        self.assertIn(ISSUE, result.shared[0])

    def test_changed_failure_never_matches(self):
        result = reds.classify(HEAD.replace("ready == true", "saved == true"), SUMMARY, JOB,
                               flake_state=state(), workflow=WORKFLOW)
        self.assertTrue(result.own)

    def test_historical_signature_cannot_authorize_a_new_diagnostic(self):
        old = FAIL
        new = FAIL.replace("ready == true", "saved == true")
        snapshot = state()
        row = snapshot["tests"][0]
        row["failure_signatures"] = [old, new]
        row["quarantine"]["signatures"] = [old]
        self.assertTrue(reds.classify(new + "\n" + SUMMARY, SUMMARY, JOB,
                                      flake_state=snapshot, workflow=WORKFLOW).own)
        row["quarantine"]["signatures"] = [old, new]
        self.assertFalse(reds.classify(new + "\n" + SUMMARY, SUMMARY, JOB,
                                       flake_state=snapshot, workflow=WORKFLOW).own)

    def test_insufficient_stale_expired_malformed_or_ambiguous_evidence_is_ignored(self):
        changes = [lambda s: s.update(generated_at=(NOW - timedelta(days=3)).isoformat()),
                   lambda s: s.update(generated_at=(NOW + timedelta(days=1)).isoformat()),
                   lambda s: s.update(schema="other"), lambda s: s.update(tests={}),
                   lambda s: s["tests"].append(copy.deepcopy(s["tests"][0]))]
        row_changes = [{"observations": 4, "passes": 2, "failures": 2}, {"flips": 1},
                       {"flips": 2, "observations": 20, "passes": 16}, {"observations": True},
                       {"passes": 0}, {"failures": 0}, {"failure_signatures": FAIL},
                       {"failures": 1, "passes": 9}, {"last_observed_at": None},
                       {"last_observed_at": (NOW - timedelta(days=3)).isoformat()},
                       {"failure_signatures": [""]}, {"quarantine": None},
                       {"quarantine": {"issue": ISSUE, "until": (NOW + timedelta(days=1)).isoformat()}},
                       {"quarantine": {"issue": ISSUE, "until": (NOW + timedelta(days=1)).isoformat(),
                                        "signatures": []}},
                       {"quarantine": {"issue": ISSUE, "until": (NOW + timedelta(days=1)).isoformat(),
                                        "signatures": [""]}},
                       {"quarantine": {"issue": ISSUE, "until": (NOW + timedelta(days=1)).isoformat(),
                                        "signatures": [1]}},
                       {"quarantine": {"issue": ISSUE, "until": (NOW + timedelta(days=1)).isoformat(),
                                        "signatures": ["x"] * (reds.TAP_MAX_QUARANTINE_SIGNATURES + 1)}},
                       {"quarantine": {"issue": ISSUE, "until": (NOW + timedelta(days=1)).isoformat(),
                                        "signatures": ["x" * (reds.TAP_MAX_SIGNATURE_BYTES + 1)]}},
                       {"workflow": "another"}, {"job": "another"},
                       {"quarantine": {"issue": ISSUE, "until": (NOW - timedelta(seconds=1)).isoformat()}},
                       {"quarantine": {"issue": ISSUE, "until": (NOW + timedelta(days=8)).isoformat()}},
                       {"quarantine": {"issue": "https://example.com/123", "until": NOW.isoformat()}}]
        changes += [lambda s, change=change: s["tests"][0].update(change) for change in row_changes]
        for change in changes:
            snapshot = state()
            change(snapshot)
            with self.subTest(snapshot=snapshot):
                self.assertTrue(reds.classify(HEAD, SUMMARY, JOB, flake_state=snapshot, workflow=WORKFLOW).own)

    def test_crash_cut_short_or_missing_diagnostic_never_gets_quarantine(self):
        for head in [HEAD + "\nerror: exited with unexpected signal code 6",
                     HEAD + "\n##[error]The operation was canceled", "test crate::red ... FAILED"]:
            self.assertTrue(reds.classify(head, SUMMARY, JOB, flake_state=state(), workflow=WORKFLOW).own)

    def test_matrix_shards_share_history_only_within_the_same_workflow(self):
        snapshot = state(job="react-apps-check")
        self.assertTrue(reds.flaky_failures(HEAD, "web / react-apps-check (3)", WORKFLOW, snapshot))
        self.assertTrue(reds.flaky_failures(HEAD, "web / react-apps-check (3/6)", WORKFLOW, snapshot))
        self.assertFalse(reds.flaky_failures(HEAD, "react-apps-check (3)", "other", snapshot))

    def test_exact_base_evidence_still_works_without_usable_state(self):
        for snapshot in [None, {}, {"schema": "wrong"}]:
            self.assertFalse(reds.classify(HEAD, HEAD, JOB, flake_state=snapshot, workflow=WORKFLOW).own)

    def test_window_can_combine_a_quarantine_with_an_exact_base_failure(self):
        other = FAIL.replace("sometimes()", "other()")
        result = reds.classify_any(HEAD + "\n" + other,
                                   [("run 2", other + "\n" + SUMMARY), ("run 1", SUMMARY)], JOB,
                                   flake_state=state(), workflow=WORKFLOW)
        self.assertFalse(result.own, result.reasons)
        self.assertEqual(len(result.shared), 2)

    def test_loader_path_kill_switch_and_unavailable_public_mirror(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "state.json"
            path.write_text(json.dumps(state()))
            self.assertEqual(reds.load_flake_state(path)["schema"], "tap-tests/v1")
            path.write_text("[]")
            self.assertEqual(reds.load_flake_state(path), {})
        with patch.dict("os.environ", {"TAP_TESTS_STATE": "off"}), patch.object(reds, "urlopen") as fetch:
            self.assertEqual(reds.load_flake_state(fetch=True), {})
            fetch.assert_not_called()
        with patch.dict("os.environ", {}, clear=True), patch.object(reds, "urlopen", side_effect=OSError("offline")):
            self.assertEqual(reds.load_flake_state(fetch=True), {})


class RequiredWebVerdict(unittest.TestCase):
    def test_real_gate_waives_only_the_matching_signature_from_a_relocated_final_attempt(self):
        raw = "bun test v1.3.0\ntest/a.test.ts:\nerror: Expected ready\n(fail) first [1ms]\n0 pass\n1 fail\nRan 1 test across 1 file."
        snapshot = state(raw, job="react-apps-check", workflow="cmux-next web")
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            (directory / "summary").write_text("FAIL test/a.test.ts /old/runner/test_a.test.ts.log\n")
            (directory / "state.json").write_text(json.dumps(snapshot))
            (directory / "head.json").write_text(json.dumps({"test/a.test.ts > first": False}))
            (directory / "base.json").write_text(json.dumps({"test/a.test.ts": True}))
            for text, expected in [(raw, 0), (raw.replace("Expected ready", "new diagnostic"), 1),
                                   (raw + "\npanic(main thread): crash", 1),
                                   (raw + "\nbun test v1.3.0\n(fail) partial", 1)]:
                (directory / "test_a.test.ts.log").write_text(text)
                emitted = subprocess.run([sys.executable, str(ROOT / "scripts/ci/test_reds.py"), "tap-flaky",
                                          "--workflow", "cmux-next web", "--job", "react-apps-check",
                                          "--log-dir", str(directory), "--flake-state", str(directory / "state.json")],
                                         capture_output=True, text=True)
                self.assertEqual(emitted.returncode, 0, emitted.stderr)
                (directory / "flaky").write_text(emitted.stdout)
                checked = subprocess.run([sys.executable, str(ROOT / "scripts/ci/guards_new_reds.py"),
                                          "--label", "Webview test", "--flaky", str(directory / "flaky"),
                                          str(directory / "head.json"), str(directory / "base.json")],
                                         capture_output=True, text=True)
                with self.subTest(text=text):
                    self.assertEqual(checked.returncode, expected, checked.stdout + checked.stderr)


class BaseRedConsumer(unittest.TestCase):
    def fake(self):
        github = base.FakeGitHub()
        github.logs[1] = base.log(JOB, base.TEST_STEP, *HEAD.splitlines())
        github.logs[2] = SUMMARY
        github.jobs[2]["conclusion"] = "success"
        original = github.json
        def read(route, **kwargs):
            result = original(route, **kwargs)
            if route.endswith("/actions/runs/10"):
                result["name"] = WORKFLOW
            return result
        github.json = read
        return github

    def test_quarantined_failure_can_bridge_a_green_base_run(self):
        audit = excuse.judge(base.REPO, "feat-cmux-next", base.HEAD, [10], self.fake(), flake_state=state())
        self.assertIn("quarantined base flakes", audit[0])
        self.assertIn(ISSUE, audit[0])

    def test_unrelated_failed_steps_and_error_lines_are_not_waived(self):
        for extra in ["step", "error"]:
            github = self.fake()
            if extra == "step":
                github.jobs[1]["steps"].append({"name": "Compile", "status": "completed", "conclusion": "failure"})
            else:
                github.logs[1] += "\n##[error]unrelated compile error: missing symbol"
            with self.subTest(extra=extra), self.assertRaises(excuse.Refused):
                excuse.judge(base.REPO, "feat-cmux-next", base.HEAD, [10], github, flake_state=state())

    def test_bun_diagnostic_is_covered_but_another_error_is_not(self):
        text = "\n".join(["bun test v1.3.0", "test/a.test.ts:", "error: Expected ready",
                           "(fail) first [1ms]", "0 pass", "1 fail"])
        snapshot = state(text)
        github = self.fake()
        github.logs[1] = base.log(JOB, base.TEST_STEP, *text.splitlines())
        self.assertIn(ISSUE, excuse.judge(base.REPO, "feat-cmux-next", base.HEAD, [10], github,
                                        flake_state=snapshot)[0])
        github.logs[1] += "\nerror: Failed to compile another package"
        with self.assertRaises(excuse.Refused):
            excuse.judge(base.REPO, "feat-cmux-next", base.HEAD, [10], github, flake_state=snapshot)

    def test_every_failed_step_needs_its_own_named_quarantine_evidence(self):
        for other in ["second step", "passed step", "unlabelled"]:
            github = self.fake()
            if other == "second step":
                github.jobs[1]["steps"].append({"name": "Other tests", "conclusion": "failure"})
                github.logs[1] += "\n" + base.log(JOB, "Other tests", "##[error]Process completed with exit code 1.")
            elif other == "passed step":
                github.logs[1] = base.log(JOB, "Passed tests", *HEAD.splitlines())
                github.logs[1] += "\n" + base.log(JOB, base.TEST_STEP, "##[error]Process completed with exit code 1.")
            else:
                github.logs[1] = HEAD
            with self.subTest(other=other), self.assertRaises(excuse.Refused):
                excuse.judge(base.REPO, "feat-cmux-next", base.HEAD, [10], github, flake_state=state())

    def test_raw_actions_job_logs_use_unambiguous_recorded_step_times(self):
        def timed():
            github = self.fake()
            for step, (start, end) in zip(github.jobs[1]["steps"], [(0, 5), (5, 30), (31, 45)]):
                step.update(started_at=f"2026-10-07T02:10:{start:02}Z",
                            completed_at=f"2026-10-07T02:10:{end:02}Z")
            github.logs[1] = "\n".join("2026-10-07T02:10:37.8032610Z " + line for line in HEAD.splitlines())
            return github
        github = timed()
        self.assertIn(ISSUE, excuse.judge(base.REPO, "feat-cmux-next", base.HEAD, [10], github,
                                        flake_state=state())[0])
        for change in ["other failed step", "passed step", "boundary second", "missing time", "duplicate name"]:
            github = timed()
            steps = github.jobs[1]["steps"]
            if change == "other failed step":
                steps.append({"name": "Other tests", "conclusion": "failure",
                              "started_at": "2026-10-07T02:10:46Z", "completed_at": "2026-10-07T02:10:50Z"})
                github.logs[1] += "\n2026-10-07T02:10:49Z ##[error]Process completed with exit code 1."
            elif change == "passed step":
                github.logs[1] = github.logs[1].replace("02:10:37.", "02:10:20.")
            elif change == "boundary second":
                steps[1]["completed_at"] = "2026-10-07T02:10:37Z"
                steps[2]["started_at"] = "2026-10-07T02:10:37Z"
            elif change == "missing time":
                del steps[1]["completed_at"]
            else:
                steps[1]["name"] = steps[2]["name"]
            with self.subTest(change=change), self.assertRaises(excuse.Refused):
                excuse.judge(base.REPO, "feat-cmux-next", base.HEAD, [10], github, flake_state=state())

    def test_red_base_window_combines_exact_and_quarantined_test_failures(self):
        github = self.fake()
        other = FAIL.replace("sometimes()", "other()")
        github.logs[1] += "\n" + other
        github.logs[2] = other + "\n" + SUMMARY
        github.jobs[2]["conclusion"] = "failure"
        audit = excuse.judge(base.REPO, "feat-cmux-next", base.HEAD, [10], github, flake_state=state())
        self.assertIn(ISSUE, audit[0])


if __name__ == "__main__":
    unittest.main()
