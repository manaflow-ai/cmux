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

    def check_results(self, needs):
        return subprocess.run([sys.executable, str(ROOT / "scripts/ci/web_validation.py"), "check"],
            env={**os.environ, "WEB_VALIDATION_NEEDS": json.dumps(needs)}, capture_output=True).returncode

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
