#!/usr/bin/env python3
"""Every git read a nightly job makes on a self-hosted Mac carries the job's token, exactly once.

The NIGHTLY Macs get HTTP 403 from github.com on anonymous requests while authenticated ones succeed. Every
actions/checkout in .github/workflows/nightly.yml runs with persist-credentials: false, so two kinds of git read
went out with no credential:

- actions/checkout's own clean of a reused workspace (`git reset --hard HEAD`) runs before it sets up auth. On a
  partial clone another job left there, the reset lazily fetches missing blobs from the promisor remote:
  "fatal: unable to access 'https://github.com/manaflow-ai/cmux/': The requested URL returned error: 403",
  "could not fetch ... from promisor remote" (runs 45771452504, 45768118688, 45765712386, 45771096425), and the
  whole workspace is deleted and cloned again.
- every `git fetch` a step runs after the checkout: resolve-cmux-tui-client-commit.sh's deepen failed 5 of 5
  tries and lost resolve-nightly-cmux-tui-client (run 45771096425).

The step "Give git this job's token" (anchor github-token-for-git) runs on a Mac before each job's first
checkout and writes GIT_CONFIG_* entries to GITHUB_ENV: an empty http.<server>/.extraheader (which clears any
header a checkout left in .git/config) and then the job's token as one Authorization header, masked. Two
Authorization headers make GitHub answer 400, so the test counts them. A step that sets its own GIT_CONFIG_COUNT
(a push with an app token) still sends only its own.

build-nightly-app and nightly-next-one are left out until the warm checkout step's own token header (cmux#57899)
reads these entries: that step appends a header, and appended to these it would be a second one.

Run: python3 tests/test_nightly_git_token_env.py (a few seconds, git and a local HTTP server, no network).
"""
from __future__ import annotations

import base64
import http.server
import os
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

import yaml
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/nightly.yml"
JOBS = yaml.safe_load(WORKFLOW.read_text())["jobs"]
STEP = "Give git this job's token (self-hosted Macs get 403 on anonymous reads)"
# Their warm checkout step appends its own header (cmux#57899); see the docstring.
NOT_YET = {"build-nightly-app", "nightly-next-one"}
TOKEN = "ghs_testtokenvalue0123456789"
OTHER = "ghs_apptokenforapush000000000"


def is_checkout(step: dict) -> bool:
    return str(step.get("uses", "")).startswith("actions/checkout@")


def the_step() -> dict:
    for job in JOBS.values():
        for step in job.get("steps") or []:
            if step.get("name") == STEP:
                return step
    raise AssertionError(f"no step named {STEP!r} in {WORKFLOW}")


class Recorder(http.server.BaseHTTPRequestHandler):
    seen: list[list[str]] = []

    def do_GET(self) -> None:  # noqa: N802
        Recorder.seen.append(self.headers.get_all("Authorization") or [])
        self.send_response(403)
        self.send_header("Content-Length", "0")
        self.end_headers()

    do_POST = do_GET  # noqa: N815

    def log_message(self, *args) -> None:
        pass


class WorkflowWiringTest(unittest.TestCase):
    def test_every_job_with_a_checkout_gives_git_the_token_before_it(self) -> None:
        missing = []
        for name, job in JOBS.items():
            steps = job.get("steps") or []
            first = next((i for i, step in enumerate(steps) if is_checkout(step)), None)
            if first is None or name in NOT_YET:
                continue
            if not any(step.get("name") == STEP for step in steps[:first]):
                missing.append(name)
        self.assertEqual(missing, [], "these jobs run actions/checkout (and git) with no credential on a Mac")

    def test_the_step_runs_on_macs_with_the_jobs_token(self) -> None:
        step = the_step()
        self.assertEqual(step.get("if"), "runner.os == 'macOS'")
        self.assertEqual(step["env"].get("FETCH_TOKEN"), "${{ github.token }}")


