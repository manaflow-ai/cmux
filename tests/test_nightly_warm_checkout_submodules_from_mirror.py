#!/usr/bin/env python3
"""The warm nightly-next checkout reads each submodule from the fleet's git mirror when the mirror holds it.

nightly-next run 45782377330 (1cfdcaf6, job 139782733194) failed in "Checkout build ref (warm nightly-next
builder)": `git submodule update --init --force --depth=1 --recursive` timed out at 600 s on all three tries,
because the Mac fetched ghostty, ghostty-next and homebrew-cmux from github.com. The step already reads cmux
itself from $GLAEDA_GIT_MIRROR_DIR/cmux.git. Now, for each submodule (nested ones too), a verified mirror beside
it ($GLAEDA_GIT_MIRROR_DIR/NAME.git or OWNER/NAME.git, the same checks as cmux.git) that holds the gitlink commit
replaces the github.com URL (url.<file://mirror>.insteadOf, this step's environment only). Any other submodule
still goes to github.com, with the job's token.

The step's own `run:` text from nightly.yml runs against temp mirrors. github.com is reached only through an
HTTPS proxy that records each CONNECT and refuses it, so a fetch from the origin URL is seen and fails fast.

Run: python3 tests/test_nightly_warm_checkout_submodules_from_mirror.py (a few seconds, git only, no network).
"""
from __future__ import annotations

import os
import socketserver
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
WARM_STEP = "Checkout build ref (warm nightly-next builder)"
GH = "https://github.com/manaflow-ai"
# One try, no backoff: the real helper's retries would only slow a failing run down.
RETRY_STUB = "import subprocess, sys\nsys.exit(subprocess.call(sys.argv[sys.argv.index('--') + 1:]))\n"


class Proxy(socketserver.StreamRequestHandler):
    seen: list[str] = []

    def handle(self) -> None:
        line = self.rfile.readline().decode("latin-1").strip()
        Proxy.seen.append(line)
        self.wfile.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")


