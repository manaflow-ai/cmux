#!/usr/bin/env python3
"""The nightly Macs install the pinned Bun (and Node) from the CI cache bucket, never anonymously from github.com.

Runs 45765712386 and 45756842046 (2026-11-26) failed "nightly webview checks before the signer" at Set up Bun:
oven-sh/setup-bun read github.com/oven-sh/bun/releases without a token from a self-hosted signing Mac and got
`Unexpected HTTP response: 403`. scripts/ci/toolchain-r2.sh restore ran first but was Linux-only and Freestyle-only,
so on a Mac nothing stood between setup-bun and that download.

Holds:

1. toolchain-r2.sh restore on Darwin (a fake `uname`, so this runs on Linux) with TOOLCHAIN_R2_ALL=1 puts bun at
   ~/.bun/bin/bun and node in RUNNER_TOOL_CACHE from the bucket's macOS-<arch> namespace, after checking the
   upstream archive's pin. setup-bun then finds the right version there and downloads nothing.
2. A miss, a copy that does not match its pin, or no TOOLCHAIN_R2_ALL on a non-Freestyle Mac leave the installer
   to run and exit 0.
3. `seed all` on the Linux seeder covers the Darwin pins too, each in its own platform's namespace (the archives
   are verified bytes; nothing runs them), so the Macs' keys get filled by the job that has the write credentials.
4. The real pins file holds the Darwin Bun 1.4.4 archives' upstream sha256, and every setup-bun step in nightly.yml
   comes right after a restore of the same version that runs on any runner (TOOLCHAIN_R2_ALL "1") under the same
   condition; every Node or Bun version nightly restores has its Darwin pins.
"""

from __future__ import annotations

import hashlib
import http.server
import os
import re
import shutil
import socketserver
import subprocess
import tarfile
import tempfile
import threading
import unittest
import zipfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "toolchain-r2.sh"
PINS = ROOT / "scripts" / "ci" / "toolchain-archives.sha256"
NIGHTLY = ROOT / ".github" / "workflows" / "nightly.yml"
RESTORE = re.compile(r"toolchain-r2\.sh\"? restore (node|bun) (\S+) \|\| true")

# Upstream sha256 of the Bun 1.4.4 macOS archives (github.com/oven-sh/bun bun-v1.4.4 SHASUMS256.txt, and the zips
# themselves, downloaded and hashed 2026-11-26).
BUN_144_DARWIN = {
    "bun-v1.4.4-darwin-aarch64.zip": "c240d7f0ccb90c263a849fcdb09b7ee62630d921348ed6aafda86b9d577bc510",
    "bun-v1.4.4-darwin-x64.zip": "50a3491f73abc2fe81673171a85762d3bc2cc1680ccecadd983de99adf77977e",
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class _Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):  # noqa: D401 - silence the test server
        pass


