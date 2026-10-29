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
    def test_competing_file_is_preserved_for_install_and_uninstall(self):
        for action, keep_foreign in (("install", False), ("uninstall", False), ("uninstall", True)):
            with self.subTest(action=action, keep_foreign=keep_foreign), tempfile.TemporaryDirectory() as root:
                root = Path(root).resolve()
                hooks = root / ".kiro" / "hooks"
                hooks.mkdir(parents=True)
                path = hooks / "cmux.json"
                entries = [{"name": "cmux-old", "action": {
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
                        self.assertEqual(child.returncode, 0, stderr)
                        self.assertIn("No changes were made", stdout)
                        self.assertEqual(path.read_bytes(), replacement)
                    finally:
                        if child.poll() is None:
                            child.kill()
                        child.communicate()


if __name__ == "__main__":
    unittest.main()
