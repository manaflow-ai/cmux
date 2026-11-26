#!/usr/bin/env python3
"""The warm nightly-next checkout reads GitHub with the job's token, and not at all when it already has the commit.

Nightly macOS build 45744507889 (nightly-next 6fde033d, attempts 1 and 2, jobs 139658763993 and
139665520003) and 45756842046 (32b3d62a, 2026-11-26 04:47Z) lost `nightly-next-one` at
"Checkout build ref (warm nightly-next builder)": its fetch of the build commit from github.com ran with
no credential and GitHub answered "The requested URL returned error: 403" on every try (429 before it).
Every later step then failed with exit 127, so no NIGHTLY published for hours.

The step now:
- skips the fetch when the build commit is already readable (the kept clone, or the mini's mirror the
  slot borrows), so a mirror that has the commit needs no GitHub read at all;
- otherwise sends github.token as an Authorization header scoped to this repository's URL, passed through
  GIT_CONFIG_* environment entries so the header never appears in a command line git_fetch_retry.py logs,
  and masked in the job log.

Run it yourself after changing the warm checkout step: python3 tests/test_nightly_warm_checkout_auth.py
(a few seconds, git only, no network).
"""
from __future__ import annotations

import base64
import os
import shutil
import subprocess
import tempfile
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
WARM_STEP = "Checkout build ref (warm nightly-next builder)"
TOKEN = "ghs_testtokenvalue0123456789"


def real_git() -> str:
    for folder in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(folder or ".") / "git"
        if candidate.is_file() and os.access(candidate, os.X_OK):
            with candidate.open("rb") as handle:
                if handle.read(2) != b"#!":
                    return str(candidate)
    return shutil.which("git") or "git"


REAL_GIT = real_git()

# Ahead of git on PATH: at each top-level `git fetch`, log its argv and the GIT_CONFIG_* entries it sees.
GIT_SHIM = """#!/bin/sh
for arg in "$@"; do
  if [ "$arg" = fetch ]; then
    {
      printf 'argv:'; printf ' %s' "$@"; echo
      i=0
      while [ "$i" -lt "${GIT_CONFIG_COUNT:-0}" ]; do
        eval "k=\\${GIT_CONFIG_KEY_$i}; v=\\${GIT_CONFIG_VALUE_$i}"
        echo "config: $k=$v"
        i=$((i + 1))
      done
      echo end
    } >> "$SHIM_LOG"
    break
  fi
done
exec "$SHIM_REAL_GIT" "$@"
"""


def warm_step() -> dict:
    return next(s for s in JOBS["build-nightly-app"]["steps"] if s.get("name") == WARM_STEP)


