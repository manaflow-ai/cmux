#!/usr/bin/env python3
"""The git fixture helpers' GIT_CONFIG_GLOBAL file reads the person's global config the way plain git does.

Plain git reads $XDG_CONFIG_HOME/git/config (default ~/.config/git/config) first and ~/.gitconfig after it, so
~/.gitconfig wins a conflict, and it honors a custom XDG_CONFIG_HOME. At 40d04402 tests/git_fixture_env.py and
scripts/cmux-next/tests/lib/git-fixture.sh included ~/.gitconfig first and always ~/.config/git/config: with
conflicting commit.gpgsign they said true where plain git said false, and read the wrong XDG file.
This file makes no git repositories: it only reads config, and its reference environment is plain git on purpose.
Run: python3 -I tests/test_git_fixture_global_config.py
"""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

PYTHON_PROBE = """
import importlib.util, subprocess, sys
spec = importlib.util.spec_from_file_location("git_fixture_env", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
for env in (None, module.fixture_env()):
    out = subprocess.run(["git", "config", "--get", sys.argv[2]], env=env, capture_output=True, text=True)
    print(out.stdout.strip() or "<unset>")
"""


class GlobalConfigMatchesPlainGit(unittest.TestCase):
    """Python load, Python fixture_env and the shell helper each give plain git's value."""

    KEY = "commit.gpgsign"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.home.mkdir()

    def env(self, xdg: Path | None) -> dict:
        env = {key: value for key, value in os.environ.items()
               if not key.startswith("GIT_") and key not in ("XDG_CONFIG_HOME", "CMUX_GIT_FIXTURE_GLOBAL_DIR")}
        env.update(HOME=str(self.home), GIT_CONFIG_NOSYSTEM="1", TMPDIR=str(self.root))
        if xdg is not None:
            env["XDG_CONFIG_HOME"] = str(xdg)
        return env

    def write(self, path: Path, value: str):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"[commit]\n\tgpgsign = {value}\n")

    def plain(self, env: dict) -> str:
        out = subprocess.run(["git", "config", "--get", self.KEY], cwd=self.root, env=env, capture_output=True,
                             text=True, stdin=subprocess.DEVNULL)
        return out.stdout.strip() or "<unset>"

    def helpers(self, env: dict) -> dict:
        python = subprocess.run([sys.executable, "-I", "-c", PYTHON_PROBE, str(ROOT / "tests" / "git_fixture_env.py"),
                                 self.KEY], cwd=self.root, env=env, capture_output=True, text=True, check=True,
                                stdin=subprocess.DEVNULL).stdout.split()
        shell = subprocess.run(["bash", "-c", 'source "$1" && { git config --get "$2" || echo "<unset>"; } '
                                '&& git config --get maintenance.auto', "_",
                                str(ROOT / "scripts/cmux-next/tests/lib/git-fixture.sh"), self.KEY],
                               cwd=self.root, env=env, capture_output=True, text=True, check=True,
                               stdin=subprocess.DEVNULL).stdout.split()
        maintenance = subprocess.run([sys.executable, "-I", "-c", PYTHON_PROBE,
                                      str(ROOT / "tests" / "git_fixture_env.py"), "maintenance.auto"],
                                     cwd=self.root, env=env, capture_output=True, text=True, check=True,
                                     stdin=subprocess.DEVNULL).stdout.split()
        return {"python load": python[0], "python fixture_env": python[1], "shell": shell[0],
                "python maintenance.auto": maintenance[0], "shell maintenance.auto": shell[1]}

    def check(self, env: dict, case: str):
        expected = self.plain(env)
        seen = self.helpers(env)
        print(f"{case}: plain git {self.KEY}={expected}; helpers {seen}")
        for name in ("python load", "python fixture_env", "shell"):
            self.assertEqual(seen[name], expected, f"{case}: {name} {seen}")
        self.assertEqual(seen["python maintenance.auto"], "false", seen)
        self.assertEqual(seen["shell maintenance.auto"], "false", seen)
        return expected

    def test_default_xdg_and_home_gitconfig_conflict(self):
        self.write(self.home / ".config/git/config", "true")
        self.write(self.home / ".gitconfig", "false")
        self.assertEqual(self.check(self.env(None), "default XDG + ~/.gitconfig"), "false")

    def test_custom_xdg_and_home_gitconfig_conflict(self):
        xdg = self.root / "xdg"
        self.write(xdg / "git/config", "true")
        self.write(self.home / ".gitconfig", "false")
        # The default-location file must not be read when XDG_CONFIG_HOME points elsewhere.
        self.write(self.home / ".config/git/config", "yes-wrong-file")
        self.assertEqual(self.check(self.env(xdg), "custom XDG + ~/.gitconfig"), "false")

    def test_custom_xdg_path_with_quote_and_backslash(self):
        # The include path is a config-file string: a '"' or '\\' in it must be escaped, not end or bend it.
        xdg = self.root / 'x"y\\z #;'
        self.write(xdg / "git/config", "true")
        self.write(self.home / ".config/git/config", "yes-wrong-file")
        self.assertEqual(self.check(self.env(xdg), "custom XDG with quote and backslash"), "true")
        self.write(self.home / ".gitconfig", "false")
        self.assertEqual(self.check(self.env(xdg), "quoted XDG + ~/.gitconfig"), "false")

    def test_custom_xdg_alone(self):
        xdg = self.root / "xdg"
        self.write(xdg / "git/config", "true")
        self.write(self.home / ".config/git/config", "yes-wrong-file")
        self.assertEqual(self.check(self.env(xdg), "custom XDG only"), "true")

    def test_default_xdg_alone_and_neither(self):
        self.assertEqual(self.check(self.env(None), "no global config"), "<unset>")
        self.write(self.home / ".config/git/config", "true")
        self.assertEqual(self.check(self.env(None), "default XDG only"), "true")

    def test_global_config_includes_still_expand(self):
        # [include] path= keeps the person's own includes working.
        self.write(self.root / "included", "false")
        (self.home / ".gitconfig").write_text(f"[commit]\n\tgpgsign = true\n[include]\n\tpath = {self.root / 'included'}\n")
        self.assertEqual(self.check(self.env(None), "~/.gitconfig with its own include"), "false")



if __name__ == "__main__":
    unittest.main()
