#!/usr/bin/env python3
"""Exercise web routing and its required status without credentials."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import web_validation as gate


class WebValidationTests(unittest.TestCase):
    def test_web_inputs_and_mixed_changes_are_selected(self):
        for path in (
            "web/app/api/coderouter/new/route.ts", "web/services/coderouter/accounts.ts",
            "web/tests/new.test.ts", "web/bun.lock", "package.json", "bun.lock",
            ".vercelignore", "vercel.json", "bunfig.toml", ".npmrc", "CHANGELOG.md",
            ".github/workflows/web-validation.yml", "scripts/ci/web_validation.py",
            "config/iroh/managed-relay-catalog.json", "workers/presence/src/generated/managedRelayCatalog.ts",
            "tests/test_web_validation.py",
        ):
            with self.subTest(path=path):
                self.assertTrue(gate.requires_web([path, "README.md"]))
        self.assertFalse(gate.requires_web(["README.md", "docs/cli.md", "Sources/AppDelegate.swift"]))

    def test_pull_request_routes_from_the_merge_parent_when_the_event_base_is_gone(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            def git(*args):
                return subprocess.check_output([
                    "git", "-c", "user.name=CI", "-c", "user.email=ci@example.test",
                    "-c", "core.hooksPath=/dev/null", *args,
                ], cwd=repo, text=True, stderr=subprocess.DEVNULL).strip()
            git("init", "-q", "-b", "main")
            (repo / "README.md").write_text("base\n")
            git("add", ".")
            git("commit", "-qm", "base")
            git("branch", "feature")
            (repo / "web").mkdir()
            (repo / "web/main-only.ts").write_text("export const value = 1;\n")
            git("add", ".")
            git("commit", "-qm", "main gains a web file")
            git("checkout", "-q", "feature")
            (repo / "docs").mkdir()
            (repo / "docs/note.md").write_text("docs only\n")
            git("add", ".")
            git("commit", "-qm", "docs")
            git("checkout", "-q", "main")
            git("merge", "-q", "--no-ff", "feature", "-m", "synthetic merge")
            output = repo / "outputs"
            output.write_text("")
            # The event base is a commit this checkout does not have.
            subprocess.run([sys.executable, str(ROOT / "scripts/ci/web_validation.py"), "route"],
                cwd=repo, env={**os.environ, "EVENT_NAME": "pull_request", "BASE_SHA": "1" * 40,
                    "HEAD_SHA": git("rev-parse", "HEAD"), "GITHUB_OUTPUT": str(output)}, check=True,
                capture_output=True)
            self.assertEqual(output.read_text().strip(), "required=false")

    def test_real_pr_and_push_diffs_and_missing_history(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            def git(*args):
                return subprocess.check_output([
                    "git", "-c", "user.name=CI", "-c", "user.email=ci@example.test",
                    "-c", "core.hooksPath=/dev/null", *args,
                ], cwd=repo, text=True, stderr=subprocess.DEVNULL).strip()
            git("init", "-q")
            (repo / "README.md").write_text("base\n")
            git("add", ".")
            git("commit", "-qm", "base")
            base = git("rev-parse", "HEAD")
            (repo / "web").mkdir()
            (repo / "web/new.ts").write_text("export const value = 1;\n")
            git("add", ".")
            git("commit", "-qm", "web")
            head = git("rev-parse", "HEAD")
            output = repo / "outputs"
            for event, before in (("pull_request", base), ("push", base), ("push", "0" * 40)):
                output.write_text("")
                subprocess.run([sys.executable, str(ROOT / "scripts/ci/web_validation.py"), "route"],
                    cwd=repo, env={**os.environ, "EVENT_NAME": event, "BASE_SHA": before,
                        "HEAD_SHA": head, "GITHUB_OUTPUT": str(output)}, check=True, capture_output=True)
                self.assertEqual(output.read_text().strip(), "required=true")
            (repo / "README.md").write_text("docs only\n")
            git("add", ".")
            git("commit", "-qm", "docs")
            output.write_text("")
            subprocess.run([sys.executable, str(ROOT / "scripts/ci/web_validation.py"), "route"],
                cwd=repo, env={**os.environ, "EVENT_NAME": "pull_request", "BASE_SHA": head,
                    "HEAD_SHA": git("rev-parse", "HEAD"), "GITHUB_OUTPUT": str(output)}, check=True,
                capture_output=True)
            self.assertEqual(output.read_text().strip(), "required=false")
            before_move = git("rev-parse", "HEAD")
            (repo / "docs").mkdir()
            git("mv", "web/new.ts", "docs/new.ts")
            git("commit", "-qm", "move out of web")
            output.write_text("")
            subprocess.run([sys.executable, str(ROOT / "scripts/ci/web_validation.py"), "route"],
                cwd=repo, env={**os.environ, "EVENT_NAME": "pull_request", "BASE_SHA": before_move,
                    "HEAD_SHA": git("rev-parse", "HEAD"), "GITHUB_OUTPUT": str(output)}, check=True,
                capture_output=True)
            self.assertEqual(output.read_text().strip(), "required=true")

            before_move_back = git("rev-parse", "HEAD")
            git("mv", "docs/new.ts", "web/new.ts")
            git("commit", "-qm", "move back into web")
            output.write_text("")
            subprocess.run([sys.executable, str(ROOT / "scripts/ci/web_validation.py"), "route"],
                cwd=repo, env={**os.environ, "EVENT_NAME": "pull_request", "BASE_SHA": before_move_back,
                    "HEAD_SHA": git("rev-parse", "HEAD"), "GITHUB_OUTPUT": str(output)}, check=True,
                capture_output=True)
            self.assertEqual(output.read_text().strip(), "required=true")

    def test_ci_selects_every_input_previously_owned_by_web_validation(self):
        for path in (
            ".vercelignore", "vercel.json", "bunfig.toml", ".npmrc",
            ".github/workflows/web-validation.yml", "tests/test_web_validation.py",
            "config/iroh/managed-relay-catalog.json",
            "workers/presence/src/generated/managedRelayCatalog.ts",
        ):
            with self.subTest(path=path):
                self.assertTrue(gate.classify_files([path]).web)

    def test_pr_and_merge_group_workflow_delegation_uses_one_cheap_status_job(self):
        workflow = (ROOT / ".github/workflows/web-validation.yml").read_text()
        changes = workflow[workflow.index("  changes:"):workflow.index("\n  build:")]
        status = workflow[workflow.index("  web-validation:"):]

        delegated = "github.event_name == 'pull_request' || github.event_name == 'merge_group'"
        standalone = "github.event_name != 'pull_request' && github.event_name != 'merge_group'"

        self.assertIn(standalone, changes)
        self.assertIn("Accept CI-owned pull-request validation", status)
        self.assertIn(delegated, status)
        self.assertGreaterEqual(status.count(standalone), 2)
        self.assertIn("required ci-status check", status)

    def test_pr_and_merge_group_checks_belong_to_ci(self):
        delegated = {"changes": {"result": "success", "outputs": {"required": "true"}},
                     "build": {"result": "skipped"},
                     "tests": {"result": "skipped"}, "database": {"result": "skipped"}}
        for event in ("pull_request", "merge_group"):
            with self.subTest(event=event):
                self.assertEqual(self.check_results(delegated, event), 0)
                for result in ("failure", "cancelled"):
                    self.assertNotEqual(self.check_results(
                        {**delegated, "build": {"result": result}}, event), 0)
                self.assertEqual(self.check_results(
                    {**delegated, "build": {"result": "skipped"}}, event), 0)
                for job in ("tests", "database"):
                    for result in ("failure", "cancelled"):
                        self.assertNotEqual(self.check_results(
                            {**delegated, job: {"result": result}}, event), 0)
                    missing = dict(delegated)
                    del missing[job]
                    self.assertNotEqual(self.check_results(missing, event), 0)
        for event in ("push", "workflow_dispatch", "", "unknown"):
            with self.subTest(event=event):
                self.assertNotEqual(self.check_results(delegated, event), 0)

    def check_results(self, needs, event="workflow_dispatch"):
        return subprocess.run([sys.executable, str(ROOT / "scripts/ci/web_validation.py"), "check"],
            env={**os.environ, "WEB_VALIDATION_NEEDS": json.dumps(needs),
                 "GITHUB_EVENT_NAME": event}, capture_output=True).returncode

    def test_gate_rejects_missing_cancelled_failed_or_skipped_required_jobs(self):
        good = {"changes": {"result": "success", "outputs": {"required": "true"}},
                **{job: {"result": "success"} for job in ("build", "tests", "database")}}
        self.assertEqual(self.check_results(good), 0)
        self.assertNotEqual(self.check_results({**good, "future-check": {"result": "failure"}}), 0)
        for job in ("build", "tests", "database"):
            for result in ("failure", "cancelled", "skipped", "timed_out"):
                with self.subTest(job=job, result=result):
                    self.assertNotEqual(self.check_results({**good, job: {"result": result}}), 0)
            missing = dict(good)
            del missing[job]
            self.assertNotEqual(self.check_results(missing), 0)
        for changes in ({}, {"result": "failure"}, {"result": "success", "outputs": {"required": "unknown"}}):
            self.assertNotEqual(self.check_results({**good, "changes": changes}), 0)
        docs = {"changes": {"result": "success", "outputs": {"required": "false"}},
                **{job: {"result": "skipped"} for job in ("build", "tests", "database")}}
        self.assertEqual(self.check_results(docs), 0)
        self.assertNotEqual(self.check_results({**docs, "build": {"result": "failure"}}), 0)


if __name__ == "__main__":
    unittest.main()
