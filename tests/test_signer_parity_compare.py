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
    # As codesign writes it: the superblob, then zero padding up to datasize.
    superblob = struct.pack(">III", 0xFADE0CC0, index_len + len(payload), len(blobs)) + index + payload + bytes(pad)
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


def fat(*thin_files: bytes, subtype: int = 0, align: int = 14, pad_byte: bytes = b"\0") -> bytes:
    """A universal file around thin arm64 slices, each at a 2**align boundary."""
    header = struct.pack(">II", 0xCAFEBABE, len(thin_files))
    body, off, entries = b"", 1 << align, b""
    for thin in thin_files:
        entries += struct.pack(">iiIII", 0x0100000C, subtype, off, len(thin), align)
        body += thin + pad_byte * ((-len(thin)) % (1 << align))
        off += len(thin) + ((-len(thin)) % (1 << align))
    head = header + entries
    return head + pad_byte * ((1 << align) - len(head)) + body


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

    def test_slices_differing_only_inside_the_cms_are_counted(self):
        a = make_app(self.root / "a", tool=macho(b"TEXT" * 8, b"cms-a" * 4, pad=32))
        b = make_app(self.root / "b", tool=macho(b"TEXT" * 8, b"cms-b" * 4, pad=32))
        _, result = self.run_compare(a, b)
        self.assertEqual(result["counts"]["only_cms_differs"], result["counts"]["slices"])
        self.assertEqual(result["counts"]["identical_slices"], 0)
        # Identical slices are not counted as CMS-only differences.
        _, result = self.run_compare(a, a)
        self.assertEqual(result["counts"]["only_cms_differs"], 0)
        self.assertEqual(result["counts"]["identical_slices"], result["counts"]["slices"])
        self.assertGreater(result["counts"]["slices"], 0)
        # A different reservation is reported as more than a CMS difference.
        c = make_app(self.root / "c", tool=macho(b"TEXT" * 8, b"cms-b" * 4, pad=48))
        _, result = self.run_compare(a, c)
        self.assertEqual(result["counts"]["only_cms_differs"], 0)
        self.assertIn("signature reservation (LC_CODE_SIGNATURE offset or size) differs",
                      json.dumps(result["signature_differences"]))


