#!/usr/bin/env python3
"""A workspace's initial command puts the Claude shim root first on PATH only
when that root is a real directory this user owns.

Compiles the app's login-shell wrapper with a small driver and runs the
wrapped command in each available login shell. No app, socket or CLI build.
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
POSIX_SHELLS = ["zsh", "bash", "sh", "ksh", "dash"]
PRINT_PATH = {"posix": "printf '%s\\n' \"$PATH\"", "fish": "string join : $PATH"}


def available_shells() -> dict[str, str]:
    """Maps each shell path to the kind of command it runs."""
    shells = {f"/bin/{name}": "posix" for name in POSIX_SHELLS if os.access(f"/bin/{name}", os.X_OK)}
    fish = shutil.which("fish")
    if fish is not None:
        shells[fish] = "fish"
    return shells


class WorkspaceInitialCommandShimRootOwner(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp = tempfile.TemporaryDirectory(prefix="cmux-login-shell-test-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.binary = Path(cls.temp.name) / "login-shell-fixture"
        build = subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5",
            "-module-cache-path", str(Path(cls.temp.name) / "cache"),
            str(ROOT / "Sources/WorkspaceInitialCommandLoginShell.swift"),
            str(ROOT / "tests/fixtures/WorkspaceInitialCommandLoginShellFixture.swift"),
            "-o", str(cls.binary),
        ], capture_output=True, text=True, timeout=300)
        if build.returncode:
            raise RuntimeError(build.stderr)
        cls.shells = available_shells()

    def setUp(self) -> None:
        self.sandbox = Path(tempfile.mkdtemp(prefix="case-", dir=self.temp.name))
        self.home = self.sandbox / "home"
        self.home.mkdir()

    def path_entries(self, shell: str, kind: str, shim_root: str, agent_root: str | None = None) -> list[str]:
        wrapped = subprocess.run([str(self.binary), shell, PRINT_PATH[kind]],
                                 capture_output=True, text=True, timeout=30, check=True).stdout[:-1]
        env = {
            "HOME": str(self.home),
            "PATH": "/usr/bin:/bin",
            "TMPDIR": str(self.sandbox),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "XDG_DATA_HOME": str(self.home / ".local/share"),
            "CMUX_CLAUDE_WRAPPER_SHIM_ROOT": shim_root,
        }
        if agent_root is not None:
            env["CMUX_AGENT_COMMAND_SHIM_ROOT"] = agent_root
        result = subprocess.run(["/bin/sh", "-c", wrapped], env=env, cwd=self.home,
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, f"{shell}: {result.stderr}")
        lines = result.stdout.strip().splitlines()
        self.assertTrue(lines, f"{shell} printed no PATH: {result.stderr}")
        return lines[-1].split(":")

    def assert_prepended(self, shim_root: str) -> None:
        for shell, kind in self.shells.items():
            with self.subTest(shell=shell):
                self.assertEqual(self.path_entries(shell, kind, shim_root)[0], shim_root)

    def assert_not_on_path(self, shim_root: str) -> None:
        for shell, kind in self.shells.items():
            with self.subTest(shell=shell):
                self.assertNotIn(shim_root, self.path_entries(shell, kind, shim_root))

    def test_owned_directory_is_prepended(self) -> None:
        shim_root = self.sandbox / "shims"
        shim_root.mkdir(mode=0o700)
        self.assert_prepended(str(shim_root))

    def test_owned_but_group_or_other_writable_directory_is_not_prepended(self) -> None:
        for permissions in (0o770, 0o777):
            with self.subTest(permissions=oct(permissions)):
                shim_root = self.sandbox / f"shims-{permissions:o}"
                shim_root.mkdir(mode=permissions)
                shim_root.chmod(permissions)
                self.assert_not_on_path(str(shim_root))

    def test_owned_root_under_writable_ancestor_is_not_prepended(self) -> None:
        parent = self.sandbox / "shared"
        parent.mkdir()
        parent.chmod(0o777)
        shim_root = parent / "shims"
        shim_root.mkdir(mode=0o700)
        self.assert_not_on_path(str(shim_root))
        alias = self.sandbox / "alias"
        alias.symlink_to(parent, target_is_directory=True)
        self.assert_not_on_path(str(alias / "shims"))

    def test_sticky_shared_ancestor_is_allowed(self) -> None:
        parent = self.sandbox / "shared"
        parent.mkdir()
        parent.chmod(0o1777)
        shim_root = parent / "shims"
        shim_root.mkdir(mode=0o700)
        self.assert_prepended(str(shim_root))

    def test_agent_root_is_used_without_claude_integration(self) -> None:
        shim_root = self.sandbox / "agent-shims"
        shim_root.mkdir(mode=0o700)
        for shell, kind in self.shells.items():
            with self.subTest(shell=shell):
                self.assertEqual(self.path_entries(shell, kind, "", str(shim_root))[0], str(shim_root))

    def test_symlink_is_not_prepended(self) -> None:
        target = self.sandbox / "target"
        target.mkdir(mode=0o700)
        shim_root = self.sandbox / "shims"
        os.symlink(target, shim_root)
        self.assert_not_on_path(str(shim_root))

    def test_directory_another_user_owns_is_not_prepended(self) -> None:
        if os.geteuid() == 0:
            self.skipTest("root owns the system directory used here")
        shim_root = "/usr/share"
        self.assertNotEqual(os.stat(shim_root).st_uid, os.geteuid())
        self.assert_not_on_path(shim_root)

    def test_missing_path_is_not_prepended(self) -> None:
        self.assert_not_on_path(str(self.sandbox / "missing"))

    def test_regular_file_is_not_prepended(self) -> None:
        shim_root = self.sandbox / "shims"
        shim_root.write_text("")
        self.assert_not_on_path(str(shim_root))


if __name__ == "__main__":
    unittest.main()