class HeaderTest(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.temp = Path(temp.name)
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Recorder)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        Recorder.seen = []
        (self.temp / "home").mkdir()
        self.env = git_fixture_env.fixture_env({
            "PATH": os.environ["PATH"], "HOME": str(self.temp / "home"), "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0", "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
        })

    def git(self, cwd: Path, *args: str, env: dict | None = None, check: bool = True) -> subprocess.CompletedProcess:
        result = subprocess.run(["git", *args], cwd=cwd, env=env or self.env, capture_output=True, text=True)
        if check and result.returncode != 0:
            self.fail(f"git {' '.join(args)}: exit {result.returncode}\n{result.stderr}")
        return result

    def job_env(self) -> dict[str, str]:
        """The environment a later step sees after the token step ran."""
        github_env = self.temp / "github_env"
        github_env.write_text("")
        result = subprocess.run(["bash", "-e", "-c", the_step()["run"]], cwd=self.temp, capture_output=True, text=True,
                                env={**self.env, "FETCH_TOKEN": TOKEN, "GITHUB_ENV": str(github_env),
                                     "GITHUB_SERVER_URL": self.url})
        self.assertEqual(result.returncode, 0, result.stderr)
        header = base64.b64encode(f"x-access-token:{TOKEN}".encode()).decode()
        self.assertIn(f"::add-mask::{header}", result.stdout)
        self.assertNotIn(TOKEN, github_env.read_text())
        env = dict(self.env)
        for line in github_env.read_text().splitlines():
            key, _, value = line.partition("=")
            env[key] = value
        return env

    def expected(self, token: str = TOKEN) -> list[str]:
        return ["basic " + base64.b64encode(f"x-access-token:{token}".encode()).decode()]

    def headers_sent(self) -> list[list[str]]:
        self.assertTrue(Recorder.seen, "git made no request")
        return [[h.split(" ", 1)[0].lower() + " " + h.split(" ", 1)[1] for h in seen] for seen in Recorder.seen]

    def test_a_fetch_sends_the_token_once(self) -> None:
        repo = self.temp / "repo"
        git_fixture_env.init_repo(repo, env=self.env)
        self.git(repo, "ls-remote", f"{self.url}/o/r", env=self.job_env(), check=False)
        for seen in self.headers_sent():
            self.assertEqual(seen, self.expected())

    def test_a_header_actions_checkout_left_is_replaced_not_doubled(self) -> None:
        repo = self.temp / "repo"
        git_fixture_env.init_repo(repo, env=self.env)
        self.git(repo, "config", "--local", f"http.{self.url}/.extraheader", f"AUTHORIZATION: {self.expected()[0]}")
        self.git(repo, "ls-remote", f"{self.url}/o/r", env=self.job_env(), check=False)
        for seen in self.headers_sent():
            self.assertEqual(seen, self.expected())

    def test_the_cleans_lazy_promisor_fetch_carries_the_token(self) -> None:
        origin = self.temp / "origin"
        git_fixture_env.init_repo(origin, "-b", "main", env=self.env)
        self.git(origin, "config", "uploadpack.allowFilter", "true")
        (origin / "README").write_text("one\n")
        self.git(origin, "add", "-A")
        self.git(origin, "commit", "-qm", "first")
        work = self.temp / "work"
        git_fixture_env.clone_repo(origin.as_uri(), work, "--filter=blob:none", "--no-checkout", env=self.env)
        self.git(work, "remote", "set-url", "origin", f"{self.url}/o/r")
        # What actions/checkout runs on a reused workspace before it configures any credential.
        self.git(work, "reset", "--hard", "HEAD", env=self.job_env(), check=False)
        for seen in self.headers_sent():
            self.assertEqual(seen, self.expected())

    def test_a_step_with_its_own_credential_sends_only_its_own(self) -> None:
        repo = self.temp / "repo"
        git_fixture_env.init_repo(repo, env=self.env)
        env = {**self.job_env(), "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": f"http.{self.url}/.extraheader",
               "GIT_CONFIG_VALUE_0": f"AUTHORIZATION: {self.expected(OTHER)[0]}"}
        self.git(repo, "ls-remote", f"{self.url}/o/r", env=env, check=False)
        for seen in self.headers_sent():
            self.assertEqual(seen, self.expected(OTHER))


if __name__ == "__main__":
    unittest.main()
