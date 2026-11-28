#!/usr/bin/env python3
"""Candidate keys and mirror receipts must never manufacture a skipped green."""
from __future__ import annotations

import contextlib
import datetime
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import rebuild_mirror as mirror  # noqa: E402
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)


class CandidateInputs(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.git("init", "-q")
        self.write(mirror.TABLE, json.dumps({"jobs": {"cmux-next.yml:release-compile": {
            "rebuild_mirror": {"inputs": ["other"], "independent": ["unrelated", "Packages"]}}}}))
        self.write(mirror.inputs.WORKFLOW, "name: fixture\njobs: {}\n")
        self.write(mirror.SCRIPT, "# planner fixture\n")
        self.write("scripts/ci/job_input_fingerprint.py", "# fingerprint fixture\n")
        self.write("scripts/ci/job_reuse.py", "# reuse fixture\n")
        self.write(mirror.inputs.GRAPH, json.dumps({"targets": {
            "FixtureTests": {"reads": ["unrelated/fixture.json"], "targets": [],
                             "packages": [], "kind": "test"}}}))
        self.write("Packages/Shared/Fixture/Sources/Fixture.swift", "let value = 1\n")
        self.write("unrelated/README.md", "Not a declared job input.\n")
        self.write("unrelated/fixture.json", '{"input": 1}\n')
        self.write("other/input.txt", "unknown paths remain inputs\n")
        self.commit()

    def git(self, *arguments):
        environment = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_SYSTEM": os.devnull,
                       "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
                       "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid"}
        return subprocess.run(["git", "-C", str(self.root), *arguments], env=environment,
                              check=True, capture_output=True, text=True, timeout=20).stdout.strip()

    def write(self, name, value):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-qm", "fixture", "--allow-empty")

    def full(self, **overrides):
        values = {"xcode": "Xcode 26 build fixture", "macos": "26", "macos_build": "fixture",
                  "arch": "arm64", "pool": "owned", "mini": "true", "xcode_app": "/fixture/Xcode"}
        values.update(overrides)
        return mirror.inputs.fingerprint(str(self.root), "HEAD", "release-compile",
                                         [f"{key}={value}" for key, value in values.items()])[1]

    def key(self, **overrides):
        return mirror.candidate(str(self.root), "HEAD", "release-compile", self.full(**overrides))[0]

    def test_declared_independent_edit_keeps_candidate_but_changes_full_fingerprint(self):
        before, full = self.key(), mirror.digest(self.full())
        self.write("unrelated/README.md", "Changed independently.\n")
        self.commit()
        self.assertEqual(before, self.key())
        self.assertNotEqual(full, mirror.digest(self.full()))

    def test_input_closure_overrides_independent_package_root(self):
        before = self.key()
        self.write("Packages/Shared/Fixture/Sources/Fixture.swift", "let value = 2\n")
        self.commit()
        self.assertNotEqual(before, self.key())

    def test_swift_graph_read_overrides_independent_root(self):
        before = self.key()
        self.write("unrelated/fixture.json", '{"input": 2}\n')
        self.commit()
        self.assertNotEqual(before, self.key())

    def test_explicit_job_input_overrides_independent_root(self):
        table = json.loads((self.root / mirror.TABLE).read_text())
        table["jobs"]["cmux-next.yml:release-compile"]["rebuild_mirror"]["inputs"].append("unrelated/explicit.txt")
        self.write(mirror.TABLE, json.dumps(table))
        self.write("unrelated/explicit.txt", "declared input\n")
        self.commit()
        before = self.key()
        self.write("unrelated/explicit.txt", "changed declared input\n")
        self.commit()
        self.assertNotEqual(before, self.key())

    def test_unknown_new_directory_invalidates_candidate(self):
        before = self.key()
        self.write("new-directory/new-input.txt", "unclassified input\n")
        self.commit()
        self.assertNotEqual(before, self.key())

    def test_deleted_input_invalidates_candidate(self):
        before = self.key()
        (self.root / "other/input.txt").unlink()
        self.commit()
        self.assertNotEqual(before, self.key())

    def test_executable_mode_invalidates_candidate(self):
        before = self.key()
        self.git("update-index", "--chmod=+x", "other/input.txt")
        self.git("commit", "-qm", "executable input")
        self.assertNotEqual(before, self.key())

    def test_toolchain_and_flags_invalidate_candidate(self):
        before = self.key()
        for changes in ({"xcode": "a different compiler"}, {"mini": "false"},
                        {"xcode_app": "/other/Xcode"}):
            with self.subTest(changes=changes):
                self.assertNotEqual(before, self.key(**changes))

    def test_missing_or_malformed_graph_records_uncertainty_not_a_skip(self):
        for graph in (None, "{", '{"targets": {}}', "[]",
                      '{"targets": {"Test": {"reads": "docs"}}}'):
            with self.subTest(graph=graph):
                path = self.root / mirror.inputs.GRAPH
                if graph is None:
                    path.unlink(missing_ok=True)
                else:
                    self.write(mirror.inputs.GRAPH, graph)
                self.commit()
                plan = self.root / "plan.json"
                with mock.patch.object(mirror.job_reuse, "lookup") as lookup, contextlib.redirect_stdout(io.StringIO()):
                    mirror.start(str(self.root), "HEAD", "release-compile", self.full(), plan)
                receipt = json.loads(plan.read_text())
                self.assertFalse(receipt["candidate_skip"])
                self.assertTrue(receipt["uncertain"])
                lookup.assert_not_called()

    def test_lookup_failure_records_uncertainty_without_skipping(self):
        plan = self.root / "plan.json"
        with mock.patch.object(mirror.job_reuse, "lookup", side_effect=mirror.job_reuse.Miss("unavailable")), \
                contextlib.redirect_stdout(io.StringIO()):
            mirror.start(str(self.root), "HEAD", "release-compile", self.full(), plan)
        receipt = json.loads(plan.read_text())
        self.assertFalse(receipt["candidate_skip"])
        self.assertIn("unavailable", receipt["uncertain"])

    def test_candidate_hit_records_the_prior_commit_for_cross_commit_comparisons(self):
        plan = self.root / "plan.json"
        previous = "a" * 40
        with mock.patch.object(mirror.job_reuse, "lookup", return_value={
                "hit": "true", "sha": previous, "run_url": "https://github.com/example/repository/actions/runs/1"}), \
                contextlib.redirect_stdout(io.StringIO()):
            mirror.start(str(self.root), "HEAD", "release-compile", self.full(), plan)
        record = json.loads(plan.read_text())
        self.assertTrue(record["candidate_skip"])
        self.assertEqual(record["previous_sha"], previous)
        self.assertNotEqual(record["previous_sha"], record["sha"])

    def test_candidate_key_is_exposed_for_the_enforcement_lookup(self):
        plan = self.root / "plan.json"
        with mock.patch.object(mirror.job_reuse, "lookup", return_value={"hit": "false"}), \
                contextlib.redirect_stdout(io.StringIO()) as stdout:
            mirror.start(str(self.root), "HEAD", "release-compile", self.full(), plan)
        record = json.loads(plan.read_text())
        self.assertIn(f"candidate_key={record['candidate_key']}", stdout.getvalue())

    def test_promotion_evidence_requires_matching_policy_and_a_full_day(self):
        evidence = self.root / "evidence.json"
        base = {"schema": "ci-rebuild-evidence/v1", "enabled": True,
                "policy": mirror.policy_identity(str(self.root), "HEAD", "release-compile"),
                "window_seconds": 86400, "false_skip_rate": 0,
                "complete": 1, "measured_at": "2026-11-04T00:00:00Z"}
        evidence.write_text(json.dumps(base))
        measured = datetime.datetime(2026, 11, 4, tzinfo=datetime.timezone.utc).timestamp() + 60
        with mock.patch.object(mirror.time, "time", return_value=measured):
            self.assertEqual(mirror.verify_evidence(str(self.root), "HEAD", "release-compile", evidence),
                             (True, "eligible"))
        for field, value in (("policy", "wrong"), ("window_seconds", 86399),
                             ("false_skip_rate", 0.01), ("complete", 0), ("enabled", False),
                             ("window_seconds", True), ("window_seconds", float("inf")),
                             ("false_skip_rate", False), ("false_skip_rate", float("nan")),
                             ("complete", True)):
            with self.subTest(field=field):
                changed = dict(base, **{field: value})
                evidence.write_text(json.dumps(changed))
                eligible, _ = mirror.verify_evidence(str(self.root), "HEAD", "release-compile", evidence)
                self.assertFalse(eligible)
        for timestamp in ("2020-01-01T00:00:00Z", "2026-11-04T00:00:00"):
            with self.subTest(timestamp=timestamp):
                evidence.write_text(json.dumps(dict(base, measured_at=timestamp)))
                eligible, _ = mirror.verify_evidence(str(self.root), "HEAD", "release-compile", evidence)
                self.assertFalse(eligible)
        for malformed in ([], "text"):
            with self.subTest(malformed=malformed):
                evidence.write_text(json.dumps(malformed))
                eligible, reason = mirror.verify_evidence(str(self.root), "HEAD", "release-compile", evidence)
                self.assertFalse(eligible)
                self.assertIn("object", reason)

    def test_pr_job_keeps_both_actions_head_and_built_merge_commit(self):
        plan = self.root / "plan.json"
        head = "d" * 40
        with mock.patch.dict(os.environ, {"REBUILD_HEAD_SHA": head}), \
                mock.patch.object(mirror.job_reuse, "lookup", return_value={"hit": "false"}), \
                contextlib.redirect_stdout(io.StringIO()):
            mirror.start(str(self.root), "HEAD", "release-compile", self.full(), plan)
        record = json.loads(plan.read_text())
        self.assertEqual(record["head_sha"], head)
        self.assertEqual(record["sha"], self.git("rev-parse", "HEAD"))
        self.assertNotEqual(record["sha"], record["head_sha"])