class ReviewFindingTests(unittest.TestCase):
    """Each payload difference the first review named must fail."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def compare(self, a: Path, b: Path) -> tuple[int, list]:
        out = self.root / "out.json"
        proc = subprocess.run([sys.executable, "-I", str(SCRIPT), str(a), str(b), str(out)],
                              capture_output=True, text=True)
        return proc.returncode, json.loads(out.read_text())["payload_failures"]

    def test_manifest_whitespace_is_payload(self):
        a = make_app(self.root / "a", tool=macho(b"T" * 32, b"c"))
        b = make_app(self.root / "b", tool=macho(b"T" * 32, b"d"))
        manifest = b / "Contents/Resources/bin/cmux-tui-ssh/manifest.json"
        manifest.write_text(json.dumps(json.loads(manifest.read_text()), indent=2))
        rc, failures = self.compare(a, b)
        self.assertEqual(rc, 1)
        self.assertTrue(any("manifest.json: payload differs" in f for f in failures), failures)

    def test_fat_cpu_subtype_and_thin_versus_fat_are_payload(self):
        thin = macho(b"T" * 32, b"c")
        a = make_app(self.root / "a", tool=fat(thin))
        b = make_app(self.root / "b", tool=fat(thin, subtype=2))
        self.assertEqual(self.compare(a, b)[0], 1)
        c = make_app(self.root / "c", tool=thin)
        self.assertEqual(self.compare(a, c)[0], 1)
        d = make_app(self.root / "d", tool=fat(macho(b"T" * 32, b"other-cms", 12, pad=8)))
        self.assertEqual(self.compare(a, d)[0], 0)

    def test_nonzero_fat_padding_fails(self):
        thin = macho(b"T" * 32, b"c")
        a = make_app(self.root / "a", tool=fat(thin))
        b = make_app(self.root / "b", tool=fat(thin, pad_byte=b"X"))
        rc, failures = self.compare(a, b)
        self.assertEqual(rc, 1)
        self.assertTrue(any("not zero padding" in f for f in failures), failures)

    def test_bytes_after_the_signature_are_payload(self):
        a = make_app(self.root / "a", tool=macho(b"T" * 32, b"c") + b"tail-a")
        b = make_app(self.root / "b", tool=macho(b"T" * 32, b"c") + b"tail-b")
        self.assertEqual(self.compare(a, b)[0], 1)

    def test_a_file_named_codesignature_is_payload(self):
        a = make_app(self.root / "a", tool=macho(b"T" * 32, b"c"))
        b = make_app(self.root / "b", tool=macho(b"T" * 32, b"c"))
        (a / "Contents/Resources/_CodeSignature").write_text("one")
        (b / "Contents/Resources/_CodeSignature").write_text("two")
        self.assertEqual(self.compare(a, b)[0], 1)

    def test_a_truncated_signature_fails(self):
        good = macho(b"T" * 32, b"c")
        a = make_app(self.root / "a", tool=good)
        b = make_app(self.root / "b", tool=good[:-10])
        rc, failures = self.compare(a, b)
        self.assertEqual(rc, 1)
        self.assertTrue(any("(B): LC_CODE_SIGNATURE points outside the slice" in f for f in failures), failures)

    def test_bytes_hidden_in_a_malformed_signature_fail(self):
        good = bytearray(macho(b"T" * 32, b"c", pad=16))
        sig_at = struct.unpack("<I", bytes(good[32 + 72 + 8:32 + 72 + 12]))[0]
        a = make_app(self.root / "a", tool=bytes(good))
        hidden = bytearray(good)
        hidden[-4:] = b"HIDE"  # in the zero padding after the superblob
        b = make_app(self.root / "b", tool=bytes(hidden))
        rc, failures = self.compare(a, b)
        self.assertEqual(rc, 1)
        self.assertTrue(any("not zero padding" in f for f in failures), failures)
        empty = bytearray(good)
        empty[sig_at + 8:sig_at + 12] = struct.pack(">I", 0)  # a superblob with no blobs
        c = make_app(self.root / "c", tool=bytes(empty))
        self.assertEqual(self.compare(a, c)[0], 1)

    def test_malformed_load_commands_fail_without_a_crash(self):
        good = macho(b"T" * 32, b"c")
        broken = bytearray(good)
        broken[16:20] = struct.pack("<I", 4000)  # ncmds far past the load commands
        a = make_app(self.root / "a", tool=bytes(broken))
        b = make_app(self.root / "b", tool=bytes(broken))
        rc, failures = self.compare(a, b)
        self.assertEqual(rc, 1)
        self.assertTrue(any("malformed Mach-O" in f or "LC_CODE_SIGNATURE" in f for f in failures), failures)

    def test_code_resources_on_one_side_only_is_reported_not_failed(self):
        a = make_app(self.root / "a", tool=macho(b"T" * 32, b"c"))
        b = make_app(self.root / "b", tool=macho(b"T" * 32, b"c"))
        (a / "Contents/_CodeSignature/CodeResources").unlink()
        out = self.root / "out.json"
        proc = subprocess.run([sys.executable, "-I", str(SCRIPT), str(a), str(b), str(out)], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(json.loads(out.read_text())["code_resources_differences"],
                         {"Contents/_CodeSignature/CodeResources": ["only in B"]})

    def test_a_four_byte_alignment_gap_after_the_index_is_a_valid_signature(self):
        # Rebuild the superblob as Apple lays out a CEF dylib's: index 12 + 8n, then 4 zero bytes.
        good = macho(b"T" * 32, b"c")
        sig_at = struct.unpack("<I", good[32 + 72 + 8:32 + 72 + 12])[0]
        blob = bytearray(good[sig_at:])
        count = struct.unpack(">I", bytes(blob[8:12]))[0]
        index_end = 12 + 8 * count
        for i in range(count):
            typ, at = struct.unpack(">II", bytes(blob[12 + 8 * i:20 + 8 * i]))
            blob[12 + 8 * i:20 + 8 * i] = struct.pack(">II", typ, at + 4)
        blob = blob[:index_end] + bytes(4) + blob[index_end:]
        blob[4:8] = struct.pack(">I", struct.unpack(">I", bytes(blob[4:8]))[0] + 4)
        aligned = bytearray(good[:sig_at]) + blob
        aligned[32 + 72 + 12:32 + 72 + 16] = struct.pack("<I", len(blob))
        a = make_app(self.root / "a", tool=bytes(aligned))
        b = make_app(self.root / "b", tool=good)
        rc, failures = self.compare(a, b)
        self.assertEqual(rc, 0, failures)
        hidden = bytearray(aligned)
        hidden[sig_at + index_end:sig_at + index_end + 4] = b"HIDE"
        c = make_app(self.root / "c", tool=bytes(hidden))
        self.assertEqual(self.compare(b, c)[0], 1)

    def test_input_signature_residue_passes_only_with_matching_input(self):
        # codesign over a linker-signed input: the old signature's bytes stay past the new superblob.
        good = bytearray(macho(b"T" * 32, b"c", pad=16))
        sig_at = struct.unpack("<I", bytes(good[32 + 72 + 8:32 + 72 + 12]))[0]
        old = bytes(good)
        old_tail = bytearray(old)
        old_tail[-16:] = b"OLDSIGNATUREDATA"
        residue = bytearray(good)
        residue[-16:] = b"OLDSIGNATUREDATA"
        a = make_app(self.root / "a", tool=bytes(residue))
        b = make_app(self.root / "b", tool=bytes(good))
        u = make_app(self.root / "u", tool=bytes(old_tail))
        self.assertEqual(self.compare(a, b)[0], 1)
        out = self.root / "out.json"
        proc = subprocess.run([sys.executable, "-I", str(SCRIPT), str(a), str(b), str(out), "--input", str(u)],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("input-signature residue (A): Contents/MacOS/Demo: 16 bytes", proc.stdout)
        other = bytearray(old_tail)
        other[-16:] = b"SOMETHINGELSE!!!"
        v = make_app(self.root / "v", tool=bytes(other))
        proc = subprocess.run([sys.executable, "-I", str(SCRIPT), str(a), str(b), str(out), "--input", str(v)],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 1)

    def test_setuid_bit_is_payload(self):
        a = make_app(self.root / "a", tool=macho(b"T" * 32, b"c"))
        b = make_app(self.root / "b", tool=macho(b"T" * 32, b"c"), mode=0o4755)
        rc, failures = self.compare(a, b)
        self.assertEqual(rc, 1)
        self.assertTrue(any("Contents/MacOS/Demo: payload differs (mode)" in f for f in failures), failures)


if __name__ == "__main__":
    unittest.main()