class DarwinRestore(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp())
        t = cls.tmp
        cls.bucket = t / "bucket"
        # A fake bun 8.8.8 and node 9.9.9 for macOS arm64, packed as upstream packs them.
        (t / "b" / "bun-darwin-aarch64").mkdir(parents=True)
        bun = t / "b" / "bun-darwin-aarch64" / "bun"
        bun.write_text("#!/bin/sh\necho 8.8.8\n")
        bun.chmod(0o755)
        cls.bun_name = "bun-v8.8.8-darwin-aarch64.zip"
        with zipfile.ZipFile(t / cls.bun_name, "w") as z:
            z.write(bun, "bun-darwin-aarch64/bun")
        node_dir = t / "n" / "node-v9.9.9-darwin-arm64" / "bin"
        node_dir.mkdir(parents=True)
        (node_dir / "node").write_text("#!/bin/sh\necho v9.9.9\n")
        (node_dir / "node").chmod(0o755)
        cls.node_name = "node-v9.9.9-darwin-arm64.tar.gz"
        with tarfile.open(t / cls.node_name, "w:gz") as tf:
            tf.add(t / "n" / "node-v9.9.9-darwin-arm64", "node-v9.9.9-darwin-arm64")
        # A Linux one beside them, for the seed check.
        cls.linux_name = "bun-v8.8.8-linux-x64.zip"
        shutil.copy(t / cls.bun_name, t / cls.linux_name)
        cls.sums = {n: sha256(t / n) for n in (cls.bun_name, cls.node_name, cls.linux_name)}
        (t / "pins").write_text("# test pins\n" + "".join(f"{s}  {n}\n" for n, s in cls.sums.items()))
        cls.put(cls.bun_name, "macOS-ARM64")
        cls.put(cls.node_name, "macOS-ARM64")
        cls.put(cls.linux_name, "Linux-X64")
        # A Rust key on this host's Linux namespace so `seed all` finds Rust held and downloads nothing.
        (t / "rust-toolchain.toml").write_text('[toolchain]\nchannel = "7.7.7"\nprofile = "minimal"\ncomponents = []\n')
        # A fake uname saying Darwin arm64.
        (t / "fakebin").mkdir()
        (t / "fakebin" / "uname").write_text(
            '#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -m) echo arm64 ;; *) echo Darwin ;; esac\n'
        )
        (t / "fakebin" / "uname").chmod(0o755)
        handler = lambda *a, **k: _Quiet(*a, directory=str(cls.bucket), **k)  # noqa: E731
        cls.server = socketserver.TCPServer(("127.0.0.1", 0), handler)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def put(cls, name: str, namespace: str, content: Path | None = None):
        objects = cls.bucket / "v1" / namespace / "objects"
        objects.mkdir(parents=True, exist_ok=True)
        with tarfile.open(objects / f"toolchain-{name}-{cls.sums[name][:16]}.tar.gz", "w:gz") as tf:
            tf.add(content or (cls.tmp / name), name)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def run_script(self, *args: str, darwin: bool = True, **env: str) -> subprocess.CompletedProcess:
        home = Path(tempfile.mkdtemp(dir=self.tmp))
        self.home = home
        base = {
            "PATH": (f"{self.tmp / 'fakebin'}:" if darwin else "") + "/usr/bin:/bin",
            "HOME": str(home),
            "RUNNER_OS": "macOS" if darwin else "Linux",
            "RUNNER_ARCH": "ARM64" if darwin else "X64",
            "RUNNER_NAME": "mac-mini-signer-1",
            "RUNNER_TOOL_CACHE": str(home / "tool"),
            "TOOLCHAIN_PINS_FILE": str(self.tmp / "pins"),
            "TOOLCHAIN_R2_URL": f"http://127.0.0.1:{self.port}",
            "CMUX_LAN_CACHE_SOCKET": str(self.tmp / "none.sock"),
        }
        base.update(env)
        return subprocess.run(
            ["bash", str(SCRIPT), *args], env=base, capture_output=True, text=True, timeout=120
        )

    def test_bun_restores_on_a_mac(self):
        out = self.run_script("restore", "bun", "8.8.8", TOOLCHAIN_R2_ALL="1")
        self.assertEqual(out.returncode, 0, out.stderr)
        bun = self.home / ".bun" / "bin" / "bun"
        self.assertTrue(bun.exists(), out.stdout + out.stderr)
        self.assertEqual(subprocess.run([str(bun), "--version"], capture_output=True, text=True).stdout.strip(), "8.8.8")
        self.assertIn("sha256 matches the pin", out.stdout)

    def test_node_restores_on_a_mac(self):
        out = self.run_script("restore", "node", "9.9.9", TOOLCHAIN_R2_ALL="1")
        self.assertEqual(out.returncode, 0, out.stderr)
        tool = self.home / "tool" / "node" / "9.9.9"
        self.assertTrue((tool / "arm64.complete").exists(), out.stdout + out.stderr)
        self.assertTrue((tool / "arm64" / "bin" / "node").exists())

    def test_mac_without_opt_in_is_left_alone(self):
        out = self.run_script("restore", "bun", "8.8.8")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("not a Freestyle runner", out.stdout)
        self.assertFalse((self.home / ".bun").exists())

    def test_miss_and_bad_copy_leave_setup_bun_to_run(self):
        out = self.run_script("restore", "bun", "8.8.8", TOOLCHAIN_R2_ALL="1", TOOLCHAIN_R2_URL="http://127.0.0.1:1")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("no cached", out.stdout)
        self.assertFalse((self.home / ".bun" / "bin" / "bun").exists())
        out = self.run_script("restore", "bun", "8.8.9", TOOLCHAIN_R2_ALL="1")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("no pin", out.stdout)
        bad = self.tmp / "bad" / self.bun_name
        bad.parent.mkdir(exist_ok=True)
        bad.write_text("tampered")
        self.put(self.bun_name, "macOS-ARM64", bad)
        try:
            out = self.run_script("restore", "bun", "8.8.8", TOOLCHAIN_R2_ALL="1")
            self.assertEqual(out.returncode, 0, out.stderr)
            self.assertIn("does not match its pin", out.stdout)
            self.assertFalse((self.home / ".bun" / "bin" / "bun").exists())
        finally:
            self.put(self.bun_name, "macOS-ARM64")

    def test_seed_all_on_linux_covers_the_darwin_pins(self):
        machine = os.uname().machine
        triple = {"x86_64": "x86_64-unknown-linux-gnu", "aarch64": "aarch64-unknown-linux-gnu"}.get(machine)
        if os.uname().sysname != "Linux" or triple is None:
            self.skipTest("the seeder is Linux")
        ns = "Linux-X64" if machine == "x86_64" else "Linux-ARM64"
        rkey = f"toolchain-rust-7.7.7-{triple}-minimal--v1"
        objects = self.bucket / "v1" / ns / "objects"
        objects.mkdir(parents=True, exist_ok=True)
        with tarfile.open(objects / f"{rkey}.tar.gz", "w:gz") as tf:
            tf.add(self.tmp / "rust-toolchain.toml", "x")
        creds = dict(AWS_ACCESS_KEY_ID="x", AWS_SECRET_ACCESS_KEY="x", CI_CACHE_R2_ENDPOINT="x", CI_CACHE_R2_BUCKET="x")
        out = self.run_script(
            "seed", "all", str(self.tmp / "rust-toolchain.toml"), darwin=False,
            RUNNER_ARCH="X64" if machine == "x86_64" else "ARM64", **creds,
        )
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        for name in (self.bun_name, self.node_name, self.linux_name):
            self.assertIn(f"already holds toolchain-{name}-", out.stdout, out.stdout + out.stderr)


