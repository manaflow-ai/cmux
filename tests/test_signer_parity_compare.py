"""Tests for scripts/ci/signer_parity_compare.py (the codesign/rcodesign payload compare)."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import plistlib
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "ci" / "signer_parity_compare.py"
SPEC = importlib.util.spec_from_file_location("signer_parity_compare", SCRIPT)
spc = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(spc)


def code_directory(identifier: bytes, page_shift: int, code_hash: bytes, resources_hash: bytes | None = None) -> bytes:
    """A CodeDirectory; with resources_hash, special slots 1-3 with that CodeResources hash in slot 3."""
    ident_off = 44
    special = resources_hash + bytes(64) if resources_hash else b""
    hash_off = ident_off + len(identifier) + 1 + len(special)
    body = identifier + b"\0" + special + code_hash
    header = struct.pack(">IIIIIIIIIBBBBI", 0xFADE0C02, 44 + len(body), 0x20001, 0x10000,
                         hash_off, ident_off, 3 if special else 0, 1, 64, 32, 2, 0, page_shift, 0)
    return header + body


def macho(text: bytes, cms, page_shift: int = 12, pad: int = 0, resources_hash: bytes | None = None,
          reserve: int = 0) -> bytes:
    """A thin arm64 Mach-O: __LINKEDIT, LC_CODE_SIGNATURE, `text`, then a superblob.
    cms is the CMS bytes, or a function from the CodeDirectory to them; reserve
    pads the superblob to that size, as a signer reserves a fixed space."""
    sizeofcmds = 72 + 16
    dataoff = 32 + sizeofcmds + len(text)
    cd = code_directory(b"com.example.tool", page_shift, hashlib.sha256(text).digest(), resources_hash)
    cms = cms(cd) if callable(cms) else cms
    blobs = [(0, cd), (0x10000, struct.pack(">II", 0xFADE0B01, 8 + len(cms)) + cms)]
    index_len = 12 + 8 * len(blobs)
    index, payload, off = b"", b"", index_len
    for typ, blob in blobs:
        index += struct.pack(">II", typ, off)
        payload += blob
        off += len(blob)
    # As codesign writes it: the superblob, then zero padding up to datasize.
    pad = max(pad, reserve - index_len - len(payload))
    superblob = struct.pack(">III", 0xFADE0CC0, index_len + len(payload), len(blobs)) + index + payload + bytes(pad)
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 2, sizeofcmds, 0, 0)
    linkedit = struct.pack("<II16sQQQQiiII", 0x19, 72, b"__LINKEDIT", 0x4000, 0x1000 + len(superblob),
                           0, dataoff + len(superblob), 1, 1, 0, 0)
    signature = struct.pack("<IIII", 0x1D, 16, dataoff, len(superblob))
    return header + linkedit + signature + text + superblob


def make_app(root: Path, *, tool, resources: dict | None = None, link: str = "Versions/A",
             manifest_extra: str = "", mode: int = 0o755, nested: bytes | None = None) -> Path:
    """tool is the main executable's bytes, or a function from the CodeResources bytes to them."""
    app = root / "Demo.app" / "Contents"
    (app / "MacOS").mkdir(parents=True)
    (app / "_CodeSignature").mkdir()
    resources_bytes = plistlib.dumps(resources or {"files": {}})
    (app / "_CodeSignature" / "CodeResources").write_bytes(resources_bytes)
    tool = tool(resources_bytes) if callable(tool) else tool
    nested = nested if nested is not None else tool
    (app / "Info.plist").write_text("<plist>info</plist>")
    exe = app / "MacOS" / "Demo"
    exe.write_bytes(tool)
    exe.chmod(mode)
    os.symlink(link, app / "Current")
    ssh = app / "Resources" / "bin" / "cmux-tui-ssh"
    ssh.mkdir(parents=True)
    (ssh / "cmux-tui-darwin-arm64").write_bytes(nested)
    digest = hashlib.sha256(nested).hexdigest()
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


