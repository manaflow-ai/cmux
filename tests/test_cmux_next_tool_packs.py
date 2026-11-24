#!/usr/bin/env python3
"""scripts/cmux-next/tool-packs.py split moves a tool out of an app's bin into a pack and pins it.

The pack is what cmux-tui-core's tool_packs.rs unpacks: one tar entry NAME, mode 0755. The tool's
place becomes a link to `cmux` (the multicall binary that answers to the name), and the pin in the
app and in OUT names the pack's and the tool's size and SHA-256 at a content-addressed URL.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "cmux-next" / "tool-packs.py"
BASE = "https://files-next.cmux.com/tool-packs"
TOOL = b"\xcf\xfa\xed\xfe the iPhone host " * 100


def unzstd(data: bytes) -> bytes:
    cli = shutil.which("zstd")
    if cli:
        return subprocess.run([cli, "-d", "-q", "-c"], input=data, stdout=subprocess.PIPE, check=True).stdout
    from compression import zstd  # Python 3.14+
    return zstd.decompress(data)


def have_zstd() -> bool:
    if shutil.which("zstd"):
        return True
    try:
        from compression import zstd  # noqa: F401
    except ImportError:
        return False
    return True


@unittest.skipUnless(have_zstd(), "needs the zstd CLI or Python 3.14+")
class SplitTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="tool-packs-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.app = self.tmp / "cmux NIGHTLY.app"
        self.bin = self.app / "Contents" / "Resources" / "bin"
        self.bin.mkdir(parents=True)
        (self.bin / "cmux").write_bytes(b"multicall")
        (self.bin / "cmux").chmod(0o755)
        (self.bin / "cmux-mobile-host").write_bytes(TOOL)
        (self.bin / "cmux-mobile-host").chmod(0o755)
        self.out = self.tmp / "out"

    def run_script(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, "-I", str(SCRIPT), *args], capture_output=True, text=True,
                              check=False)

    def test_split_links_the_tool_to_cmux_and_pins_its_pack(self) -> None:
        done = self.run_script("split", str(self.app), str(self.out), "--base-url", BASE + "/")
        self.assertEqual(done.returncode, 0, done.stderr)
        host = self.bin / "cmux-mobile-host"
        self.assertTrue(host.is_symlink())
        self.assertEqual(os.readlink(host), "cmux")

        app_pin = json.loads((self.app / "Contents" / "Resources" / "tool-packs.json").read_text())
        self.assertEqual(app_pin, json.loads((self.out / "tool-packs.json").read_text()))
        self.assertEqual(app_pin["version"], 1)
        tool = app_pin["tools"]["cmux-mobile-host"]
        pack = (self.out / "cmux-mobile-host.tar.zst").read_bytes()
        self.assertEqual(tool["size"], len(pack))
        self.assertEqual(tool["sha256"], hashlib.sha256(pack).hexdigest())
        self.assertEqual(tool["file_size"], len(TOOL))
        self.assertEqual(tool["file_sha256"], hashlib.sha256(TOOL).hexdigest())
        self.assertEqual(tool["url"], f"{BASE}/{tool['sha256']}/cmux-mobile-host.tar.zst")

        with tarfile.open(fileobj=io.BytesIO(unzstd(pack))) as tar:
            members = tar.getmembers()
            self.assertEqual([m.name for m in members], ["cmux-mobile-host"])
            self.assertTrue(members[0].isreg())
            self.assertEqual(members[0].mode, 0o755)
            self.assertEqual(members[0].mtime, 0)
            self.assertEqual(tar.extractfile(members[0]).read(), TOOL)

    def test_split_is_deterministic(self) -> None:
        copy = self.tmp / "copy.app"
        shutil.copytree(self.app, copy, symlinks=True)
        first = self.run_script("split", str(self.app), str(self.out), "--base-url", BASE)
        second = self.run_script("split", str(copy), str(self.tmp / "out2"), "--base-url", BASE)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual((self.out / "tool-packs.json").read_text(), (self.tmp / "out2" / "tool-packs.json").read_text())

    def test_split_refuses_a_split_app_an_unknown_tool_and_plain_http(self) -> None:
        self.assertEqual(self.run_script("split", str(self.app), str(self.out), "--base-url", BASE).returncode, 0)
        again = self.run_script("split", str(self.app), str(self.tmp / "again"), "--base-url", BASE)
        self.assertNotEqual(again.returncode, 0)
        self.assertIn("split already", again.stderr)

        fresh = self.tmp / "fresh.app"
        (fresh / "Contents" / "Resources" / "bin").mkdir(parents=True)
        (fresh / "Contents" / "Resources" / "bin" / "cmux").write_bytes(b"multicall")
        unknown = self.run_script("split", str(fresh), str(self.tmp / "o3"), "--base-url", BASE,
                                  "--tool", "optchat-chief")
        self.assertNotEqual(unknown.returncode, 0)
        self.assertIn("not a tool", unknown.stderr)
        http = self.run_script("split", str(fresh), str(self.tmp / "o4"), "--base-url", "http://example.com/x")
        self.assertNotEqual(http.returncode, 0)
        self.assertIn("must be https", http.stderr)


if __name__ == "__main__":
    unittest.main()
