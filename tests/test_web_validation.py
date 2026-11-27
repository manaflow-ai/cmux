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
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)


class CmuxNextBaseWebVerdict(unittest.TestCase):
    """feat-cmux-next pushes run ci-web's checks under the same `web / ...` names as PRs.

    ci.yml runs only on pull requests, so on 2026-10-07 react-apps-check was red on feat-cmux-next
    unseen, and gh-merge-green's base-aware excusal had no base verdict for any web check.
    """

    def setUp(self):
        # Text, not YAML: this file runs on a bare runner Python without PyYAML.
        self.text = (ROOT / ".github/workflows/cmux-next-web.yml").read_text()

    def test_every_feat_cmux_next_push_runs_it(self):
        # Since 2026-11-21 the post-merge batch tier's `web` suite runs ci-web.yml on the base after merges;
        # cmux-next-web.yml runs only when dispatched (next_batch.py's web lane).
        self.assertRegex(self.text, r"\non:\n  workflow_dispatch:\n")
        self.assertNotRegex(self.text, r"\n  push:\n")
        batch = (ROOT / ".github/workflows/cmux-next-post-merge.yml").read_text()
        self.assertIn("  web:\n    needs: plan\n    if: contains(needs.plan.outputs.suites, ' web ')\n", batch)
        self.assertIn("    uses: ./.github/workflows/ci-web.yml\n", batch)
        # No pull_request trigger; the runs-on fork check (#48644) still names github.event_name == 'pull_request'.
        self.assertNotRegex(self.text, r"\n  pull_request(_target)?:")
        self.assertNotIn("paths:", self.text)

    def test_it_calls_ci_web_as_the_web_job_with_every_web_lane(self):
        self.assertIn(
            "  web:\n    needs: coalesce\n"
            "    # A yielded coalesce job (a newer push's run checks these commits) runs no checks.\n"
            "    if: ${{ needs.coalesce.outputs.run != 'false' }}\n"
            "    # actions: read: the webview base replay reads the base's flake history artifact (ci-web.yml).\n"
            "    permissions:\n      contents: read\n      actions: read\n"
            "    uses: ./.github/workflows/ci-web.yml\n    with:\n"
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
                # One shared key for every Bun job (bun-web-shared-v1): the runners share one
                # ~/.bun/install/cache, so per-workflow keys stored the same 1.17 GB folder four
                # times and pushed the repo's Actions cache past its 10 GB cap.
                self.assertIn("key: bun-web-shared-v1-", block)
                key_hash = re.search(r"key: bun-web-shared-v1-.*hashFiles\(([^)]*)\)", block)
                self.assertIsNotNone(key_hash)
                self.assertIn(f"'{lockfile}'", key_hash.group(1))

    def test_webviews_tests_run_on_a_runner_that_starts_jobs_at_widths_that_fit_it(self):
        """`bun test` in webviews grows memory across the suite: on the 4 vCPU runner
        (vars.LINUX_RUNNER) it was SIGKILLed, exit 137, twice in run 37666132324, running as many
        files at once as a 16 vCPU runner. On 2026-11-18 RUNNER_POOLS.linux_16 held 2 vCPU after its
        writer marked the large sizes dead: shards ran 8 files at once there into the 40 min limit
        (run 44249075431) or queued over an hour (run 44304196887). The shards now read the 4 vCPU
        pool (linux_4), run the declared 16 vCPU widths at the share of cores the runner has
        (CMUX_WEB_TEST_SIZED_FOR_VCPU, run-webviews-tests.sh), and get the minutes that takes
        (tests/test_webviews_test_history.py ShardSize evaluates each arm)."""
        workflow = (ROOT / ".github/workflows/ci-web.yml").read_text()
        start = workflow.index("  react-apps-check-shard:")
        match = re.search(r"\n  [A-Za-z0-9_-]+:", workflow[start + 3 :])
        block = workflow[start:] if match is None else workflow[start : start + 3 + match.start()]
        runs_on = re.search(r"^    runs-on: (.+)$", block, re.MULTILINE).group(1)
        self.assertIn("scripts/ci/run-webviews-tests.sh", block)
        self.assertNotIn("vars.LINUX_RUNNER", runs_on)
        self.assertNotIn("linux_16", runs_on)
        # Own-branch Linux jobs take the one cmux-linux label since #48644; linux_4 was the pool before it.
        self.assertTrue(runs_on.endswith(("|| fromJSON(vars.RUNNER_POOLS).linux_4 }}", "|| 'cmux-linux' }}")), runs_on)
        sized_for = int(re.search(r'^          CMUX_WEB_TEST_SIZED_FOR_VCPU: "(\d+)"$', block, re.MULTILINE).group(1))
        sizes = re.findall(r"'blacksmith-(\d+)vcpu-ubuntu-2404'|RUNNER_POOLS\)\.linux_(\d+)", runs_on)
        for vcpu in (int(a or b) for a, b in sizes):
            self.assertLessEqual(vcpu, sized_for, "the widths only narrow to fit a runner, never widen")
        self.assertIn("CMUX_WEB_TEST_JOB_MINUTES: *webview-shard-minutes", block)

    def test_webviews_tests_shard_on_wide_runners(self):
        """Two 8 vCPU shards each ran about 65 dev-server files two at a time for 12 of
        their 14-16 minutes. Twelve 8 vCPU shards took 14.3 min: each paid a cold Vite
        warm-up. Four 32 vCPU shards run eight dev-server files at once on a shared warm
        cache. Blacksmith is a capped paid overflow now (2026-10-30), so the shards run at
        16 vCPU: 14% slower at p50 than 32 for half the price. There, four shards ran their
        dev-server files four at a time for 18-26 min each (p50 24.4 min, 2026-10-31), the
        long pole from ask to merge for a webview fix, so they were eight. At eight the split
        balanced each shard to about 1000 s of tests (2026-11-13), past a 20 min verdict, so
        they were twelve (about 690 s each). Twelve paid twelve setups and cold Vite warm-ups, about 9%
        more runner-minutes than eight (2026-11-22), so they are eight again. The base replay (react-apps-base-check) is one
        job that joins every head shard's results artifact (one job a head shard before #42540)."""
        workflow = (ROOT / ".github/workflows/ci-web.yml").read_text()
        start = workflow.index("  react-apps-check-shard:")
        match = re.search(r"\n  [A-Za-z0-9_-]+:", workflow[start + 3 :])
        block = workflow[start:] if match is None else workflow[start : start + 3 + match.start()]
        # The matrix is web-subarea-scope's pick (webviews_pr_shards.py): all REACT_APPS_SHARDS on a push, shard 1
        # and the shards holding a touched test on a pull request.
        self.assertIn("include: ${{ fromJSON(needs.web-subarea-scope.outputs.react_shards) }}", block)
        scope = workflow[workflow.index("  web-subarea-scope:"):workflow.index("  web-typecheck:")]
        self.assertEqual(int(re.search(r'^          REACT_APPS_SHARDS: "(\d+)"$', scope, re.MULTILINE).group(1)), 12)
        self.assertIn("react_shards: ${{ steps.react-shards.outputs.matrix }}", scope)
        self.assertRegex(block, r"(fromJSON\(vars\.RUNNER_POOLS\)\.linux_4|'cmux-linux') }}")
        base_start = workflow.index("  react-apps-base-check:")
        base_match = re.search(r"\n  [A-Za-z0-9_-]+:", workflow[base_start + 3 :])
        base = workflow[base_start:] if base_match is None else workflow[base_start : base_start + 3 + base_match.start()]
        self.assertNotIn("strategy:", base)
        self.assertIn("HEAD_SHARDS: ${{ needs.web-subarea-scope.outputs.react_shards }}", base)
        self.assertIn("pattern: react-apps-head-results-shard*", base)
        for step in ("Generated bundle merge driver", "Check diff viewer eager JS budget",
                     "Verify React Compiler for webviews", "Check webviews (Oxlint, Oxfmt, source rules)",
                     "Check PR-scoped webview rules"):
            with self.subTest(step=step):
                body = block[block.index(f"- name: {step}"):]
                body = body[: body.index("\n      - name:", 1)] if "\n      - name:" in body[1:] else body
                # Shard 1 only; a same-input receipt hit (#49946, react_shard_receipt.py) may also skip it.
                # The merge driver suite also waits on the focused-map pick (test below).
                self.assertRegex(body, r"\n        if: (matrix\.shard == 1|\$\{\{ matrix\.shard == 1 && "
                                       r"steps\.receipt\.outputs\.hit != 'true'"
                                       r"( && steps\.hook-suites\.outputs\.merge_driver != 'false')? \}\})\n")

    def test_shard_one_runs_the_git_hook_suites_a_pull_request_change_selects(self):
        """The git-hook suites ran on every web pull request head, 1.8 of shard 1's 11 min (ci-min-per-pr-30 cut G).

        A pull request runs each when scripts/ci/focused_tests.py selects it, or when webviews' vp moves; a push runs
        both; an error in the pick runs both."""
        workflow = (ROOT / ".github/workflows/ci-web.yml").read_text()
        start = workflow.index("  react-apps-check-shard:")
        block = workflow[start : workflow.index("\n  react-apps-base-check:", start)]

        def step(name):
            body = block[block.index(f"- name: {name}\n"):]
            return body[: body.index("\n      - name:", 1)] if "\n      - name:" in body[1:] else body

        pick = step("Pick shard 1's git-hook suites")
        self.assertIn("id: hook-suites", pick)
        self.assertIn("continue-on-error: true", pick)
        # Compare complete named steps: an id prefix also matches merge-driver-start,
        # which starts independent work before the picker and does not read its outputs.
        for name, output in (("Generated bundle merge driver", "merge_driver"),
                             ("Post-edit formatting hook", "post_edit")):
            with self.subTest(consumer=name):
                consumer = step(name)
                self.assertLess(block.index(pick), block.index(consumer))
                # A pick that failed or never ran leaves no output, and the suite runs.
                self.assertIn(f"steps.hook-suites.outputs.{output} != 'false'", consumer)
        script = pick[pick.index("        run: |\n") + len("        run: |\n"):]
        # The run block's own lines: the next step's leading comments sit at 6 spaces.
        script = "\n".join(line[10:] for line in script.splitlines() if line.startswith(" " * 10)) + "\n"

        def run(event, files, plan, stub_fails=False):
            with tempfile.TemporaryDirectory() as tmp:
                repo = Path(tmp) / "repo"
                (repo / "scripts/ci").mkdir(parents=True)
                env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
                env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, HOME=tmp,
                           GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
                           GIT_COMMITTER_EMAIL="t@t", EVENT_NAME=event, RUNNER_TEMP=tmp,
                           GITHUB_OUTPUT=str(Path(tmp) / "out"))
                git_fixture_env.without_auto_maintenance(env)
                stub = "import sys; sys.exit(3)" if stub_fails else f"print({json.dumps(json.dumps(plan))})"
                (repo / "scripts/ci/focused_tests.py").write_text(stub + "\n")
                git = lambda *args: subprocess.run(["git", "-C", str(repo), *args], env=env, check=True,
                                                   capture_output=True)
                git("init", "-q")
                git("add", "-A")
                git("commit", "-qm", "base")
                for name in files:
                    (repo / name).parent.mkdir(parents=True, exist_ok=True)
                    (repo / name).write_text("x\n")
                git("add", "-A")
                git("commit", "-qm", "head")
                subprocess.run(["bash", "-e", "-o", "pipefail", "-c", script], cwd=repo, env=env, check=True,
                               capture_output=True)
                lines = (Path(tmp) / "out").read_text().split()
                return dict(line.split("=", 1) for line in lines)

        hooks = {"path": "tests/test_install_git_hooks.py", "lane": "linux-guard"}
        post_edit = {"path": "tests/test_format_post_edit.py", "lane": "linux-guard"}
        self.assertEqual(run("pull_request", ["webviews/src/Pane.tsx"], {"python": []}),
                         {"merge_driver": "false", "post_edit": "false"})
        self.assertEqual(run("pull_request", ["scripts/install-git-hooks.sh"], {"python": [hooks]}),
                         {"merge_driver": "true", "post_edit": "false"})
        self.assertEqual(run("pull_request", ["scripts/format-post-edit.sh"], {"python": [post_edit, hooks]}),
                         {"merge_driver": "true", "post_edit": "true"})
        # The real-vp cases read webviews' installed vp.
        self.assertEqual(run("pull_request", ["webviews/bun.lock"], {"python": []}),
                         {"merge_driver": "true", "post_edit": "true"})
        self.assertEqual(run("pull_request", ["webviews/src/Pane.tsx"], None, stub_fails=True),
                         {"merge_driver": "true", "post_edit": "true"})
        self.assertEqual(run("push", ["webviews/src/Pane.tsx"], {"python": []}),
                         {"merge_driver": "true", "post_edit": "true"})

    def test_a_shard_whose_engines_failed_is_red_without_running_its_tests(self):
        """A failed engine install went on to the whole suite, 15-25 min, and the shard was red
        anyway (run 43337871244): the tests now skip and the gate step names the engine step."""
        workflow = (ROOT / ".github/workflows/ci-web.yml").read_text()
        start = workflow.index("  react-apps-check-shard:")
        block = workflow[start : workflow.index("\n  react-apps-base-check:", start)]
        def step(name):
            body = block[block.index(f"- name: {name}\n"):]
            return body[: body.index("\n      - name:", 1)] if "\n      - name:" in body[1:] else body
        self.assertIn("id: engines", step("Install headless engines"))
        # The tests run unless cancelled, the engines failed or a same-input receipt (#49946) already holds their
        # results: each is a top-level && term of the condition.
        self.assertRegex(step("Test webviews"), r"\$\{\{ !cancelled\(\) (&& steps\.receipt\.outputs\.hit != 'true' )?"
                                                r"&& steps\.engines\.outcome != 'failure' && ")
        self.assertIn("steps.webview-tests.outcome != 'skipped'", step("Upload head webview results"))
        # A pull request's shard whose gate check failed is red whatever its tests say: it skips them (11-21:
        # 50 of 52 shard 1 jobs red on one gate, then 40 min of tests). A push still runs every test.
        tests = " ".join(step("Test webviews").split())
        self.assertIn("!(github.event_name == 'pull_request' && (", tests)
        for gate_id in ("source-build", "bundles", "merge-driver", "post-edit-format", "webviews-check",
                        "pr-scoped-rules"):
            with self.subTest(gate=gate_id):
                self.assertIn(f"steps.{gate_id}.outcome == 'failure'", tests)
                self.assertIn(f"id: {gate_id}", block)
        gate = step("Fail on the gate checks")
        self.assertIn("ENGINES: ${{ steps.engines.outcome }}", gate)
        self.assertIn('"ENGINES|Install headless engines"', gate)
        # The split starts shard 1 at the seconds its shard-only checks take.
        self.assertIn('CMUX_WEB_TEST_SHARD_HEAD_START: "1:120"', step("Test webviews"))

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


    def test_web_typecheck_generates_next_route_types_the_build_no_longer_checks(self):
        """The production build skips type errors (CMUX_CI_TYPECHECK_SEPARATE); web-typecheck runs next typegen
        first, so a route type error in .next/types still turns web-typecheck red."""
        workflow = (ROOT / ".github/workflows/ci-web.yml").read_text()
        start = workflow.index("  web-typecheck:")
        match = re.search(r"\n  [A-Za-z0-9_-]+:", workflow[start + 3 :])
        block = workflow[start:] if match is None else workflow[start : start + 3 + match.start()]
        typegen = block.index("run: bun x next typegen")
        self.assertLess(typegen, block.index("- name: Typecheck"))
        # next typegen loads next.config.ts, which validates app/env.ts; CI holds none of its secrets.
        step = block[block.index("- name: Generate Next route types") : typegen]
        self.assertIn('SKIP_ENV_VALIDATION: "1"', step)
        self.assertIn("CMUX_CI_TYPECHECK_SEPARATE: \"1\"", workflow)

if __name__ == "__main__":
    unittest.main()