# --strict: a small DER writer builds real CMS signatures, signed with openssl.

def tlv(tag: int, body: bytes) -> bytes:
    n = len(body)
    size = bytes([n]) if n < 0x80 else bytes([0x80 | ((n.bit_length() + 7) // 8)]) + n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([tag]) + size + body


def der_oid(dotted: str) -> bytes:
    arcs = [int(x) for x in dotted.split(".")]
    body = b""
    for arc in [40 * arcs[0] + arcs[1]] + arcs[2:]:
        chunk = [arc & 0x7F]
        while arc > 0x7F:
            arc >>= 7
            chunk.insert(0, 0x80 | (arc & 0x7F))
        body += bytes(chunk)
    return tlv(0x06, body)


def seq(*items: bytes) -> bytes:
    return tlv(0x30, b"".join(items))


def der_set(*items: bytes) -> bytes:
    return tlv(0x31, b"".join(sorted(items)))


def attribute(dotted: str, value: bytes) -> bytes:
    return seq(der_oid(dotted), der_set(value))


SHA256 = seq(der_oid("2.16.840.1.101.3.4.2.1"), tlv(0x05, b""))
RSA = seq(der_oid("1.2.840.113549.1.1.1"), tlv(0x05, b""))


class Signer:
    """A throwaway RSA key and self-signed certificate, made with openssl."""

    def __init__(self, folder: Path):
        self.key, cert = folder / "key.pem", folder / "cert.der"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(self.key),
                        "-outform", "DER", "-out", str(cert), "-subj", "/CN=parity test", "-days", "1"],
                       check=True, capture_output=True)
        self.cert = cert.read_bytes()
        tbs = spc.read_tlv(self.cert)[0].children[0].children
        self.issuer_serial = seq(spc.der(tbs[3]), spc.der(tbs[1]))

    def cms(self, cd: bytes, *, time: str = "261028120000Z", extra_signed: bytes = b"", unsigned=None) -> bytes:
        """A detached CMS SignedData over a CodeDirectory, as a code signature carries it."""
        signed = [attribute("1.2.840.113549.1.9.3", der_oid("1.2.840.113549.1.7.1")),
                  attribute(spc.SIGNING_TIME, tlv(0x17, time.encode())),
                  attribute("1.2.840.113549.1.9.4", tlv(0x04, hashlib.sha256(cd).digest())),
                  attribute(spc.APPLE_CDHASHES_PLIST,
                            tlv(0x04, plistlib.dumps({"cdhashes": [hashlib.sha256(cd).digest()[:20]]})))]
        signed += [extra_signed] if extra_signed else []
        attrs = der_set(*signed)
        signature = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(self.key)], input=attrs,
                                   check=True, capture_output=True).stdout
        unsigned = [attribute(spc.TIMESTAMP_TOKEN, seq(tlv(0x04, b"token at " + time.encode())))] \
            if unsigned is None else unsigned
        info = seq(tlv(0x02, b"\x01"), self.issuer_serial, SHA256, b"\xa0" + attrs[1:], RSA, tlv(0x04, signature),
                   tlv(0xA1, b"".join(unsigned)) if unsigned else b"")
        body = seq(tlv(0x02, b"\x01"), der_set(SHA256), seq(der_oid("1.2.840.113549.1.7.1")),
                   tlv(0xA0, self.cert), der_set(info))
        return seq(der_oid("1.2.840.113549.1.7.2"), tlv(0xA0, body))


def indefinite(cms: bytes) -> bytes:
    """The same CMS with its outer SEQUENCE in BER indefinite-length form."""
    node, _ = spc.read_tlv(cms)
    return b"\x30\x80" + b"".join(spc.der(c) for c in node.children) + b"\0\0"


NESTED = "Contents/Resources/bin/cmux-tui-ssh/cmux-tui-darwin-arm64"


