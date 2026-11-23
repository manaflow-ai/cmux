#!/usr/bin/env python3
"""scripts/ci/ci_pool_tokens.py: a job's GitHub API calls go out on the CI pool Apps first.

CI_POOL_FIRST (2026-11-23): 00:30-03:30Z about 290 of 322 risk tier runs, 12 hot verify hand-offs and 31 cmux-tui
artifacts jobs ended red on "API rate limit": every job's github.token shares the repository installation's hour.
The CI pool Apps (leo-workspace tools/gh-app-new ci-create; vars.CMUX_CI_POOL_APPS, secrets.CMUX_CI_POOL_KEYS) each
have an installation hour of their own. These tests mint against a fake GitHub with a throwaway key, and check that
the three workflows read the pool first and keep github.token as the last fallback.
"""

from __future__ import annotations

import http.server
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "ci_pool_tokens.py"
WORKFLOWS = ROOT / ".github" / "workflows"


class FakeGitHub(http.server.BaseHTTPRequestHandler):
    refuse: set[int] = set()
    seen: list[tuple[str, dict, str]] = []

    def do_POST(self) -> None:  # noqa: N802
        n = int(self.path.split("/")[3])
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.seen.append((self.path, body, self.headers.get("Authorization", "")))
        if n in self.refuse:
            self.send_response(500)
            self.end_headers()
            return
        out = json.dumps({"token": f"ghs_pool{n}token", "expires_at": "2099-01-01T00:00:00Z"}).encode()
        self.send_response(201)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *_args) -> None:
        pass


@unittest.skipUnless(shutil.which("openssl"), "needs openssl")
class Mint(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = tempfile.mkdtemp()
        cls.keys = []
        for i in range(2):
            out = subprocess.run(["openssl", "genrsa", "2048"], capture_output=True, text=True, check=True).stdout
            cls.keys.append(out)
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeGitHub)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def setUp(self) -> None:
        FakeGitHub.refuse = set()
        FakeGitHub.seen = []

    def run_script(self, **env: str) -> tuple[subprocess.CompletedProcess, str]:
        ghenv = Path(tempfile.mkstemp(dir=self.tmp)[1])
        full = {"PATH": os.environ["PATH"], "GITHUB_ENV": str(ghenv), "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                "GITHUB_API_URL": f"http://127.0.0.1:{self.server.server_address[1]}", "RUNNER_TEMP": self.tmp,
                **env}
        done = subprocess.run([sys.executable, str(SCRIPT)], env=full, capture_output=True, text=True, timeout=60)
        return done, ghenv.read_text()

    def apps(self, n: int = 2) -> str:
        return json.dumps([{"name": f"ci-pool-{i + 1}", "app_id": 100 + i, "installation_id": i + 1}
                           for i in range(n)])

    def test_no_pool_writes_nothing_and_never_fails(self) -> None:
        done, written = self.run_script()
        self.assertEqual(done.returncode, 0)
        self.assertEqual(written, "")
        self.assertIn("keeps github.token", done.stdout)

    def test_a_key_count_that_differs_from_the_apps_writes_nothing(self) -> None:
        done, written = self.run_script(CI_POOL_APPS=self.apps(2), CI_POOL_KEYS=self.keys[0])
        self.assertEqual((done.returncode, written), (0, ""))

    def test_each_pool_is_minted_masked_narrowed_and_spread_by_run(self) -> None:
        done, written = self.run_script(CI_POOL_APPS=self.apps(2), CI_POOL_KEYS="\n".join(self.keys),
                                        CI_POOL_PERMISSIONS='{"actions":"write"}', GITHUB_RUN_ID="7")
        self.assertEqual(done.returncode, 0, done)
        # run 7 of 2 pools starts on the second: runs spread over the pools
        self.assertIn("CI_POOL_GH_TOKEN=ghs_pool2token\n", written)
        self.assertIn("CI_POOL_GH_TOKEN_SPARES=ghs_pool1token\n", written)
        self.assertIn("::add-mask::ghs_pool1token", done.stdout)
        self.assertIn("::add-mask::ghs_pool2token", done.stdout)
        self.assertNotIn("PRIVATE KEY", done.stdout + done.stderr)
        for _path, body, auth in FakeGitHub.seen:
            self.assertEqual(body, {"repositories": ["cmux"], "permissions": {"actions": "write"}})
            self.assertTrue(auth.startswith("Bearer ") and auth.count(".") == 2)
        # the key files the JWT signing wrote are gone
        left = [p for p in Path(self.tmp).iterdir() if p.is_file() and "PRIVATE KEY" in p.read_text()]
        self.assertEqual(left, [])

    def test_a_refused_pool_leaves_the_others(self) -> None:
        FakeGitHub.refuse = {1}
        done, written = self.run_script(CI_POOL_APPS=self.apps(2), CI_POOL_KEYS="\n".join(self.keys),
                                        GITHUB_RUN_ID="0")
        self.assertEqual(done.returncode, 0, done)
        self.assertIn("CI_POOL_GH_TOKEN=ghs_pool2token\n", written)
        self.assertIn("not minted: ci-pool-1: HTTP 500", done.stdout)


