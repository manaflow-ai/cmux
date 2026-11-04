"""Measured base flakes may waive their exact quarantined diagnostic, never an unreadable or new failure."""
import copy
import importlib.util
import json
import tempfile
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
         "passes": 6, "failures": 4, "flips": 4, "flip_rate": 4 / 9,
         "failure_signatures": [failed["signature"]],
         "quarantine": {"issue": ISSUE, "until": (NOW + timedelta(days=1)).isoformat()}}]}


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

    def test_insufficient_stale_expired_malformed_or_ambiguous_evidence_is_ignored(self):
        changes = [lambda s: s.update(generated_at=(NOW - timedelta(days=3)).isoformat()),
                   lambda s: s.update(generated_at=(NOW + timedelta(days=1)).isoformat()),
                   lambda s: s.update(schema="other"), lambda s: s.update(tests={}),
                   lambda s: s["tests"].append(copy.deepcopy(s["tests"][0]))]
        row_changes = [{"observations": 4, "passes": 2, "failures": 2}, {"flips": 1},
                       {"flips": 2, "observations": 20, "passes": 16}, {"observations": True},
                       {"passes": 0}, {"failures": 0}, {"failure_signatures": FAIL},
                       {"failure_signatures": [""]}, {"quarantine": None},
                       {"workflow": "another"}, {"job": "another"},
                       {"quarantine": {"issue": ISSUE, "until": (NOW - timedelta(seconds=1)).isoformat()}},
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


class BaseRedConsumer(unittest.TestCase):
    def fake(self):
        github = base.FakeGitHub()
        github.logs[1] = HEAD
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
        github.logs[1] = text
        self.assertIn(ISSUE, excuse.judge(base.REPO, "feat-cmux-next", base.HEAD, [10], github,
                                        flake_state=snapshot)[0])
        github.logs[1] += "\nerror: Failed to compile another package"
        with self.assertRaises(excuse.Refused):
            excuse.judge(base.REPO, "feat-cmux-next", base.HEAD, [10], github, flake_state=snapshot)

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