class DerReaderTests(unittest.TestCase):
    def test_der_round_trips_and_oids_decode(self):
        data = seq(der_oid("1.2.840.113549.1.9.16.2.14"), tlv(0x04, b"x" * 200), der_set(tlv(0x02, b"\x05")))
        node, end = spc.read_tlv(data)
        self.assertEqual(end, len(data))
        self.assertEqual(spc.der(node), data)
        self.assertEqual(spc.oid(node.children[0]), "1.2.840.113549.1.9.16.2.14")
        self.assertEqual(spc.framing_issues(node), [])

    def test_ber_framing_reads_as_the_same_content_and_is_named(self):
        der_form = seq(tlv(0x04, b"abcdef"))
        ber_form = b"\x30\x80" + b"\x24\x80" + tlv(0x04, b"abc") + tlv(0x04, b"def") + b"\0\0" + b"\0\0"
        node, end = spc.read_tlv(ber_form)
        self.assertEqual(end, len(ber_form))
        self.assertEqual(spc.der(node), der_form)
        issues = spc.framing_issues(node)
        self.assertIn("SEQUENCE: indefinite length", issues)
        self.assertTrue(any("constructed (chunked) string" in i for i in issues), issues)
        long_form = b"\x04\x81\x03abc"  # a long-form length for a short string
        self.assertEqual(spc.read_tlv(long_form)[0].issues, ["non-minimal length"])
        unsorted = b"\x31\x06" + tlv(0x02, b"\x09") + tlv(0x02, b"\x01")
        self.assertIn("SET: SET OF elements not in DER order", spc.framing_issues(spc.read_tlv(unsorted)[0]))

    def test_truncated_input_raises(self):
        for bad in (b"\x30", b"\x30\x05\x02\x01", b"\x30\x80\x02\x01\x01"):
            with self.assertRaises(ValueError):
                spc.read_tlv(bad)