def receipt(**changes):
    value = {"schema": mirror.SCHEMA, "repository": "example/repository", "run_id": "42",
             "attempt": "1", "job": "fast-tier-cargo", "mode": "mirror", "started_at": 0,
             "sha": "b" * 40,
             "candidate_key": "job-pass-mirror-fast-tier-cargo-" + "a" * 40,
             "candidate_skip": True, "outcome": "success", "execution_minutes": 2,
             "execution_receipt": "c" * 64}
    value.update(changes)
    return value


def execution():
    return {"schema": "cmux-next-fast-tier-receipt.v1", "status": "pass", "kinds": ["cargo", "script"],
            "entries": [{"name": "core", "status": "PASS"}, {"name": "script", "status": "PASS"}],
            "github": {"GITHUB_SHA": "b" * 40, "GITHUB_RUN_ID": "42"}}


class MirrorReceipts(unittest.TestCase):
    def test_empty_evidence_is_not_zero_false_skip_rate(self):
        summary = mirror.report([])
        self.assertEqual(summary["observations"], 0)
        self.assertIsNone(summary["false_skip_rate"])
        self.assertFalse(summary["enforcement"])

    def test_duplicate_receipt_counts_once_but_distinct_attempts_count_separately(self):
        first = receipt()
        second = receipt(attempt="2", outcome="failure", execution_minutes=3)
        summary = mirror.report([first, dict(first), second])
        self.assertEqual(summary["observations"], 2)
        self.assertEqual(summary["candidate_skips"], 2)
        self.assertEqual(summary["false_skips"], 1)
        self.assertEqual(summary["false_skip_rate"], 0.5)
        self.assertEqual(summary["full_execution_minutes"], 5)
        self.assertEqual(summary["candidate_execution_minutes"], 3)
        self.assertEqual(summary["actual_saved_machine_minutes"], 0)
        self.assertFalse(summary["enforcement"])

    def test_cancelled_skipped_and_uncertain_results_are_incomplete(self):
        rows = [receipt(attempt="1", outcome="cancelled"), receipt(attempt="2", outcome="skipped"),
                receipt(attempt="3", uncertain="lookup unavailable"),
                receipt(attempt="4", outcome=None), receipt(attempt="5", execution_receipt=None)]
        summary = mirror.report(rows)
        self.assertEqual(summary["incomplete"], 5)
        self.assertEqual(summary["complete"], 0)
        self.assertEqual(summary["candidate_skips"], 0)
        self.assertIsNone(summary["false_skip_rate"])

    def test_conflicting_receipts_or_missing_identity_are_rejected(self):
        with self.assertRaises(ValueError):
            mirror.report([receipt(), receipt(outcome="failure")])
        with self.assertRaises(ValueError):
            mirror.report([receipt(run_id="")])

    def finish(self, outcome, executed=True, **changes):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            plan = root / "plan.json"
            plan.write_text(json.dumps(receipt(**changes)))
            output = root / "result.json"
            run_receipt = root / "execution.json" if executed is not None else None
            if run_receipt:
                run_receipt.write_text(json.dumps(execution() if executed is True else executed))
            registry = {"entries": [{"name": "core", "kind": "cargo"},
                                    {"name": "script", "kind": "script"},
                                    {"name": "other-platform", "kind": "swift"}]}
            stdout = io.StringIO()
            with mock.patch.object(mirror.time, "time", return_value=120), \
                    mock.patch.object(mirror.inputs, "git", return_value=json.dumps(registry)), \
                    contextlib.redirect_stdout(stdout):
                result = mirror.finish(plan, outcome, output, run_receipt)
            self.assertEqual(result, json.loads(output.read_text()))
            return result, stdout.getvalue()

    def test_failed_cancelled_skipped_or_uncertain_execution_never_publishes_green(self):
        for outcome in ("failure", "cancelled", "skipped"):
            with self.subTest(outcome=outcome):
                _, output = self.finish(outcome)
                self.assertEqual(output, "")
        _, output = self.finish("success", uncertain="missing closure")
        self.assertEqual(output, "")

    def test_success_records_elapsed_time_and_publishes_candidate_green(self):
        result, output = self.finish("success")
        self.assertEqual(result["execution_minutes"], 2)
        self.assertFalse(result["false_skip"])
        self.assertEqual(output, f"key={result['candidate_key']}\n")

    def test_success_without_full_execution_evidence_cannot_publish_green(self):
        invalid = [None, {}, [], {**execution(), "github": []}, {**execution(), "entries": []},
                   {**execution(), "status": "fail"},
                   {**execution(), "kinds": ["cargo"]},
                   {**execution(), "github": {"GITHUB_SHA": "c" * 40, "GITHUB_RUN_ID": "42"}},
                   {**execution(), "github": {"GITHUB_SHA": "b" * 40, "GITHUB_RUN_ID": "43"}}]
        for run in invalid:
            with self.subTest(execution=run):
                result, output = self.finish("success", executed=run)
                self.assertEqual(output, "")
                self.assertTrue(result["uncertain"])

    def test_quarantined_or_partial_test_execution_cannot_publish_green(self):
        for status in ("QUARANTINED-PASS", "QUARANTINED-FAIL", "FLAKY", "ADMISSIBLE"):
            with self.subTest(status=status):
                run = execution()
                run["entries"][0]["status"] = status
                result, output = self.finish("success", executed=run)
                self.assertEqual(output, "")
                self.assertTrue(result["uncertain"])
        run = execution()
        run["entries"].pop()
        result, output = self.finish("success", executed=run)
        self.assertEqual(output, "")
        self.assertTrue(result["uncertain"])

    def test_failure_after_candidate_hit_is_false_skip(self):
        result, _ = self.finish("failure")
        self.assertTrue(result["false_skip"])
        result, _ = self.finish("failure", candidate_skip=False)
        self.assertFalse(result["false_skip"])


if __name__ == "__main__":
    unittest.main()
