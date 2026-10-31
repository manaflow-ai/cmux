#!/usr/bin/env python3
"""Kiro global-hook mutations must preserve a competing writer's document."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

from claude_teams_test_utils import resolve_cmux_cli


class KiroGlobalHookMutationTests(unittest.TestCase):
    def test_marker_in_foreign_hook_is_preserved_and_marker_only_file_is_removed(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root).resolve()
            path = root / ".kiro" / "hooks" / "cmux.json"
            path.parent.mkdir(parents=True)
            marker = {"name": "cmux-ownership", "trigger": "SessionEnd", "enabled": False,
                      "action": {"type": "command", "command": ": cmux-kiro-global-hook; exit 0"}}
            foreign = {"name": "user-hook", "trigger": "SessionEnd", "enabled": True,
                       "action": {"type": "command", "command": "echo ': cmux-kiro-global-hook;'"}}
            env = {"HOME": str(root), "CFFIXED_USER_HOME": str(root), "PATH": "/usr/bin:/bin",
                   "CMUX_CLI_SENTRY_DISABLED": "1", "CMUX_SOCKET_PATH": str(root / "no-socket")}
            cli = str(resolve_cmux_cli())
            for entries, should_exist in (([marker, foreign], True), ([marker], False)):
                path.write_text(json.dumps({"version": "v1", "hooks": entries}))
                for _ in range(2):
                    result = subprocess.run([cli, "hooks", "kiro", "uninstall", "--global"],
                                            env=env, capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(path.exists(), should_exist)
                    if should_exist:
                        self.assertIn(foreign, json.loads(path.read_text())["hooks"])

    def test_dangling_user_symlink_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root).resolve()
            path = root / ".kiro" / "hooks" / "cmux.json"
            path.parent.mkdir(parents=True)
            missing = root / "user-hooks.json"
            path.symlink_to(missing)
            env = {"HOME": str(root), "CFFIXED_USER_HOME": str(root), "PATH": "/usr/bin:/bin",
                   "CMUX_CLI_SENTRY_DISABLED": "1", "CMUX_SOCKET_PATH": str(root / "no-socket")}
            result = subprocess.run([str(resolve_cmux_cli()), "hooks", "kiro", "install", "--global", "--yes"],
                                    env=env, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(path.is_symlink())
            self.assertFalse(missing.exists())

    def test_competing_file_is_preserved_for_install_and_uninstall(self):
        for action, keep_foreign in (("install", False), ("uninstall", False), ("uninstall", True)):
            with self.subTest(action=action, keep_foreign=keep_foreign), tempfile.TemporaryDirectory() as root:
                root = Path(root).resolve()
                hooks = root / ".kiro" / "hooks"
                hooks.mkdir(parents=True)
                path = hooks / "cmux.json"
                entries = [{"name": "cmux-session-start", "trigger": "SessionStart", "action": {
                    "type": "command", "command": ": cmux-kiro-global-hook; exit 0"}}]
                if keep_foreign:
                    entries.append({"name": "foreign", "action": {"type": "command", "command": "true"}})
                path.write_text(json.dumps({"version": "v1", "hooks": entries}))
                env = {
                    "HOME": str(root), "CFFIXED_USER_HOME": str(root),
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_CLI_SENTRY_DISABLED": "1",
                    "CMUX_SOCKET_PATH": str(root / "no-socket"),
                    "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
                }
                with open(str(path) + ".lock", "a") as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX)
                    child = subprocess.Popen(
                        [str(resolve_cmux_cli()), "hooks", "kiro", action, "--global", "--yes"],
                        env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        text=True,
                    )
                    try:
                        # Observe the child opening the held lock, rather than guessing
                        # how long parsing its initial snapshot takes.
                        deadline = time.monotonic() + 10
                        while time.monotonic() < deadline:
                            self.assertIsNone(child.poll(), "CLI mutated the file without taking the held lock")
                            opened = subprocess.run(
                                ["/usr/sbin/lsof", "-a", "-p", str(child.pid), "-Fn", str(path) + ".lock"],
                                capture_output=True, text=True, timeout=5,
                            )
                            if str(path) + ".lock" in opened.stdout:
                                break
                            time.sleep(0.02)
                        else:
                            self.fail("CLI never reached the global-hook mutation lock")
                        replacement = json.dumps({"version": "v1", "hooks": [{"name": "new-user-hook"}]}).encode()
                        path.write_bytes(replacement)
                        fcntl.flock(lock, fcntl.LOCK_UN)
                        stdout, stderr = child.communicate(timeout=10)
                        self.assertNotEqual(child.returncode, 0, stdout + stderr)
                        self.assertIn("No changes were made", stdout + stderr)
                        self.assertEqual(path.read_bytes(), replacement)
                    finally:
                        if child.poll() is None:
                            child.kill()
                        child.communicate()


if __name__ == "__main__":
    unittest.main()