@unittest.skipUnless(shutil.which("openssl"), "openssl makes the test signatures")
class StrictModeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.keys = tempfile.TemporaryDirectory()
        cls.signer = Signer(Path(cls.keys.name))

    @classmethod
    def tearDownClass(cls):
        cls.keys.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def app(self, name: str, time: str = "261028120000Z", other: str = "data", **cms):
        """An app whose main executable seals its CodeResources, which lists a nested
        signed Mach-O and a plain file; both Mach-O files are signed at `time`."""
        nested = macho(b"N" * 32, lambda cd: self.signer.cms(cd, time=time, **cms), reserve=4096)
        resources = {"files2": {"Resources/bin/cmux-tui-ssh/cmux-tui-darwin-arm64": {"hash2": hashlib.sha256(nested).digest()},
                                "Resources/other": {"hash2": hashlib.sha256(other.encode()).digest()}}}
        tool = lambda sealed: macho(b"TEXT" * 8, lambda cd: self.signer.cms(cd, time=time, **cms),
                                    resources_hash=hashlib.sha256(sealed).digest(), reserve=4096)
        app = make_app(self.root / name, tool=tool, resources=resources, nested=nested)
        (app / "Contents/Resources/other").write_text("data")
        return app

    def strict(self, a: Path, b: Path, env=None):
        out = self.root / "out.json"
        proc = subprocess.run([sys.executable, "-I", str(SCRIPT), str(a), str(b), str(out), "--strict"],
                              capture_output=True, text=True, env=env)
        return proc, json.loads(out.read_text())

    def test_signing_time_and_timestamp_only_pass(self):
        a, b = self.app("a"), self.app("b", time="261028130500Z")
        proc, result = self.strict(a, b)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertTrue(proc.stdout.rstrip().endswith("strict parity: PASS"), proc.stdout)
        self.assertIn(f"PASS {NESTED}: differs only by the signing time", proc.stdout)
        self.assertIn("PASS Contents/_CodeSignature/CodeResources: differs only by the signing time", proc.stdout)
        self.assertEqual(result["strict"]["differences"], 0)
        proc, _ = self.strict(a, a)
        self.assertIn("strict parity: PASS", proc.stdout)

    def test_another_signed_attribute_fails_and_default_mode_still_passes(self):
        a = self.app("a")
        b = self.app("b", time="261028130500Z", extra_signed=attribute("1.2.840.113549.1.9.15", seq()))
        proc, _ = self.strict(a, b)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("signed attributes differ", proc.stdout)
        self.assertRegex(proc.stdout, r"strict parity: FAIL \(\d+ differences\)")
        out = self.root / "default.json"
        self.assertEqual(subprocess.run([sys.executable, "-I", str(SCRIPT), str(a), str(b), str(out)],
                                        capture_output=True).returncode, 0)

    def test_unsigned_attributes_other_than_the_timestamp_fail(self):
        stamp = attribute(spc.TIMESTAMP_TOKEN, seq())
        a = self.app("a")
        b = self.app("b", unsigned=[stamp, attribute("1.2.840.113549.1.9.6", seq())])
        proc, _ = self.strict(a, b)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("unsigned attributes other than one timestamp token", proc.stdout)
        c = self.app("c", unsigned=[])
        proc, _ = self.strict(a, c)
        self.assertIn("a timestamp token only in A", proc.stdout)

    def test_ber_framing_of_the_same_cms_fails_as_framing_only(self):
        a = self.app("a")
        b = self.app("b")
        exe = b / "Contents/MacOS/Demo"
        original = exe.read_bytes()
        cms = self.signer_cms_of(original)
        reframed = original.replace(cms, indefinite(cms))  # 30 82 LL LL becomes 30 80 ... 00 00: same length
        self.assertEqual(len(reframed), len(original))
        exe.write_bytes(reframed)
        proc, _ = self.strict(a, b)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("FAIL Contents/MacOS/Demo", proc.stdout)
        self.assertIn("framing only", proc.stdout)

    def signer_cms_of(self, body: bytes) -> bytes:
        return spc.blobs(body)[0x10000][8:]

    def test_a_signature_that_does_not_verify_fails(self):
        a, b = self.app("a"), self.app("b")
        exe = b / "Contents/MacOS/Demo"
        body = exe.read_bytes()
        cms = self.signer_cms_of(body)
        signature = spc.parse_cms(cms)["signers"][0]["signature"].value
        exe.write_bytes(body.replace(signature, signature[:-1] + bytes([signature[-1] ^ 1])))
        proc, _ = self.strict(a, b)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("CMS (B): does not verify", proc.stdout)

    def test_without_openssl_strict_mode_fails_closed(self):
        a, b = self.app("a"), self.app("b", time="261028130500Z")
        empty = self.root / "empty-path"
        empty.mkdir()
        proc, _ = self.strict(a, b, env={"PATH": str(empty)})
        self.assertEqual(proc.returncode, 1)
        self.assertIn("openssl is not available", proc.stdout)

    def test_a_code_resources_hash_not_from_a_signing_time_fails(self):
        a, b = self.app("a"), self.app("b", time="261028130500Z", other="changed")
        proc, _ = self.strict(a, b)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("files2/Resources/other: hash2", proc.stdout)
        self.assertIn("CodeResources hash slot differs", proc.stdout)
        self.assertIn(f"PASS {NESTED}", proc.stdout)

    def test_a_different_code_directory_field_fails(self):
        a = make_app(self.root / "a", tool=macho(b"T" * 32, lambda cd: self.signer.cms(cd), page_shift=12))
        b = make_app(self.root / "b", tool=macho(b"T" * 32, lambda cd: self.signer.cms(cd), page_shift=14))
        proc, _ = self.strict(a, b)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("CodeDirectory: pageSize differ", proc.stdout)


if __name__ == "__main__":
    unittest.main()
