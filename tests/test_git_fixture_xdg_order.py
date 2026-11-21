#!/usr/bin/env python3
"""The git fixture helpers read the person's global config exactly as plain git does (Codex F1 on cmux#40871).

Plain git reads $XDG_CONFIG_HOME/git/config (~/.config/git/config when XDG_CONFIG_HOME is unset) and then
~/.gitconfig, so a key in ~/.gitconfig wins. At 59e37b4c tests/git_fixture_env.py and
scripts/cmux-next/tests/lib/git-fixture.sh included ~/.gitconfig first and ~/.config/git/config after it, and
ignored XDG_CONFIG_HOME: loading either helper changed user.name. At d4422bca (cmux#40939) a relative HOME or
XDG_CONFIG_HOME was written as a relative include path, which git resolves against the fixture file's folder. Each case here builds a HOME, asks plain git
(no GIT_CONFIG_GLOBAL) for a key, and checks that git under each helper answers the same: the Python module as
loaded, fixture_env() for an env with another HOME, and the shell helper.

  python3 tests/test_git_fixture_xdg_order.py
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "tests" / "git_fixture_env.py"
LIB = ROOT / "scripts" / "cmux-next" / "tests" / "lib" / "git-fixture.sh"

# Load the module in a child with ENV, then run `git config --get KEY` there (the module's own os.environ).
LOADED = """
import importlib.util, os, subprocess, sys
spec = importlib.util.spec_from_file_location("git_fixture_env", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
done = subprocess.run(["git", "config", "--get", sys.argv[2]], capture_output=True, text=True)
print(done.returncode, done.stdout.strip())
"""
# Load the module with this process's HOME, then fixture_env() an env whose HOME and XDG_CONFIG_HOME are argv's.
FIXTURE_ENV = """
import importlib.util, json, subprocess, sys
spec = importlib.util.spec_from_file_location("git_fixture_env", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
env = module.fixture_env(json.loads(sys.argv[3]))
done = subprocess.run(["git", "config", "--get", sys.argv[2]], capture_output=True, text=True, env=env)
print(done.returncode, done.stdout.strip())
"""


class GlobalConfigOrder(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="git-fixture-xdg-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.tmp)], check=False)
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.cwd = self.tmp / "not-a-repo"
        self.cwd.mkdir()
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("GIT_") and key not in ("XDG_CONFIG_HOME", "CMUX_GIT_FIXTURE_GLOBAL_DIR")}
        # No system config and no repository: only the global files decide.
        self.env.update(HOME=str(self.home), GIT_CONFIG_NOSYSTEM="1", GIT_CEILING_DIRECTORIES=str(self.tmp))

    def write(self, path: Path, text: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def answer(self, command: list[str], env: dict[str, str]) -> str:
        done = subprocess.run(command, cwd=self.cwd, env=env, capture_output=True, text=True, timeout=60,
                              stdin=subprocess.DEVNULL)
        self.assertEqual(done.returncode, 0, done.stderr)
        return done.stdout.strip()

    def views(self, key: str, env: dict[str, str]) -> dict[str, str]:
        """`EXIT VALUE` of `git config --get KEY`: plain git, then git under each helper."""
        plain = subprocess.run(["git", "config", "--get", key], cwd=self.cwd, env=env, capture_output=True,
                               text=True, stdin=subprocess.DEVNULL)
        import json
        # fixture_env from a parent whose HOME is elsewhere: the env's own HOME and XDG_CONFIG_HOME must count.
        parent = dict(env, HOME=str(self.tmp / "parent-home"))
        parent.pop("XDG_CONFIG_HOME", None)
        return {
            "plain git": f"{plain.returncode} {plain.stdout.strip()}".strip(),
            "python helper": self.answer([sys.executable, "-I", "-c", LOADED, str(MODULE), key], env),
            "fixture_env": self.answer([sys.executable, "-I", "-c", FIXTURE_ENV, str(MODULE), key, json.dumps(env)],
                                       parent),
            "shell helper": self.answer(
                ["bash", "-c", 'source "$1"; v=$(git config --get "$2"); echo "$? $v"', "_", str(LIB), key], env),
        }

    def assertAllMatchPlainGit(self, key: str, env: dict[str, str], expected: str) -> None:
        views = self.views(key, env)
        self.assertEqual(views["plain git"], expected, "the fixture HOME is not what this case means")
        for name, seen in views.items():
            self.assertEqual(seen, expected, f"{name} reads {key} differently from plain git: {views}")

    def test_gitconfig_wins_over_the_default_xdg_file(self):
        self.write(self.home / ".config/git/config", "[user]\n\tname = from-xdg\n\temail = xdg@example.invalid\n")
        self.write(self.home / ".gitconfig", "[user]\n\tname = from-gitconfig\n")
        self.assertAllMatchPlainGit("user.name", self.env, "0 from-gitconfig")
        # A key only the XDG file sets still comes through.
        self.assertAllMatchPlainGit("user.email", self.env, "0 xdg@example.invalid")

    def test_xdg_config_home_names_the_xdg_file(self):
        self.write(self.home / ".config/git/config", "[user]\n\tname = from-default-xdg\n")
        self.write(self.tmp / "xdg/git/config", "[user]\n\tname = from-xdg-config-home\n")
        env = dict(self.env, XDG_CONFIG_HOME=str(self.tmp / "xdg"))
        self.assertAllMatchPlainGit("user.name", env, "0 from-xdg-config-home")
        self.write(self.home / ".gitconfig", "[user]\n\tname = from-gitconfig\n")
        self.assertAllMatchPlainGit("user.name", env, "0 from-gitconfig")

    def test_xdg_config_home_unset_falls_back_to_dot_config(self):
        self.write(self.home / ".config/git/config", "[user]\n\tname = from-default-xdg\n")
        self.assertAllMatchPlainGit("user.name", self.env, "0 from-default-xdg")

    def test_neither_file_present(self):
        self.assertAllMatchPlainGit("user.name", self.env, "1")
        # The opt-out is still there under every helper.
        views = self.views("maintenance.auto", self.env)
        self.assertEqual(views.pop("plain git"), "1")
        self.assertEqual(set(views.values()), {"0 false"}, views)

    def test_a_files_own_include_still_works(self):
        self.write(self.home / "more.gitconfig", "[user]\n\tname = from-include\n")
        self.write(self.home / ".gitconfig", "[include]\n\tpath = ~/more.gitconfig\n")
        self.assertAllMatchPlainGit("user.name", self.env, "0 from-include")

    def test_a_relative_home_counts_from_the_callers_cwd(self):
        """git reads a relative HOME against its cwd; the fixture file's includes must name the same files
        (an [include] path resolves against the fixture file's own folder)."""
        self.write(self.home / ".config/git/config", "[user]\n\tname = from-xdg\n\temail = xdg@example.invalid\n")
        self.write(self.home / ".gitconfig", "[user]\n\tname = from-gitconfig\n")
        env = dict(self.env, HOME=os.path.relpath(self.home, self.cwd))
        self.assertFalse(os.path.isabs(env["HOME"]))
        self.assertAllMatchPlainGit("user.name", env, "0 from-gitconfig")
        self.assertAllMatchPlainGit("user.email", env, "0 xdg@example.invalid")

    def test_a_relative_xdg_config_home_counts_from_the_callers_cwd(self):
        self.write(self.tmp / "xdg/git/config", "[user]\n\tname = from-relative-xdg\n")
        env = dict(self.env, XDG_CONFIG_HOME=os.path.relpath(self.tmp / "xdg", self.cwd))
        self.assertFalse(os.path.isabs(env["XDG_CONFIG_HOME"]))
        self.assertAllMatchPlainGit("user.name", env, "0 from-relative-xdg")

    def test_the_shell_helper_prints_the_python_text(self):
        """One rule: the shell helper's GIT_CONFIG_GLOBAL holds what git_fixture_env.py --global-config-text prints."""
        self.write(self.home / ".config/git/config", "[user]\n\tname = from-xdg\n")
        self.write(self.home / ".gitconfig", "[user]\n\tname = from-gitconfig\n")
        text = self.answer([sys.executable, "-I", str(MODULE), "--global-config-text"], self.env)
        shell = self.answer(["bash", "-c", 'source "$1"; cat "$GIT_CONFIG_GLOBAL"', "_", str(LIB)], self.env)
        self.assertEqual(shell, text)
        xdg = text.index(str(self.home / ".config/git/config"))
        self.assertLess(xdg, text.index(str(self.home / ".gitconfig")), text)


if __name__ == "__main__":
    unittest.main()