class RealPinsAndNightlyWiring(unittest.TestCase):
    def test_pins_hold_the_darwin_bun_archives(self):
        pins = {}
        for line in PINS.read_text().splitlines():
            if line and not line.startswith("#"):
                digest, name = line.split()
                pins[name] = digest
        for name, digest in BUN_144_DARWIN.items():
            self.assertEqual(pins.get(name), digest, name)
        data = yaml.safe_load(NIGHTLY.read_text())
        for job, body in data["jobs"].items():
            for step in body.get("steps") or []:
                m = RESTORE.search(str(step.get("run", "")))
                if not m:
                    continue
                kind, version = m.groups()
                for arch in ("aarch64", "x64") if kind == "bun" else ("arm64", "x64"):
                    name = f"bun-v{version}-darwin-{arch}.zip" if kind == "bun" else f"node-v{version}-darwin-{arch}.tar.gz"
                    self.assertIn(name, pins, f"{job}: nightly restores {kind} {version} but has no pin for {name}")

    def test_every_nightly_setup_bun_follows_a_restore_any_runner_takes(self):
        data = yaml.safe_load(NIGHTLY.read_text())
        seen = 0
        for job, body in data["jobs"].items():
            steps = body.get("steps") or []
            for index, step in enumerate(steps):
                uses = str(step.get("uses", ""))
                m = RESTORE.search(str(step.get("run", "")))
                if m:
                    self.assertEqual(
                        str((step.get("env") or {}).get("TOOLCHAIN_R2_ALL", "")), "1",
                        f"{job}: the restore of {m.group(1)} {m.group(2)} skips non-Freestyle runners (the Macs)",
                    )
                if "oven-sh/setup-bun@" not in uses:
                    continue
                seen += 1
                version = str((step.get("with") or {}).get("bun-version", "")).strip()
                prev = steps[index - 1] if index else {}
                m = RESTORE.search(str(prev.get("run", "")))
                self.assertTrue(m and m.group(1) == "bun", f"{job}: setup-bun step {index} has no bun restore before it")
                self.assertEqual(m.group(2).strip("'\""), version, f"{job}: restore and setup-bun disagree on the version")
                self.assertEqual(prev.get("if"), step.get("if"), f"{job}: the restore runs under another condition")
        self.assertGreaterEqual(seen, 5)


if __name__ == "__main__":
    unittest.main()