def steps(workflow: str, job: str) -> list[dict]:
    return yaml.safe_load((WORKFLOWS / workflow).read_text())["jobs"][job]["steps"]


def step(workflow: str, job: str, name: str) -> dict:
    return next(s for s in steps(workflow, job) if s.get("name") == name)


class Wiring(unittest.TestCase):
    """Each wired step reads the pool first and github.token last; the mint can never fail its job."""

    WIRED = [
        ("risk-tier.yml", "evidence", "Grade the pull request"),
        ("cmux-next-hot-verify.yml", "hand-off", "Dispatch the look"),
        ("cmux-tui-artifacts.yml", "darwin-fallback-plan", "Find the macOS targets the build left without artifacts"),
        ("cmux-tui-artifacts.yml", "rerun-deferred-commits", "Re-run the runs that deferred to this tree"),
        ("cmux-tui-artifacts.yml", "sweep-pending-tree-notify", "Start the cmux-next tree jobs a refused tree notify left"),
        ("cmux-tui-artifacts.yml", "notify-unpublished-tree", "Report the unpublished tree to the cmux-next runs that wait for it"),
        ("cmux-tui-artifacts.yml", "notify-unpublished-tree", "Hand the key to a run that deferred to this one"),
    ]

    def test_every_wired_step_takes_the_pool_first_after_a_mint_that_cannot_fail(self) -> None:
        for workflow, job, name in self.WIRED:
            with self.subTest(job=job, step=name):
                all_steps = steps(workflow, job)
                names = [s.get("name") for s in all_steps]
                mint = all_steps[names.index("Mint the CI pool's tokens")]
                self.assertLess(names.index("Mint the CI pool's tokens"), names.index(name))
                self.assertTrue(mint.get("continue-on-error"))
                self.assertEqual(mint["env"]["CI_POOL_APPS"], "${{ vars.CMUX_CI_POOL_APPS }}")
                self.assertEqual(mint["env"]["CI_POOL_KEYS"], "${{ secrets.CMUX_CI_POOL_KEYS }}")
                json.loads(mint["env"]["CI_POOL_PERMISSIONS"])
                token = step(workflow, job, name)["env"]["GH_TOKEN"]
                self.assertTrue(token.startswith("${{ env.CI_POOL_GH_TOKEN ||"), token)
                self.assertTrue(token.endswith("github.token }}"), token)

    def test_shell_gh_steps_rotate_every_pool_then_github_token(self) -> None:
        for workflow, job, name in self.WIRED[:3]:
            with self.subTest(job=job):
                env = step(workflow, job, name)["env"]
                self.assertEqual(env["GH_TOKEN_SPARES"], "${{ env.CI_POOL_GH_TOKEN_SPARES }} ${{ github.token }}")
                runs = " ".join(str(s.get("run", "")) for s in steps(workflow, job))
                self.assertIn("gh_budget_wait.sh --install", runs)

    def test_the_risk_label_stays_on_github_token(self) -> None:
        # A label an App adds starts every `labeled` workflow again; one github.token adds does not.
        self.assertEqual(step("risk-tier.yml", "evidence", "Set the risk label")["env"]["GH_TOKEN"],
                         "${{ github.token }}")

    def test_risk_tier_runs_only_the_bases_scripts(self) -> None:
        checkout = steps("risk-tier.yml", "evidence")[0]
        self.assertEqual(checkout["with"]["ref"], "${{ github.workflow_sha }}")
        paths = set(checkout["with"]["sparse-checkout"].split())
        self.assertEqual(paths, {"scripts/ci/risk_tier.py", "scripts/ci/ci_pool_tokens.py",
                                 "scripts/ci/gh_budget_wait.sh"})
        self.assertFalse(re.search(r"head\.(sha|ref)", json.dumps(checkout)))


if __name__ == "__main__":
    unittest.main()
