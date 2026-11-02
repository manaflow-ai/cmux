#!/usr/bin/env python3
"""Exercise web routing and its required status without credentials."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import web_validation as gate
import git_fixture_env  # noqa: F401  (disables git auto maintenance)


class CmuxNextBaseWebVerdict(unittest.TestCase):
    """feat-cmux-next pushes run ci-web's checks under the same `web / ...` names as PRs.

    ci.yml runs only on pull requests, so on 2026-10-07 react-apps-check was red on feat-cmux-next
    unseen, and gh-merge-green's base-aware excusal had no base verdict for any web check.
    """

    def setUp(self):
        # Text, not YAML: this file runs on a bare runner Python without PyYAML.
        self.text = (ROOT / ".github/workflows/cmux-next-web.yml").read_text()

    def test_every_feat_cmux_next_push_runs_it(self):
        self.assertRegex(self.text, r"\non:\n  push:\n    branches: \[feat-cmux-next\]\n")
        self.assertNotIn("pull_request", self.text)
        self.assertNotIn("paths:", self.text)

    def test_it_calls_ci_web_as_the_web_job_with_every_web_lane(self):
        self.assertIn(
            "jobs:\n  web:\n    uses: ./.github/workflows/ci-web.yml\n    with:\n"
            "      web: ${{ 'true' }}\n      macos: ${{ 'false' }}\n      agent_session_web: ${{ 'true' }}\n",
            self.text,
        )

    def test_a_later_push_never_cancels_a_verdict(self):
        self.assertIn("group: cmux-next-web-${{ github.sha }}\n  cancel-in-progress: false\n", self.text)


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

    def test_native_artifact_transport_does_not_select_web(self):
        paths = [
            ".github/workflows/ci-artifact-transport.yml",
            ".github/workflows/ci-macos.yml",
            "scripts/ci/parallel_artifact_download.py",
            "scripts/ci/restore-app-host-test-product.sh",
            "tests/test-execution.toml",
            "tests/test_ci_change_areas.py",
            "tests/test_ci_parallel_artifact_transport.py",
        ]
        self.assertFalse(gate.requires_web(paths))
        self.assertTrue(gate.requires_web(paths + ["web/app/page.tsx"]))
        self.assertTrue(gate.requires_web(["scripts/ci/future_unknown_helper.py"]))

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

    def test_ci_web_caches_bun_packages_for_each_install_lockfile(self):
        workflow = (ROOT / ".github/workflows/ci-web.yml").read_text()
        expected = {
            "web-typecheck": "web/bun.lock",
            "web-production-build": "web/bun.lock",
            "web-tests": "web/bun.lock",
            "web-instant-navigation": "web/bun.lock",
            "diff-sidecar-check": "webviews/bun.lock",
            "web-db-migrations": "web/bun.lock",
        }
        for job, lockfile in expected.items():
            with self.subTest(job=job):
                start = workflow.index(f"  {job}:")
                match = re.search(r"\n  [A-Za-z0-9_-]+:", workflow[start + 3 :])
                next_job = -1 if match is None else start + 3 + match.start()
                block = workflow[start:] if next_job < 0 else workflow[start:next_job]
                self.assertIn("uses: actions/cache@", block)
                self.assertIn("path: ~/.bun/install/cache", block)
                self.assertIn(f"hashFiles('{lockfile}')", block)

    def test_webviews_tests_run_on_a_runner_with_room_for_the_suite(self):
        """`bun test` in webviews grows memory across the suite: on the 4 vCPU runner
        (vars.LINUX_RUNNER) it was SIGKILLed, exit 137, twice in run 37666132324."""
        workflow = (ROOT / ".github/workflows/ci-web.yml").read_text()
        start = workflow.index("  react-apps-check-shard:")
        match = re.search(r"\n  [A-Za-z0-9_-]+:", workflow[start + 3 :])
        block = workflow[start:] if match is None else workflow[start : start + 3 + match.start()]
        runs_on = re.search(r"^    runs-on: (.+)$", block, re.MULTILINE).group(1)
        self.assertIn("scripts/ci/run-webviews-tests.sh", block)
        self.assertNotIn("vars.LINUX_RUNNER", runs_on)
        self.assertNotIn("4vcpu", runs_on)
        # 16 vCPU (memory for the suite at half the 32 vCPU price), failing over to 32.
        self.assertTrue(runs_on.endswith("'blacksmith-16vcpu-ubuntu-2404' }}"), runs_on)
        self.assertIn("vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-32vcpu-ubuntu-2404'", runs_on)

    def test_webviews_tests_shard_on_wide_runners(self):
        """Two 8 vCPU shards each ran about 65 dev-server files two at a time for 12 of
        their 14-16 minutes. Twelve 8 vCPU shards took 14.3 min: each paid a cold Vite
        warm-up. Four 32 vCPU shards run eight dev-server files at once on a shared warm
        cache. Blacksmith is a capped paid overflow now (2026-10-30), so the shards run at
        16 vCPU: 14% slower at p50 than 32 for half the price. There, four shards ran their
        dev-server files four at a time for 18-26 min each (p50 24.4 min, 2026-10-31), the
        long pole from ask to merge for a webview fix, so they are eight. The base replay
        (react-apps-base-check) takes one shard per head shard's results artifact."""
        workflow = (ROOT / ".github/workflows/ci-web.yml").read_text()
        start = workflow.index("  react-apps-check-shard:")
        match = re.search(r"\n  [A-Za-z0-9_-]+:", workflow[start + 3 :])
        block = workflow[start:] if match is None else workflow[start : start + 3 + match.start()]
        shards = [int(n) for n in re.findall(r"^          - shard: (\d+)$", block, re.MULTILINE)]
        counts = set(re.findall(r"^            shard_count: (\d+)$", block, re.MULTILINE))
        self.assertEqual(len(shards), 8)
        self.assertIn("'blacksmith-16vcpu-ubuntu-2404' }}", block)
        self.assertEqual(shards, list(range(1, len(shards) + 1)))
        self.assertEqual(counts, {str(len(shards))})
        base_start = workflow.index("  react-apps-base-check:")
        base_match = re.search(r"\n  [A-Za-z0-9_-]+:", workflow[base_start + 3 :])
        base = workflow[base_start:] if base_match is None else workflow[base_start : base_start + 3 + base_match.start()]
        self.assertEqual([int(n) for n in re.findall(r"^          - shard: (\d+)$", base, re.MULTILINE)], shards)
        for step in ("Generated bundle merge driver", "Check diff viewer eager JS budget",
                     "Verify React Compiler for webviews", "Check webviews (Oxlint, Oxfmt, type check)",
                     "Check PR-scoped webview rules"):
            with self.subTest(step=step):
                body = block[block.index(f"- name: {step}"):]
                body = body[: body.index("\n      - name:", 1)] if "\n      - name:" in body[1:] else body
                self.assertIn("if: matrix.shard == 1", body)

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
