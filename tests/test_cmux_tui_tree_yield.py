#!/usr/bin/env python3
"""An unstarted feat-cmux-next tree build yields when no tip or nightly cut has its key.

2026-11-18: 109 feat-cmux-next cmux-tui artifacts runs from 06:00Z to 11:10Z built 27 tree keys,
five 16 vCPU legs each on a vCPU-capped pool, and only 8 keys were ever cut to nightly-next; a cut
waited 9 to 84 min for its tree behind builds nothing read. tree-preflight's superseded step
(scripts/ci/cmux_tui_superseded_push.py) now yields such a run before it claims its key, unless the
TREE_YIELD_SUPERSEDED repository variable is 0. A dev or dogfood build that then finds the tree
missing asks cmux-tui-tree-request.yml for it (pin-cmux-tui.sh wait_for_tree) instead of failing.

Runs the workflow step's own command against real commits, a local bare remote for the branch heads
and a fake GitHub API and CDN. Run: python3 -m unittest tests/test_cmux_tui_tree_yield.py
"""

from __future__ import annotations

import http.server
import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
import unittest

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location("git_fixture_env", os.path.join(ROOT, "tests", "git_fixture_env.py"))
git_fixture_env = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(git_fixture_env)

WORKFLOW = os.path.join(ROOT, ".github", "workflows", "cmux-tui-artifacts.yml")
REPO = "manaflow-ai/cmux"


def stale_step():
    with open(WORKFLOW, encoding="utf-8") as handle:
        steps = yaml.safe_load(handle)["jobs"]["tree-preflight"]["steps"]
    return next(s for s in steps if s.get("id") == "stale")


class Fake:
    """The GitHub REST API and the files.cmux.com CDN: GET/HEAD routes, POSTs logged."""

    def __init__(self):
        self.routes: dict[str, tuple[int, object]] = {}
        self.posts: list[tuple[str, dict]] = []
        self.on_post = None
        fake = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def _answer(self, body_too):
                status, body = fake.routes.get(self.path.split("?")[0], (404, {"message": "Not Found"}))
                data = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                if body_too:
                    self.wfile.write(data)

            def do_GET(self):
                self._answer(True)

            def do_HEAD(self):
                self._answer(False)

            def do_POST(self):
                length = int(self.headers.get("Content-Length") or 0)
                fake.posts.append((self.path, json.loads(self.rfile.read(length) or b"{}")))
                if fake.on_post:
                    fake.on_post()
                self.send_response(204)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.com", *args],
                          check=True, capture_output=True, text=True, env=git_fixture_env.fixture_env()).stdout.strip()


class Fixture:
    """A repository with the key script and inputs, and commits with distinct cmux-tui trees."""

    def __init__(self, tmp):
        self.repo = os.path.join(tmp, "src")
        self.remote = os.path.join(tmp, "remote.git")
        git_fixture_env.init_repo(self.repo)
        git_fixture_env.init_repo(self.remote, "--bare")
        for rel in ("scripts/ci/cmux_tui_tree_key.py", "scripts/ci/cmux_tui_superseded_push.py",
                    "scripts/cmux-next/cmux-tui-tree-inputs.txt", "scripts/cmux-next/pin-cmux-tui.sh"):
            os.makedirs(os.path.dirname(os.path.join(self.repo, rel)), exist_ok=True)
            shutil.copy2(os.path.join(ROOT, rel), os.path.join(self.repo, rel))
        subprocess.run([os.path.join(ROOT, "scripts/cmux-next/tests/lib/tree-inputs-fixture.sh"), self.repo], check=True)
        os.makedirs(os.path.join(self.repo, "cmux-tui"), exist_ok=True)
        self.commits = {}
        for name, content in (("cut", "zero"), ("old", "one"), ("old-same-as-tip", "two"), ("tip", "two"),
                              ("pending", "three")):
            with open(os.path.join(self.repo, "cmux-tui", "src"), "w") as handle:
                handle.write(content)
            git(self.repo, "add", "-A")
            git(self.repo, "commit", "-q", "--allow-empty", "-m", name)
            self.commits[name] = git(self.repo, "rev-parse", "HEAD")
        # feat-cmux-next is at "tip"; "pending" sits on a side ref, as a commit a promotion names.
        git(self.repo, "push", "-q", self.remote, f"{self.commits['tip']}:refs/heads/feat-cmux-next",
            f"{self.commits['cut']}:refs/heads/nightly-next", f"{self.commits['pending']}:refs/heads/side")

    def key(self, name):
        return subprocess.run(["python3", "scripts/ci/cmux_tui_tree_key.py", "--version", "v2", self.commits[name]],
                              cwd=self.repo, check=True, capture_output=True, text=True).stdout.strip()


class YieldTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.fx = Fixture(cls.tmp)
        cls.fake = Fake()

    @classmethod
    def tearDownClass(cls):
        cls.fake.close()
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def setUp(self):
        self.fake.routes = {}
        self.fake.posts = []
        self.promotions([])

    def promotions(self, shas, status="queued"):
        runs = [{"id": 1, "status": status, "display_title": f"Promote nightly-next to {sha}"} for sha in shas]
        runs.append({"id": 2, "status": "in_progress", "display_title": "Nightly macOS build"})
        self.fake.routes[f"/repos/{REPO}/actions/workflows/nightly.yml/runs"] = (200, {"workflow_runs": runs})

    def preflight(self, name, tree_yield="true", ref="refs/heads/feat-cmux-next", attempt="1", remote=None):
        """Runs the stale step's command as tree-preflight does; returns (stale, log)."""
        output = os.path.join(self.tmp, "github-output")
        open(output, "w").close()
        env = git_fixture_env.fixture_env({
            "PATH": os.environ["PATH"], "HOME": self.tmp, "GITHUB_OUTPUT": output, "GITHUB_API_URL": self.fake.url,
            "GITHUB_REPOSITORY": REPO, "GH_TOKEN": "", "GITHUB_RUN_ATTEMPT": attempt,
            "CMUX_TUI_PIN_BASE": f"{self.fake.url}/cmux-tui", "EVENT_NAME": "push", "REF": ref,
            "SHA": self.fx.commits[name], "CMUX_TUI_REF_REMOTE": remote or f"file://{self.fx.remote}"})
        if tree_yield is not None:
            env["TREE_YIELD"] = tree_yield
        result = subprocess.run(["bash", "-e", "-c", stale_step()["run"]], cwd=self.fx.repo, env=env,
                                capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr)
        values = dict(line.split("=", 1) for line in open(output).read().splitlines() if "=" in line)
        return values.get("stale"), result.stdout + result.stderr

    def test_superseded_key_yields(self):
        stale, log = self.preflight("old")
        self.assertEqual(stale, "true", log)
        self.assertIn("tree build yielded", log)
        self.assertIn("TREE_YIELD_SUPERSEDED=0", log)

    def test_tip_builds(self):
        stale, log = self.preflight("tip")
        self.assertEqual(stale, "false", log)

    def test_older_commit_with_the_tips_key_builds(self):
        self.assertEqual(self.fx.key("old-same-as-tip"), self.fx.key("tip"))
        stale, log = self.preflight("old-same-as-tip")
        self.assertEqual(stale, "false", log)
        self.assertIn("the feat-cmux-next tip", log)

    def test_nightly_next_heads_key_builds(self):
        stale, log = self.preflight("cut")
        self.assertEqual(stale, "false", log)

    def test_pending_promotions_key_builds(self):
        self.promotions([self.fx.commits["pending"]])
        stale, log = self.preflight("pending")
        self.assertEqual(stale, "false", log)

    def test_finished_promotion_is_not_pending(self):
        self.promotions([self.fx.commits["pending"]], status="completed")
        stale, log = self.preflight("pending")
        self.assertEqual(stale, "true", log)

    def test_variable_zero_builds_everything(self):
        # The step passes vars.TREE_YIELD_SUPERSEDED != '0': "false" when the variable is 0.
        env_expr = str(stale_step()["env"].get("TREE_YIELD"))
        self.assertEqual(env_expr, "${{ vars.TREE_YIELD_SUPERSEDED != '0' }}")
        for name in ("old", "tip", "cut", "pending"):
            stale, log = self.preflight(name, tree_yield="false")
            self.assertEqual(stale, "false", f"{name}: {log}")

    def test_rerun_builds(self):
        stale, log = self.preflight("old", attempt="2")
        self.assertEqual(stale, "false", log)
        self.assertIn("re-run", log)

    def test_published_tree_is_kept(self):
        self.fake.routes[f"/cmux-tui/tree/{self.fx.key('old')}/completion.json"] = (200, {})
        stale, log = self.preflight("old")
        self.assertEqual(stale, "false", log)

    def test_read_failure_keeps_the_run(self):
        self.fake.routes[f"/repos/{REPO}/actions/workflows/nightly.yml/runs"] = (502, {})
        stale, log = self.preflight("old")
        self.assertEqual(stale, "false", log)
        stale, log = self.preflight("old", remote=f"file://{self.tmp}/missing.git")
        self.assertEqual(stale, "false", log)

    def test_other_branches_keep_their_rules(self):
        stale, log = self.preflight("old", ref="refs/heads/main")
        self.assertEqual(stale, "false", log)


