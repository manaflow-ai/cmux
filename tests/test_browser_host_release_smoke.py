#!/usr/bin/env python3
"""scripts/cmux-next/smoke-browser-host.sh: the release smoke of cmux-browser-host.

A fake binary plays the contract of plans/cmux-next/browser-host.md 6d
(version line, guide, serve + list on a socket); each broken variant must fail
the smoke, so a release cannot ship a binary that misses one of them.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SMOKE = ROOT / "scripts/cmux-next/smoke-browser-host.sh"
SHA = "0123456789abcdef0123456789abcdef01234567"

FAKE = r'''#!/usr/bin/env python3
import json, os, socket, sys
mode = os.environ.get("FAKE_MODE", "good")
cmd = sys.argv[1] if len(sys.argv) > 1 else ""
if cmd == "version":
    sha = "f" * 40 if mode == "wrong-sha" else os.environ["FAKE_SHA"]
    print(f"cmux-browser-host 0.1.0 ({sha})")
    sys.exit(0)
if cmd == "guide":
    if mode != "empty-guide":
        print("# cmux browser guide")
    sys.exit(0)
path = sys.argv[sys.argv.index("--socket") + 1]
if cmd == "serve":
    if mode == "serve-dies":
        sys.exit(3)
    s = socket.socket(socket.AF_UNIX)
    s.bind(path)
    s.listen(1)
    while True:
        c, _ = s.accept()
        c.recv(65536)
        c.sendall(json.dumps({"sessions": []}).encode())
        c.close()
if cmd == "list":
    if mode == "bad-list":
        print("not json")
        sys.exit(0)
    c = socket.socket(socket.AF_UNIX)
    c.connect(path)
    c.sendall(b"list")
    print(c.recv(65536).decode())
    sys.exit(0)
sys.exit(2)
'''


class SmokeTest(unittest.TestCase):
    def smoke(self, mode: str) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
            fake = Path(tmp) / "cmux-browser-host"
            fake.write_text(FAKE)
            fake.chmod(0o755)
            env = {**os.environ, "FAKE_MODE": mode, "FAKE_SHA": SHA}
            return subprocess.run(["bash", str(SMOKE), str(fake), SHA], capture_output=True, text=True,
                                  env=env, timeout=60)

    def test_a_binary_that_meets_the_contract_passes(self):
        done = self.smoke("good")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("all checks passed", done.stdout)

    def test_each_broken_contract_fails(self):
        for mode in ("wrong-sha", "empty-guide", "serve-dies", "bad-list"):
            with self.subTest(mode=mode):
                done = self.smoke(mode)
                self.assertEqual(done.returncode, 1, f"{mode}: {done.stdout}{done.stderr}")
                self.assertIn("FAIL", done.stderr)


if __name__ == "__main__":
    sys.exit(unittest.main())
