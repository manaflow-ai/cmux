"""Tests for scripts/ci/signer_parity_compare.py (the codesign/rcodesign payload compare)."""
from __future__ import annotations

import hashlib
import json
import plistlib
import os
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "ci" / "signer_parity_compare.py"


def code_directory(identifier: bytes, page_shift: int, code_hash: bytes) -> bytes:
    ident_off = 44
    hash_off = ident_off + len(identifier) + 1
    body = identifier + b"\0" + code_hash
    header = struct.pack(">IIIIIIIIIBBBBI", 0xFADE0C02, 44 + len(body), 0x20001, 0x10000,
                         hash_off, ident_off, 0, 1, 64, 32, 2, 0, page_shift, 0)
    return header + body


def macho(text: bytes, cms: bytes, page_shift: int = 12, pad: int = 0) -> bytes:
    """A thin arm64 Mach-O: __LINKEDIT, LC_CODE_SIGNATURE, `text`, then a superblob."""
    sizeofcmds = 72 + 16
    dataoff = 32 + sizeofcmds + len(text)
    cd = code_directory(b"com.example.tool", page_shift, hashlib.sha256(text).digest())
    blobs = [(0, cd), (0x10000, struct.pack(">II", 0xFADE0B01, 8 + len(cms)) + cms)]
    index_len = 12 + 8 * len(blobs)
    index, payload, off = b"", b"", index_len
    for typ, blob in blobs:
        index += struct.pack(">II", typ, off)
        payload += blob
        off += len(blob)
    superblob = struct.pack(">III", 0xFADE0CC0, index_len + len(payload) + pad, len(blobs)) + index + payload + bytes(pad)
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 2, sizeofcmds, 0, 0)
    linkedit = struct.pack("<II16sQQQQiiII", 0x19, 72, b"__LINKEDIT", 0x4000, 0x1000 + len(superblob),
                           0, dataoff + len(superblob), 1, 1, 0, 0)
    signature = struct.pack("<IIII", 0x1D, 16, dataoff, len(superblob))
    return header + linkedit + signature + text + superblob


def make_app(root: Path, *, tool: bytes, resources: dict | None = None, link: str = "Versions/A",
             manifest_extra: str = "", mode: int = 0o755) -> Path:
    app = root / "Demo.app" / "Contents"
    (app / "MacOS").mkdir(parents=True)
    (app / "_CodeSignature").mkdir()
    (app / "_CodeSignature" / "CodeResources").write_bytes(plistlib.dumps(resources or {"files": {}}))
    (app / "Info.plist").write_text("<plist>info</plist>")
    exe = app / "MacOS" / "Demo"
    exe.write_bytes(tool)
    exe.chmod(mode)
    os.symlink(link, app / "Current")
    ssh = app / "Resources" / "bin" / "cmux-tui-ssh"
    ssh.mkdir(parents=True)
    (ssh / "cmux-tui-darwin-arm64").write_bytes(tool)
    digest = hashlib.sha256(tool).hexdigest()
    (ssh / "manifest.json").write_text(json.dumps({"version": "1" + manifest_extra,
                                                   "binaries": {"cmux-tui-darwin-arm64": digest}}))
    return root / "Demo.app"


class SignerParityCompareTests(unittest.TestCase):
    def run_compare(self, a: Path, b: Path):
        out = Path(self.tmp.name) / "out.json"
        proc = subprocess.run([sys.executable, "-I", str(SCRIPT), str(a), str(b), str(out),
                               "--labels", "codesign,rcodesign"], capture_output=True, text=True)
        return proc, json.loads(out.read_text())

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_signature_only_differences_pass_and_are_reported(self):
        a = make_app(self.root / "a", tool=macho(b"TEXT" * 8, b"cms-one", 14), resources={"files2": {"MacOS/x": {"hash2": b"a"}}})
        b = make_app(self.root / "b", tool=macho(b"TEXT" * 8, b"cms-two-longer", 12, pad=16),
                     resources={"files2": {"MacOS/x": {"hash2": b"b", "requirement": "r"}}})
        proc, result = self.run_compare(a, b)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(result["payload_failures"], [])
        sig = result["signature_differences"]["Contents/MacOS/Demo"]["arm64"]
        self.assertIn("CMS signature: differs (15 / 22 bytes)", sig)
        cd = next(d for d in sig if isinstance(d, dict))["CodeDirectory"]
        self.assertEqual(cd["pageSize"], [16384, 4096])
        self.assertEqual(result["code_resources_differences"]["Demo.app/Contents/_CodeSignature/CodeResources"
                         .split("Demo.app/", 1)[1]], ["files2/MacOS/x: hash2, requirement"])

    def test_one_payload_byte_fails(self):
        a = make_app(self.root / "a", tool=macho(b"TEXT" * 8, b"cms"))
        b = make_app(self.root / "b", tool=macho(b"TEXT" * 7 + b"TEXt", b"cms"))
        proc, result = self.run_compare(a, b)
        self.assertEqual(proc.returncode, 1)
        self.assertTrue(any("Contents/MacOS/Demo: payload differs" in f for f in result["payload_failures"]))

    def test_mode_and_symlink_targets_are_payload(self):
        a = make_app(self.root / "a", tool=macho(b"T" * 32, b"c"))
        b = make_app(self.root / "b", tool=macho(b"T" * 32, b"c"), link="Versions/B", mode=0o644)
        proc, result = self.run_compare(a, b)
        self.assertEqual(proc.returncode, 1)
        joined = "\n".join(result["payload_failures"])
        self.assertIn("Contents/Current: payload differs (target)", joined)
        self.assertIn("Contents/MacOS/Demo: payload differs (mode)", joined)

    def test_manifest_checksums_of_signed_payloads_are_masked_only_when_they_match(self):
        a = make_app(self.root / "a", tool=macho(b"T" * 32, b"one"))
        b = make_app(self.root / "b", tool=macho(b"T" * 32, b"two"))
        proc, _ = self.run_compare(a, b)
        self.assertEqual(proc.returncode, 0, proc.stdout)
        manifest = b / "Contents/Resources/bin/cmux-tui-ssh/manifest.json"
        data = json.loads(manifest.read_text())
        data["binaries"]["cmux-tui-darwin-arm64"] = "0" * 64
        manifest.write_text(json.dumps(data))
        proc, result = self.run_compare(a, b)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("manifest checksum is not the file's sha256", "\n".join(result["payload_failures"]))

    def test_other_manifest_fields_are_payload(self):
        a = make_app(self.root / "a", tool=macho(b"T" * 32, b"c"))
        b = make_app(self.root / "b", tool=macho(b"T" * 32, b"c"), manifest_extra="x")
        proc, _ = self.run_compare(a, b)
        self.assertEqual(proc.returncode, 1)

    def test_a_path_on_one_side_only_fails(self):
        a = make_app(self.root / "a", tool=macho(b"T" * 32, b"c"))
        b = make_app(self.root / "b", tool=macho(b"T" * 32, b"c"))
        (b / "Contents" / "extra.txt").write_text("x")
        proc, result = self.run_compare(a, b)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("Contents/extra.txt: only in rcodesign", result["payload_failures"])


if __name__ == "__main__":
    unittest.main()