class DogfoodRequestTests(unittest.TestCase):
    """pin-cmux-tui.sh fetch (reload.sh, tagged and dogfood builds) for a commit whose run yielded."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.fx = Fixture(self.tmp)
        self.fake = Fake()
        self.sha = self.fx.commits["pending"]
        git(self.fx.repo, "checkout", "-q", self.sha)
        self.runs_path = f"/repos/{REPO}/actions/workflows/cmux-tui-artifacts.yml/runs"
        self.fake.routes[self.runs_path] = (200, {"total_count": 1, "workflow_runs": [
            {"id": 12, "status": "completed", "conclusion": "success", "head_sha": self.sha,
             "html_url": "https://github.com/o/r/actions/runs/12"}]})
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        with open(os.path.join(self.bin, "gh"), "w") as handle:  # no gh login on this host
            handle.write("#!/bin/sh\nexit 1\n")
        os.chmod(os.path.join(self.bin, "gh"), 0o755)

    def tearDown(self):
        self.fake.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def fetch(self, token, wait=8, extra=None):
        env = git_fixture_env.fixture_env({
            "PATH": f"{self.bin}:{os.environ['PATH']}", "HOME": self.tmp, "GITHUB_REPOSITORY": REPO,
            "GITHUB_API_URL": self.fake.url, "CMUX_TUI_PIN_BASE": f"{self.fake.url}/cmux-tui",
            "CMUX_TUI_TREE_WAIT_SECONDS": str(wait), "CMUX_TUI_TREE_POLL_SECONDS": "1",
            "CMUX_TUI_TREE_RUN_CHECK_SECONDS": "1", "CMUX_TUI_TREE_ACTIVE_WAIT_SECONDS": "0",
            "CMUX_TUI_TREE_RUN_FETCH_SECONDS": "5"})
        if token:
            env["GH_TOKEN"] = token
        env.update(extra or {})
        started = time.monotonic()
        result = subprocess.run(["bash", "scripts/cmux-next/pin-cmux-tui.sh", "fetch"], cwd=self.fx.repo, env=env,
                                capture_output=True, text=True, timeout=120)
        return result.returncode, result.stdout + result.stderr, time.monotonic() - started

    def test_yielded_tree_is_requested_instead_of_failing(self):
        def rerun():  # cmux-tui-tree-request.yml re-runs the commit's run: it reads as active again
            self.fake.routes[self.runs_path] = (200, {"total_count": 1, "workflow_runs": [
                {"id": 12, "status": "queued", "conclusion": None, "head_sha": self.sha, "html_url": "u12"}]})
        self.fake.on_post = rerun
        status, log, took = self.fetch("test-token")
        dispatch = f"/repos/{REPO}/actions/workflows/cmux-tui-tree-request.yml/dispatches"
        self.assertEqual(self.fake.posts, [(dispatch, {"ref": "feat-cmux-next", "inputs": {"commit": self.sha}})], log)
        self.assertIn("asked cmux-tui-tree-request.yml to publish it", log)
        # It waited on for the re-run (here none comes, so the bounded wait ends), never failing fast.
        self.assertNotIn("no cmux-tui artifacts run will publish", log)
        self.assertIn("is not published after", log)
        self.assertNotEqual(status, 0)

    def test_request_once_then_fail_fast_when_the_rerun_never_starts(self):
        status, log, _ = self.fetch("test-token", wait=60)
        self.assertEqual(len(self.fake.posts), 1, log)
        self.assertIn("no cmux-tui artifacts run will publish", log)
        self.assertNotEqual(status, 0)

    def test_without_a_token_it_fails_with_the_request_command(self):
        status, log, _ = self.fetch("", wait=60)
        self.assertEqual(self.fake.posts, [], log)
        self.assertNotEqual(status, 0)
        self.assertIn(f"gh workflow run cmux-tui-tree-request.yml --repo {REPO} --ref feat-cmux-next "
                      f"-f commit={self.sha}", log)

    def test_request_off_with_cmux_tui_tree_request_0(self):
        status, log, _ = self.fetch("test-token", wait=60, extra={"CMUX_TUI_TREE_REQUEST": "0"})
        self.assertEqual(self.fake.posts, [], log)
        self.assertNotEqual(status, 0)


if __name__ == "__main__":
    unittest.main()
