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
        c.sendall(json.dumps([] if mode == "array-list" else {"sessions": []}).encode())
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

    def test_the_real_list_shape_passes(self):
        # The first release run (37212778565, 2026-10-04): the real binary's list
        # prints a bare JSON array of sessions.
        done = self.smoke("array-list")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)

    def test_each_broken_contract_fails(self):
        for mode in ("wrong-sha", "empty-guide", "serve-dies", "bad-list"):
            with self.subTest(mode=mode):
                done = self.smoke(mode)
                self.assertEqual(done.returncode, 1, f"{mode}: {done.stdout}{done.stderr}")
                self.assertIn("FAIL", done.stderr)


class ReleaseHelperTest(unittest.TestCase):
    HELPER = ROOT / "scripts/cmux-next/browser-host-release.py"

    def helper(self, *args):
        return subprocess.run([sys.executable, str(self.HELPER), *args], capture_output=True, text=True, timeout=60)

    def test_the_tag_must_match_the_crate_version(self):
        cargo = str(ROOT / "cmux-tui/crates/cmux-browser-host/Cargo.toml")
        import tomllib
        crate = tomllib.loads(Path(cargo).read_text())["package"]["version"]
        ok = self.helper("version", f"cmux-browser-host-v{crate}", cargo)
        self.assertEqual((ok.returncode, ok.stdout.strip()), (0, crate), ok.stderr)
        for tag in ("cmux-browser-host-v99.0.0", "cmux-browser-host-1.0.0", "v" + crate):
            self.assertNotEqual(self.helper("version", tag, cargo).returncode, 0, tag)

    def test_packages_are_reproducible_and_entries_cover_both_targets(self):
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "cmux-browser-host"
            binary.write_bytes(b"\x7fELF fake")
            paths = []
            for target in ("x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu"):
                first = self.helper("package", str(binary), "0.1.0", target, f"{tmp}/a").stdout.strip()
                second = self.helper("package", str(binary), "0.1.0", target, f"{tmp}/b").stdout.strip()
                self.assertEqual(Path(first).read_bytes(), Path(second).read_bytes(), "archive bytes differ")
                paths.append(first)
            import json, tarfile
            with tarfile.open(paths[0]) as tar:
                member = tar.getmember("bin/cmux-browser-host")
                self.assertEqual((member.mode, member.mtime), (0o755, 0))
            done = self.helper("entries", "https://example.invalid/r", "0.1.0", *paths)
            self.assertEqual(done.returncode, 0, done.stderr)
            doc = json.loads(done.stdout)
            # Channel manifest schema 2 (decision MANIFEST-ARCH, 2026-10-04): every entry
            # names its arch and target, required, so no reader picks one by an ignored field.
            self.assertEqual(doc["schema"], 2)
            got = doc["packages"]
            self.assertEqual(sorted((e["arch"], e["target"]) for e in got),
                             [("aarch64", "aarch64-unknown-linux-gnu"), ("x86_64", "x86_64-unknown-linux-gnu")])
            for e in got:
                self.assertEqual(set(e), {"name", "version", "url", "sha256", "size", "roles", "arch", "target"})
                self.assertEqual(len(e["sha256"]), 64)
            self.assertNotEqual(self.helper("entries", "https://x", "0.1.0", paths[0]).returncode, 0,
                                "one target alone must be refused")


if __name__ == "__main__":
    sys.exit(unittest.main())
