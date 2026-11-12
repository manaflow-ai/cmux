#!/usr/bin/env python3
"""The git fixture helpers never write into a repository or config file the caller's environment points at.

A test run from inside a git hook (pre-commit, pre-push) inherits GIT_DIR, GIT_INDEX_FILE and friends; a caller can
also export GIT_CONFIG, GIT_CONFIG_GLOBAL, GIT_CONFIG_SYSTEM or GIT_CONFIG_COUNT/KEY_*/VALUE_* pairs. At 14947ada
(cmux#41195) tests/git_fixture_env.py and scripts/cmux-next/tests/lib/git-fixture.sh passed them all through:
`git init` with GIT_DIR set re-initialised the caller's repository, `git -C fixture config` wrote the GIT_CONFIG
file, and a fixture commit landed in the caller's repository. Each case here points every one of them at a decoy,
runs a fixture through each helper (init, the opt-out write, a commit, a clone) and checks that every decoy is
byte for byte what it was and that the fixture repository got the commit and the opt-out.

  python3 tests/test_git_fixture_redirects.py
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "tests" / "git_fixture_env.py"
LIB = ROOT / "scripts" / "cmux-next" / "tests" / "lib" / "git-fixture.sh"

# Runs in a child whose env holds the decoys: load the module, then build a fixture three ways (init_repo, a plain
# subprocess git with the inherited env, fixture_env for an explicit env) and clone it. argv: module, fixture dir.
PYTHON_FIXTURE = """
import importlib.util, os, subprocess, sys
spec = importlib.util.spec_from_file_location("git_fixture_env", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
work = sys.argv[2]
repo = os.path.join(work, "repo")
module.init_repo(repo, "-b", "main")
ident = ["-c", "user.name=t", "-c", "user.email=t@example.invalid"]
subprocess.run(["git", "-C", repo, *ident, "commit", "-q", "--allow-empty", "-m", "inherited env"], check=True)
subprocess.run(["git", "-C", repo, *ident, "commit", "-q", "--allow-empty", "-m", "fixture_env"], check=True,
               env=module.fixture_env(dict(os.environ, **{"GIT_DIR": os.environ.get("DECOY_GIT_DIR", "")})))
module.clone_repo(repo, os.path.join(work, "clone"))
print(sorted(name for name in module.REPO_REDIRECTS if name in os.environ))
"""

SHELL_FIXTURE = """
set -euo pipefail
source "$1"
work=$2
git_fixture_init -b main "$work/repo"
git_q -C "$work/repo" commit -q --allow-empty -m "inherited env"
git_fixture_clone "$work/repo" "$work/clone"
git_fixture_init --bare "$work/bare.git"
"""


def fixture_module():
    """tests/git_fixture_env.py, loaded by path (suites run with python3 -I) when a read first needs it."""
    spec = importlib.util.spec_from_file_location("git_fixture_env", MODULE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def digest(path: Path) -> str:
    """A hash of every file under path (names and bytes), or of the file itself."""
    if path.is_file():
        return hashlib.sha256(path.read_bytes()).hexdigest()
    h = hashlib.sha256()
    for item in sorted(p for p in path.rglob("*") if p.is_file()):
        h.update(str(item.relative_to(path)).encode() + b"\0" + item.read_bytes())
    return h.hexdigest()


class DecoyEnvironment(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="git-fixture-redirects-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.tmp)], check=False)
        base = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        base.update(HOME=str(self.tmp / "home"), TMPDIR=str(self.tmp / "tmpdir"))
        self.base = base
        (self.tmp / "home").mkdir()
        (self.tmp / "tmpdir").mkdir()
        # A real repository with a commit, an index and a config: what a hook's GIT_DIR names.
        self.decoy = self.tmp / "decoy"
        run = dict(cwd=self.tmp, env=base, check=True, capture_output=True)
        subprocess.run(["git", "init", "-q", "-b", "main", str(self.decoy)], **run)
        (self.decoy / "file").write_text("decoy\n")
        subprocess.run(["git", "-C", str(self.decoy), "add", "file"], **run)
        subprocess.run(["git", "-C", str(self.decoy), "-c", "user.name=d", "-c", "user.email=d@example.invalid",
                        "commit", "-q", "-m", "decoy"], **run)
        self.files = {name: self.tmp / name for name in ("decoy-config", "decoy-global", "decoy-system")}
        for name, path in self.files.items():
            path.write_text(f"[decoy]\n\tname = {name}\n")
        self.env = dict(
            base,
            GIT_DIR=str(self.decoy / ".git"),
            DECOY_GIT_DIR=str(self.decoy / ".git"),
            GIT_WORK_TREE=str(self.decoy),
            GIT_COMMON_DIR=str(self.decoy / ".git"),
            GIT_INDEX_FILE=str(self.decoy / ".git" / "index"),
            GIT_OBJECT_DIRECTORY=str(self.decoy / ".git" / "objects"),
            GIT_CONFIG=str(self.files["decoy-config"]),
            GIT_CONFIG_GLOBAL=str(self.files["decoy-global"]),
            GIT_CONFIG_SYSTEM=str(self.files["decoy-system"]),
            GIT_CONFIG_COUNT="1",
            GIT_CONFIG_KEY_0="decoy.pair",
            GIT_CONFIG_VALUE_0="inherited",
        )
        self.before = {"decoy repository": digest(self.decoy)}
        self.before.update({name: digest(path) for name, path in self.files.items()})
        self.work = self.tmp / "work"
        self.work.mkdir()

    def assertDecoysUntouched(self, done: subprocess.CompletedProcess[str]) -> None:
        after = {"decoy repository": digest(self.decoy)}
        after.update({name: digest(path) for name, path in self.files.items()})
        changed = sorted(name for name in self.before if after[name] != self.before[name])
        self.assertEqual(changed, [], f"the fixture wrote into a decoy:\n{done.stdout}\n{done.stderr}")

    def assertFixtureRepo(self, path: Path, commits: int) -> None:
        # Read the fixture through the helper's own fixture_env: this process's env without git's redirects (GIT_DIR,
        # GIT_WORK_TREE, GIT_INDEX_FILE, GIT_CONFIG, ...) and with the config isolation kept. A copy of os.environ kept
        # an inherited GIT_DIR (a run from a hook), and both reads went to that repository (review of hq#9676 F3).
        env = fixture_module().fixture_env(dict(os.environ))
        count = subprocess.run(["git", "-C", str(path), "rev-list", "--count", "HEAD"], env=env,
                               capture_output=True, text=True)
        self.assertEqual(count.stdout.strip(), str(commits), count.stderr)
        local = subprocess.run(["git", "-C", str(path), "config", "--local", "--get", "maintenance.auto"], env=env,
                               capture_output=True, text=True)
        self.assertEqual(local.stdout.strip(), "false", "the opt-out is not in the fixture's own config")

    def test_the_assertions_read_the_fixture_under_an_inherited_git_dir(self):
        """Review of hq#9676 F3, ported: this process's own GIT_DIR (a test run from a hook) must not move
        assertFixtureRepo onto another repository. GIT_DIR names an empty repository here, so reading it fails."""
        done = subprocess.run(["bash", "-c", 'set -euo pipefail; source "$1"; git_fixture_init "$2/empty"; '
                               'git_fixture_init "$2/repo"; git_q -C "$2/repo" commit -q --allow-empty -m one',
                               "_", str(LIB), str(self.work)],
                              env=self.base, cwd=self.tmp, capture_output=True, text=True, timeout=120,
                              stdin=subprocess.DEVNULL)
        self.assertEqual(done.returncode, 0, done.stderr)
        with mock.patch.dict(os.environ, {"GIT_DIR": str(self.work / "empty" / ".git")}):
            self.assertFixtureRepo(self.work / "repo", 1)

    def test_python_helper_with_every_redirect_pointing_at_a_decoy(self):
        done = subprocess.run([sys.executable, "-I", "-c", PYTHON_FIXTURE, str(MODULE), str(self.work)],
                              env=self.env, cwd=self.tmp, capture_output=True, text=True, timeout=120,
                              stdin=subprocess.DEVNULL)
        self.assertDecoysUntouched(done)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.strip(), "[]", "a redirect stayed in os.environ after the import")
        self.assertFixtureRepo(self.work / "repo", 2)
        self.assertFixtureRepo(self.work / "clone", 2)

    def test_shell_helper_with_every_redirect_pointing_at_a_decoy(self):
        done = subprocess.run(["bash", "-c", SHELL_FIXTURE, "_", str(LIB), str(self.work)], env=self.env,
                              cwd=self.tmp, capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
        self.assertDecoysUntouched(done)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertFixtureRepo(self.work / "repo", 1)
        self.assertFixtureRepo(self.work / "clone", 1)

    def test_each_config_redirect_alone(self):
        """GIT_CONFIG, GIT_CONFIG_GLOBAL, GIT_CONFIG_SYSTEM and a -c pair, one at a time: init and clone write the opt-out
        into the fixture repository's own config, and the file the variable names stays untouched."""
        base = {key: value for key, value in self.env.items()
                if key in ("PATH", "HOME", "TMPDIR", "LANG", "LC_ALL")}
        single = {
            "GIT_CONFIG": {"GIT_CONFIG": str(self.files["decoy-config"])},
            "GIT_CONFIG_GLOBAL": {"GIT_CONFIG_GLOBAL": str(self.files["decoy-global"])},
            "GIT_CONFIG_SYSTEM": {"GIT_CONFIG_SYSTEM": str(self.files["decoy-system"])},
            "GIT_CONFIG_COUNT pair": {"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "include.path",
                                      "GIT_CONFIG_VALUE_0": str(self.files["decoy-config"])},
        }
        for name, extra in single.items():
            for helper in ("python", "shell"):
                with self.subTest(variable=name, helper=helper):
                    work = self.tmp / f"one-{helper}-{name.split()[0]}"
                    work.mkdir()
                    env = dict(base, **extra)
                    if helper == "python":
                        script = ("import importlib.util, sys\n"
                                  "spec = importlib.util.spec_from_file_location('g', sys.argv[1])\n"
                                  "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n"
                                  "m.init_repo(sys.argv[2] + '/repo')\n"
                                  "m.clone_repo(sys.argv[2] + '/repo', sys.argv[2] + '/clone')\n")
                        argv = [sys.executable, "-I", "-c", script, str(MODULE), str(work)]
                    else:
                        argv = ["bash", "-c", 'set -euo pipefail; source "$1"; git_fixture_init "$2/repo"; '
                                'git_fixture_clone "$2/repo" "$2/clone"', "_",
                                str(LIB), str(work)]
                    # Each case starts from the decoys as they are now, so one case's write does not fail the next.
                    self.before = {"decoy repository": digest(self.decoy)}
                    self.before.update({key: digest(path) for key, path in self.files.items()})
                    done = subprocess.run(argv, env=env, cwd=self.tmp, capture_output=True, text=True,
                                          timeout=120, stdin=subprocess.DEVNULL)
                    self.assertDecoysUntouched(done)
                    self.assertEqual(done.returncode, 0, done.stderr)
                    for made in ("repo", "clone"):
                        local = (work / made / ".git" / "config").read_text()
                        self.assertIn("auto = false", local, f"the opt-out did not reach the {made}'s own config")
                        self.assertNotIn("decoy", local)

    def test_write_env_drops_every_redirect_and_pair(self):
        script = ("import importlib.util, json, os, sys\n"
                  "spec = importlib.util.spec_from_file_location('g', sys.argv[1])\n"
                  "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)\n"
                  "print(json.dumps(m.write_env(json.loads(sys.argv[2]))))\n")
        done = subprocess.run([sys.executable, "-I", "-c", script, str(MODULE), json.dumps(self.env)], env=self.env,
                              cwd=self.tmp, capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
        self.assertEqual(done.returncode, 0, done.stderr)
        env = json.loads(done.stdout)
        kept = sorted(key for key in env if key.startswith("GIT_") and key not in ("GIT_CONFIG_GLOBAL",
                                                                                   "GIT_CONFIG_NOSYSTEM"))
        self.assertEqual(kept, [])
        self.assertEqual((env["GIT_CONFIG_GLOBAL"], env["GIT_CONFIG_NOSYSTEM"]), (os.devnull, "1"))


if __name__ == "__main__":
    unittest.main()