class WarmCheckoutAuthTest(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.temp = Path(temp.name)
        for folder in ("bin", "home", "runner-temp"):
            (self.temp / folder).mkdir()
        self.env = git_fixture_env.fixture_env({
            "PATH": f"{self.temp / 'bin'}{os.pathsep}{os.environ['PATH']}", "HOME": str(self.temp / "home"),
            "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
        })
        (self.temp / "bin/curl").write_text("#!/bin/sh\nexit 7\n")
        (self.temp / "bin/curl").chmod(0o755)
        self.origin = self.temp / "origin"
        git_fixture_env.init_repo(self.origin, "-b", "main", env=self.env)
        self.git(self.origin, "config", "uploadpack.allowAnySHA1InWant", "true")
        self.sha = self.commit({"scripts/ci/git_fetch_retry.py": (ROOT / "scripts/ci/git_fetch_retry.py").read_text(),
                                "README": "one\n"}, "first")
        self.fleet_git = self.temp / "fleet/git"
        self.fleet_git.mkdir(parents=True)
        self.ws = self.temp / "actions-runner-1/_work/cmux/cmux"
        self.ws.mkdir(parents=True)
        self.log = self.temp / "fetches.log"

    def git(self, cwd: Path, *args: str) -> str:
        result = subprocess.run([REAL_GIT, *args], cwd=cwd, env=self.env, capture_output=True, text=True)
        if result.returncode != 0:
            self.fail(f"git {' '.join(args)}: exit {result.returncode}\n{result.stderr}")
        return result.stdout.strip()

    def commit(self, tree: dict[str, str], message: str) -> str:
        for name, text in tree.items():
            path = self.origin / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.git(self.origin, "add", "-A")
        self.git(self.origin, "commit", "-qm", message)
        return self.git(self.origin, "rev-parse", "HEAD")

    def mirror_origin(self) -> None:
        mirror = self.fleet_git / "cmux.git"
        git_fixture_env.clone_repo(self.origin, mirror, "--mirror", env=self.env)
        (mirror / "glaeda-verified").write_text("ok\n")

    def run_step(self, token: str = TOKEN) -> subprocess.CompletedProcess:
        script = self.temp / "runner-temp/warm-checkout.sh"
        script.write_text(warm_step()["run"])
        shim = self.temp / "bin/git"
        shim.write_text(GIT_SHIM)
        shim.chmod(0o755)
        env = {**self.env, "BUILD_SHA": self.sha, "WORKFLOW_SHA": self.sha, "REPO_URL": self.origin.as_uri(),
               "GITHUB_WORKSPACE": str(self.ws), "RUNNER_TEMP": str(self.temp / "runner-temp"),
               "GITHUB_REPOSITORY": "o/r", "GLAEDA_GIT_MIRROR_DIR": str(self.fleet_git),
               "FETCH_TOKEN": token, "SHIM_REAL_GIT": REAL_GIT, "SHIM_LOG": str(self.log)}
        result = subprocess.run(["bash", "-e", str(script)], cwd=self.temp, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, f"the warm checkout step failed\n{result.stdout}\n{result.stderr}")
        (self.temp / "bin/git").unlink()
        self.assertEqual(self.git(self.ws, "rev-parse", "HEAD"), self.sha)
        return result

    def fetches(self) -> list[str]:
        return [line for line in (self.log.read_text().splitlines() if self.log.exists() else [])
                if line.startswith("argv:")]

    def test_the_step_passes_the_jobs_token(self) -> None:
        self.assertEqual(warm_step()["env"].get("FETCH_TOKEN"), "${{ github.token }}")

    def test_the_fetch_sends_the_token_as_a_header_scoped_to_the_repository(self) -> None:
        result = self.run_step()
        log = self.log.read_text()
        header = base64.b64encode(f"x-access-token:{TOKEN}".encode()).decode()
        self.assertIn(f"config: http.{self.origin.as_uri()}.extraheader=AUTHORIZATION: basic {header}", log)
        self.assertIn(f"::add-mask::{header}", result.stdout)

    def test_the_token_never_appears_in_a_command_line(self) -> None:
        self.run_step()
        header = base64.b64encode(f"x-access-token:{TOKEN}".encode()).decode()
        self.assertTrue(self.fetches(), "the step ran no fetch")
        for line in self.fetches():
            self.assertNotIn(TOKEN, line)
            self.assertNotIn(header, line)

    def test_no_token_fetches_without_a_header(self) -> None:
        self.run_step(token="")
        self.assertNotIn("extraheader", self.log.read_text())

    def test_a_commit_the_borrowed_mirror_has_is_not_fetched(self) -> None:
        self.mirror_origin()
        result = self.run_step()
        self.assertEqual(self.fetches(), [], "the slot read GitHub for a commit its mirror already holds")
        self.assertIn("no fetch", result.stdout)

    def test_a_commit_the_mirror_lacks_is_fetched(self) -> None:
        self.mirror_origin()
        self.sha = self.commit({"README": "two\n"}, "newer than the mirror")
        self.run_step()
        self.assertEqual(len(self.fetches()), 1)


if __name__ == "__main__":
    unittest.main()