class WarmCheckoutSubmodulesFromMirrorTest(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.temp = Path(temp.name)
        for folder in ("bin", "home", "runner-temp", "src"):
            (self.temp / folder).mkdir()
        self.proxy = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Proxy)
        Proxy.seen = []
        threading.Thread(target=self.proxy.serve_forever, daemon=True).start()
        self.addCleanup(self.proxy.server_close)
        self.addCleanup(self.proxy.shutdown)
        self.env = git_fixture_env.fixture_env({
            "PATH": f"{self.temp / 'bin'}{os.pathsep}{os.environ['PATH']}", "HOME": str(self.temp / "home"),
            "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
        })
        (self.temp / "bin/curl").write_text("#!/bin/sh\nexit 7\n")
        (self.temp / "bin/curl").chmod(0o755)
        self.fleet_git = self.temp / "fleet/git"
        (self.fleet_git / "manaflow-ai").mkdir(parents=True)
        # zig-pkg sits inside ghostty (a nested submodule); its mirror uses the OWNER/NAME.git layout.
        self.pkg = self.repo("zig-pkg", {"pkg.zig": "one\n"})
        self.pkg = self.repo("zig-pkg", {"pkg.zig": "two\n"})
        self.ghostty = self.repo("ghostty", {"src/main.zig": "ghostty\n"}, subs={"pkg": ("zig-pkg", self.pkg)})
        self.brew = self.repo("homebrew-cmux", {"Formula/cmux.rb": "brew\n"})
        self.sha = self.repo("cmux", {"scripts/ci/git_fetch_retry.py": RETRY_STUB, "README": "cmux\n"},
                             subs={"ghostty": ("ghostty", self.ghostty), "homebrew-cmux": ("homebrew-cmux", self.brew)})
        for name, where in (("cmux", "cmux.git"), ("ghostty", "ghostty.git"), ("homebrew-cmux", "homebrew-cmux.git"),
                            ("zig-pkg", "manaflow-ai/zig-pkg.git")):
            self.mirror(name, where)
        self.ws = self.temp / "actions-runner-1/_work/cmux/cmux"
        self.ws.mkdir(parents=True)

    def git(self, cwd: Path, *args: str) -> str:
        result = subprocess.run(["git", *args], cwd=cwd, env=self.env, capture_output=True, text=True)
        if result.returncode != 0:
            self.fail(f"git {' '.join(args)}: exit {result.returncode}\n{result.stderr}")
        return result.stdout.strip()

    def repo(self, name: str, tree: dict[str, str], subs: dict[str, tuple[str, str]] | None = None) -> str:
        """Commit TREE (and gitlinks to SUBS: path -> (repo name, commit)) in src/NAME; returns the commit."""
        path = self.temp / "src" / name
        if not path.exists():
            git_fixture_env.init_repo(path, "-b", "main", env=self.env)
        for file, text in tree.items():
            (path / file).parent.mkdir(parents=True, exist_ok=True)
            (path / file).write_text(text)
        if subs:
            (path / ".gitmodules").write_text("".join(
                f'[submodule "{sub}"]\n\tpath = {sub}\n\turl = {GH}/{repo}.git\n' for sub, (repo, _) in subs.items()))
        self.git(path, "add", "-A")
        for sub, (_, commit) in (subs or {}).items():
            self.git(path, "update-index", "--add", "--cacheinfo", f"160000,{commit},{sub}")
        self.git(path, "commit", "-qm", f"{name} commit")
        return self.git(path, "rev-parse", "HEAD")

    def mirror(self, name: str, where: str) -> Path:
        target = self.fleet_git / where
        git_fixture_env.clone_repo(self.temp / "src" / name, target, "--mirror", env=self.env)
        (target / "glaeda-verified").write_text("ok\n")
        return target

    def run_warm_step(self) -> subprocess.CompletedProcess:
        warm = next(s for s in yaml.safe_load(WORKFLOW.read_text())["jobs"]["build-nightly-app"]["steps"]
                    if s.get("name") == WARM_STEP)
        script = self.temp / "runner-temp/warm-checkout.sh"
        script.write_text(warm["run"])
        proxy = f"http://127.0.0.1:{self.proxy.server_address[1]}"
        env = {**self.env, "BUILD_SHA": self.sha, "WORKFLOW_SHA": self.sha, "REPO_URL": f"{GH}/cmux",
               "CHECKOUT_MIRROR_WAIT_SECONDS": "1", "CHECKOUT_FETCH_BACKOFF_SECONDS": "0", "FETCH_TOKEN": "test-token",
               "GLAEDA_GIT_MIRROR_TOOL": str(self.temp / "no-mirror-tool"), "GITHUB_WORKSPACE": str(self.ws),
               "RUNNER_TEMP": str(self.temp / "runner-temp"), "GITHUB_REPOSITORY": "manaflow-ai/cmux",
               "GITHUB_SERVER_URL": "https://github.com", "GLAEDA_GIT_MIRROR_DIR": str(self.fleet_git),
               "https_proxy": proxy, "HTTPS_PROXY": proxy, "http_proxy": proxy}
        return subprocess.run(["bash", "-e", str(script)], cwd=self.temp, env=env, capture_output=True, text=True,
                              timeout=120)

    def github_connects(self) -> list[str]:
        return [line for line in Proxy.seen if "github.com" in line]

    def test_submodules_the_mirrors_hold_are_never_fetched_from_github(self) -> None:
        result = self.run_warm_step()
        self.assertEqual(result.returncode, 0, f"{result.stdout}\n{result.stderr}")
        self.assertEqual(self.github_connects(), [], result.stderr)
        self.assertEqual(self.git(self.ws / "ghostty", "rev-parse", "HEAD"), self.ghostty)
        self.assertEqual(self.git(self.ws / "ghostty/pkg", "rev-parse", "HEAD"), self.pkg)
        self.assertEqual((self.ws / "ghostty/pkg/pkg.zig").read_text(), "two\n")
        self.assertEqual(self.git(self.ws / "homebrew-cmux", "rev-parse", "HEAD"), self.brew)
        self.assertIn("checkout-git-fetches: github.com=0", result.stdout)
        # The rewrite lives in the step's environment, never in the kept slot's config.
        self.assertNotIn("insteadof", self.git(self.ws, "config", "--list", "--show-origin").lower())

    def test_a_mirror_that_lacks_the_commit_falls_back_to_github(self) -> None:
        stale = self.fleet_git / "homebrew-cmux.git"
        self.git(stale, "update-ref", "-d", "refs/heads/main")
        self.git(stale, "-c", "gc.reflogExpire=now", "gc", "-q", "--prune=now")
        result = self.run_warm_step()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.github_connects(), result.stderr)
        self.assertEqual(self.git(self.ws / "ghostty", "rev-parse", "HEAD"), self.ghostty)

    def test_an_unverified_mirror_is_not_read(self) -> None:
        (self.fleet_git / "manaflow-ai/zig-pkg.git/glaeda-verified").unlink()
        result = self.run_warm_step()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.github_connects(), result.stderr)


if __name__ == "__main__":
    unittest.main()
