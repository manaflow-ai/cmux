#!/usr/bin/env python3
"""Compares two signings of the same unsigned .app: the payload must be byte-identical.

    signer_parity_compare.py A.app B.app OUT.json [--labels codesign,rcodesign] [--report OUT.md]

The payload is every path of the bundle except what a code signature writes:
  - anything inside a _CodeSignature directory (CodeResources and the
    detached signature files);
  - in each Mach-O slice, the LC_CODE_SIGNATURE blob and the 3 size fields
    that follow its size only (the __LINKEDIT vmsize and filesize and the
    LC_CODE_SIGNATURE datasize). Every byte before and after the blob is payload;
  - in a universal file, each slice's offset and size in the fat header (they
    move with the slice sizes). The rest of the header (magic, count, CPU type
    and subtype, alignment) is payload, a thin file never equals a fat one, and
    the bytes between slices must be zero padding on both sides;
  - the sha256 checksums of signed Mach-O payloads in a cmux-tui-ssh
    manifest.json (signing re-pins them): each must be the sha256 of its file
    in that tree and appear exactly once, and is replaced by a placeholder of
    the same length; every other byte of the raw manifest is payload.
Every other byte, every file mode (all 12 bits: setuid, setgid and sticky too)
and every symlink target is payload, and one differing byte fails the compare
(exit 1).

The signature report lists, for every Mach-O slice, which CodeDirectory fields
and signature blobs differ between A and B, and for every CodeResources which
entries differ; those differences are reported, not failed.

STRICT MODE (--strict) fails on every difference except the signing time:
  - the CMS SignedData must have the same certificates, signer identifier,
    digest and signature algorithms, and signed attributes; only signingTime
    (1.2.840.113549.1.9.5) may differ. The messageDigest and CodeDirectory-hash
    attributes are compared with each side's own CodeDirectory digests named,
    so they may differ only where the CodeDirectories may, and each must hold
    only digests of its own side's CodeDirectories. The signature value may
    differ only when the signed attributes do. Each side's signature must
    verify against its own leaf certificate (openssl cms -verify -noverify,
    over its CodeDirectory), identical ones included; without openssl it fails;
  - the only unsigned attribute allowed is one timestamp token
    (1.2.840.113549.1.9.16.2.14), on both sides or neither; its contents may differ;
  - the same content framed differently (BER versus DER) fails, reported as
    framing only;
  - every other signature blob must be byte-identical, except a
    CodeDirectory's CodeResources hash slot, and a CodeResources entry may
    differ only by the hash of a nested item (a Mach-O, a CodeResources) that
    itself passes strict mode; then those hashes compare as equal;
  - a _CodeSignature directory must sit where a bundle signature goes, hold
    the same regular files on both sides, and match byte for byte but for
    CodeResources; missing or malformed inputs fail, never crash.
An item that differs only by framing, or by hashes of such items, is labelled
framing only in the report; it still fails.
The report ends with `strict parity: PASS` or `strict parity: FAIL (<n> differences)`.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import stat
import struct
import sys

FAT_MAGICS = {0xCAFEBABE: False, 0xCAFEBABF: True}
MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64, LC_CODE_SIGNATURE = 0x19, 0x1D
CPU = {0x01000007: "x86_64", 0x0100000C: "arm64"}
BLOB = {0: "CodeDirectory", 2: "Requirements", 5: "Entitlements (XML)", 7: "Entitlements (DER)",
        0x1000: "CodeDirectory (alternate)", 0x10000: "CMS signature"}
SPECIAL = {1: "Info.plist hash", 2: "Requirements hash", 3: "CodeResources hash",
           5: "Entitlements (XML) hash", 7: "Entitlements (DER) hash"}


def fat_header(data: bytes):
    """The fat header with each slice's offset and size zeroed (they move with the
    slice sizes), and whether every byte outside the slices is zero padding; None
    for a thin file."""
    magic = struct.unpack(">I", data[:4])[0]
    if magic not in FAT_MAGICS:
        return None
    count = struct.unpack(">I", data[4:8])[0]
    wide = FAT_MAGICS[magic]
    width = 32 if wide else 20
    head = bytearray(data[:8 + width * count])
    covered = [(0, len(head))]
    for i in range(count):
        at = 8 + width * i
        if wide:
            _, _, off, size, _, _ = struct.unpack(">iiQQII", data[at:at + width])
            head[at + 8:at + 24] = bytes(16)
        else:
            _, _, off, size, _ = struct.unpack(">iiIII", data[at:at + width])
            head[at + 8:at + 16] = bytes(8)
        covered.append((off, off + size))
    padding_is_zero, pos = True, 0
    for start, end in sorted(covered):
        if start > pos and data[pos:start].strip(b"\0"):
            padding_is_zero = False
        pos = max(pos, end)
    if data[pos:].strip(b"\0"):
        padding_is_zero = False
    return bytes(head), padding_is_zero


def slices(data: bytes):
    """[(arch, slice bytes)] for a Mach-O file, or None for anything else."""
    if len(data) < 8:
        return None
    magic = struct.unpack(">I", data[:4])[0]
    if magic in FAT_MAGICS:
        count = struct.unpack(">I", data[4:8])[0]
        if not 0 < count < 20:
            return None  # a Java class file shares the magic
        wide, out = FAT_MAGICS[magic], []
        for i in range(count):
            if wide:
                cpu, _, off, size, _, _ = struct.unpack(">iiQQII", data[8 + 32 * i:40 + 32 * i])
            else:
                cpu, _, off, size, _ = struct.unpack(">iiIII", data[8 + 20 * i:28 + 20 * i])
            out.append((CPU.get(cpu & 0xFFFFFFFF, hex(cpu & 0xFFFFFFFF)), data[off:off + size]))
        return out
    if struct.unpack("<I", data[:4])[0] == MH_MAGIC_64:
        cpu = struct.unpack("<i", data[4:8])[0]
        return [(CPU.get(cpu & 0xFFFFFFFF, hex(cpu & 0xFFFFFFFF)), data)]
    return None


def signature_range(macho: bytes, residue_source: bytes | None = None):
    """(dataoff, datasize) of LC_CODE_SIGNATURE, or None when there is none.
    Raises ValueError when it points outside the slice or its blob is not a
    complete embedded-signature superblob."""
    ncmds, sizeofcmds = struct.unpack("<II", macho[16:24])
    if 32 + sizeofcmds > len(macho) or ncmds * 8 > sizeofcmds:
        raise ValueError("malformed Mach-O: the load commands do not fit the file")
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", macho[off:off + 8])
        if size < 8 or off + size > 32 + sizeofcmds:
            raise ValueError("malformed Mach-O: a load command smaller than its header, or past the load commands")
        if cmd == LC_CODE_SIGNATURE:
            dataoff, datasize = struct.unpack("<II", macho[off + 8:off + 16])
            if datasize < 12 or dataoff + datasize > len(macho):
                raise ValueError("LC_CODE_SIGNATURE points outside the slice")
            # The region left out of the payload must hold signature data only:
            # a superblob whose index is followed by its blobs back to back
            # (alignment gaps of up to 7 zero bytes allowed),
            # with a CodeDirectory among them, then zero padding to datasize.
            magic, length, count = struct.unpack(">III", macho[dataoff:dataoff + 12])
            if magic != 0xFADE0CC0 or not 12 + 8 * count <= length <= datasize or count == 0:
                raise ValueError("the signature is not a complete embedded-signature superblob")
            entries = sorted(struct.unpack(">II", macho[dataoff + 12 + 8 * i:dataoff + 20 + 8 * i])[::-1]
                             for i in range(count))
            at, types = 12 + 8 * count, set()
            for blob_at, typ in entries:
                blob_magic, blob_length = struct.unpack(">II", macho[dataoff + blob_at:dataoff + blob_at + 8])
                # Apple pads blobs to 8-byte alignment (a CEF dylib's first blob is at
                # 24 after a 20-byte index): a gap of up to 7 zero bytes only.
                gap = macho[dataoff + at:dataoff + blob_at] if blob_at >= at else b"x"
                if len(gap) > 7 or gap.strip(b"\0") or blob_length < 8 or blob_at + blob_length > length \
                        or blob_magic >> 16 != 0xFADE:  # every code-signing blob magic is 0xFADExxxx
                    raise ValueError("the signature's blobs are not back to back after its index")
                at = blob_at + blob_length
                types.add(typ)
            tail = macho[dataoff + at:dataoff + length] if length >= at else b"x"
            if len(tail) > 7 or tail.strip(b"\0") or 0 not in types:
                raise ValueError("the signature has bytes outside its blobs, or no CodeDirectory")
            rest = macho[dataoff + length:dataoff + datasize]
            if rest.strip(b"\0"):
                # codesign writes its signature over the input's own (the
                # linker's ad hoc one) and leaves the old bytes past its new
                # superblob. Each byte there must be zero padding or the
                # input's byte at the same offset; nothing past the superblob
                # is hashed or signed, so a zero is padding either way.
                old = residue_source[dataoff + length:dataoff + datasize] if residue_source else b""
                if any(r != 0 and (k >= len(old) or r != old[k]) for k, r in enumerate(rest)):
                    raise ValueError("the bytes after the signature superblob are not zero padding"
                                     + (" or the input's own bytes" if residue_source else ""))
                RESIDUE.append(len(rest.rstrip(b"\0")))
            return dataoff, datasize
        off += size
    return None


RESIDUE: list = []  # sizes of input-signature residue accepted for the current file


def code_signature_command(macho: bytes):
    """(dataoff, datasize) of LC_CODE_SIGNATURE as written, unchecked; describe()
    checks it with signature_range() before payload() or blobs() reads it."""
    ncmds, sizeofcmds = struct.unpack("<II", macho[16:24])
    if 32 + sizeofcmds > len(macho) or ncmds * 8 > sizeofcmds:
        raise ValueError("malformed Mach-O: the load commands do not fit the file")
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", macho[off:off + 8])
        if size < 8 or off + size > 32 + sizeofcmds:
            raise ValueError("malformed Mach-O: a load command smaller than its header, or past the load commands")
        if cmd == LC_CODE_SIGNATURE:
            return struct.unpack("<II", macho[off + 8:off + 16])
        off += size
    return None


def payload(macho: bytes) -> bytes:
    """The slice bytes before its signature, with the 3 signature-size fields zeroed."""
    sig = code_signature_command(macho)
    out = bytearray(macho[:sig[0]] if sig else macho)
    # Bytes after the signature blob (none in a well-formed file) stay payload.
    trailer = macho[sig[0] + sig[1]:] if sig else b""
    ncmds, sizeofcmds = struct.unpack("<II", macho[16:24])
    if 32 + sizeofcmds > len(macho) or ncmds * 8 > sizeofcmds:
        raise ValueError("malformed Mach-O: the load commands do not fit the file")
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", macho[off:off + 8])
        if size < 8 or off + size > 32 + sizeofcmds:
            raise ValueError("malformed Mach-O: a load command smaller than its header, or past the load commands")
        if cmd == LC_SEGMENT_64 and macho[off + 8:off + 24].rstrip(b"\0") == b"__LINKEDIT":
            out[off + 32:off + 40] = bytes(8)  # vmsize
            out[off + 48:off + 56] = bytes(8)  # filesize
        if cmd == LC_CODE_SIGNATURE:
            out[off + 12:off + 16] = bytes(4)  # datasize
        off += size
    return bytes(out) + b"\0TRAILER\0" + trailer


def blobs(macho: bytes) -> dict:
    sig = code_signature_command(macho)
    if not sig:
        return {}
    blob = macho[sig[0]:sig[0] + sig[1]]
    if len(blob) < 12:
        return {}
    count = struct.unpack(">I", blob[8:12])[0]
    out = {}
    for i in range(count):
        typ, off = struct.unpack(">II", blob[12 + 8 * i:20 + 8 * i])
        length = struct.unpack(">I", blob[off + 4:off + 8])[0]
        out[typ] = blob[off:off + length]
    return out


def code_directory(cd: bytes) -> dict:
    (_, _, version, flags, hash_off, ident_off, n_special, n_code, code_limit, hash_size,
     hash_type, platform, page_size, _) = struct.unpack(">IIIIIIIIIBBBBI", cd[:44])
    fields = {"version": hex(version), "flags": hex(flags),
              "identifier": cd[ident_off:].split(b"\0", 1)[0].decode("utf-8", "replace"),
              "hashType": hash_type, "platform": platform, "pageSize": 1 << page_size if page_size else 0,
              "codeLimit": code_limit, "nCodeSlots": n_code}
    if version >= 0x20200 and len(cd) >= 52:
        team = struct.unpack(">I", cd[48:52])[0]
        fields["team"] = cd[team:].split(b"\0", 1)[0].decode("utf-8", "replace") if team else ""
    if version >= 0x20400 and len(cd) >= 88:
        fields["execSeg base,limit,flags"] = list(struct.unpack(">QQQ", cd[64:88]))
    if version >= 0x20500 and len(cd) >= 92:
        fields["runtime"] = hex(struct.unpack(">I", cd[88:92])[0])
    for k in range(1, n_special + 1):
        slot = cd[hash_off - k * hash_size:hash_off - (k - 1) * hash_size]
        if slot.strip(b"\0"):
            fields[SPECIAL.get(k, f"special slot {k}")] = slot.hex()
    fields["code page hashes"] = hashlib.sha256(cd[hash_off:hash_off + n_code * hash_size]).hexdigest()
    fields["CDHash (sha256)"] = hashlib.sha256(cd).hexdigest()
    return fields


def outside_cms(a: bytes, b: bytes) -> list:
    """Whether two signed slices differ anywhere but in their CMS blob: the
    reservation fields, and every byte outside the CMS and the superblob's
    length field, compared directly."""
    sa, sb = code_signature_command(a), code_signature_command(b)
    if sa[0] != sb[0] or sa[1] != sb[1]:
        return ["signature reservation (LC_CODE_SIGNATURE offset or size) differs"]
    if len(a) != len(b):
        return ["slice length differs"]

    def cms_start(m):
        blob = m[sa[0]:sa[0] + sa[1]]
        count = struct.unpack(">I", blob[8:12])[0]
        for i in range(count):
            typ, off = struct.unpack(">II", blob[12 + 8 * i:20 + 8 * i])
            if typ == 0x10000:
                return sa[0] + off
        return None

    ca, cb = cms_start(a), cms_start(b)
    if ca is None or ca != cb:
        return ["the CMS blob starts at a different offset"]
    end = sa[0] + max(struct.unpack(">I", a[sa[0] + 4:sa[0] + 8])[0], struct.unpack(">I", b[sa[0] + 4:sa[0] + 8])[0])

    def masked(m):
        x = bytearray(m)
        x[sa[0] + 4:sa[0] + 8] = bytes(4)
        x[ca:end] = bytes(end - ca)
        return bytes(x)

    return [] if masked(a) == masked(b) else ["bytes outside the CMS blob differ"]


def signature_diff(a: bytes, b: bytes) -> list:
    out = outside_cms(a, b)
    ba, bb = blobs(a), blobs(b)
    for typ in sorted(set(ba) | set(bb)):
        name = BLOB.get(typ, hex(typ))
        if typ not in ba or typ not in bb:
            out.append(f"{name}: only in {'A' if typ in ba else 'B'}")
        elif ba[typ] != bb[typ]:
            if typ in (0, 0x1000):
                fa, fb = code_directory(ba[typ]), code_directory(bb[typ])
                diff = {k: [fa.get(k), fb.get(k)] for k in sorted(set(fa) | set(fb)) if fa.get(k) != fb.get(k)}
                out.append({name: diff})
            else:
                out.append(f"{name}: differs ({len(ba[typ])} / {len(bb[typ])} bytes)")
    return out


def is_ssh_manifest(rel: str) -> bool:
    return rel.endswith("Contents/Resources/bin/cmux-tui-ssh/manifest.json")


def manifest_payload(root: str, rel: str, data: bytes):
    """The manifest's raw bytes with the checksum of each signed Mach-O payload
    replaced by a fixed placeholder of the same length (each must be the sha256
    of its file and appear exactly once); every other byte is compared."""
    manifest = json.loads(data)
    folder = os.path.dirname(os.path.join(root, rel))
    errors, out = [], data
    for name, digest in sorted(manifest.get("binaries", {}).items()):
        path = os.path.join(folder, name)
        if os.path.isfile(path) and not os.path.islink(path):
            with open(path, "rb") as handle:
                body = handle.read()
            if slices(body) is not None:
                actual = hashlib.sha256(body).hexdigest()
                if str(digest) != actual:
                    errors.append(f"{name}: manifest checksum is not the file's sha256")
                    continue
                if out.count(actual.encode()) != 1:
                    errors.append(f"{name}: its checksum appears {out.count(actual.encode())} times in the manifest")
                    continue
                out = out.replace(actual.encode(), b"S" * 64)
    return out, errors


def walk(root: str) -> dict:
    out = {}
    for directory, dirs, files in os.walk(root):
        dirs.sort()
        for name in sorted(dirs) + sorted(files):
            path = os.path.join(directory, name)
            rel = os.path.relpath(path, root)
            # Only the contents of a real _CodeSignature directory directly in
            # a bundle's Contents/ (or a framework version) are signature
            # output; a file or link of that name is payload like any other.
            parts = rel.split(os.sep)
            if any(p == "_CodeSignature" and os.path.isdir(os.path.join(root, *parts[:i + 1]))
                   and not os.path.islink(os.path.join(root, *parts[:i + 1]))
                   for i, p in enumerate(parts)):
                continue
            out[rel] = path
    return out


def input_slices(input_root: str | None, rel: str) -> dict:
    """The unsigned input's slices of the same path, by architecture."""
    if not input_root:
        return {}
    path = os.path.join(input_root, rel)
    if os.path.islink(path) or not os.path.isfile(path):
        return {}
    with open(path, "rb") as handle:
        data = handle.read()
    try:
        return dict(slices(data) or [])
    except struct.error:
        return {}


def describe(root: str, rel: str, path: str, input_root: str | None = None) -> dict:
    st = os.lstat(path)
    if stat.S_ISLNK(st.st_mode):
        return {"kind": "symlink", "target": os.readlink(path)}
    if stat.S_ISDIR(st.st_mode):
        return {"kind": "dir", "mode": oct(stat.S_IMODE(st.st_mode))}
    with open(path, "rb") as handle:
        data = handle.read()
    record = {"kind": "file", "mode": oct(stat.S_IMODE(st.st_mode)), "sha256": hashlib.sha256(data).hexdigest()}
    try:
        parts = slices(data)
    except struct.error:
        parts = None  # not a parseable Mach-O: its bytes are compared as they are
    if parts is not None:
        digest = hashlib.sha256()
        fat = fat_header(data)
        digest.update(b"thin\0" if fat is None else b"fat\0" + fat[0])
        if fat is not None and not fat[1]:
            record["padding_error"] = "bytes outside the fat slices are not zero padding"
        source = input_slices(input_root, rel)
        RESIDUE.clear()
        try:
            signed = all(signature_range(body, source.get(arch)) for arch, body in parts)
            for arch, body in parts:
                digest.update(arch.encode() + b"\0" + payload(body))
        except (ValueError, struct.error) as error:
            record["signature_error"] = str(error) if isinstance(error, ValueError) else f"malformed Mach-O ({error})"
            signed = False
            digest.update(b"invalid\0" + data)
        record.update(kind="macho", archs=[a for a, _ in parts], payload_sha256=digest.hexdigest(),
                      signed=signed)
        if RESIDUE:
            record["input_signature_residue_bytes"] = sum(RESIDUE)
        record["_slices"] = parts
    elif is_ssh_manifest(rel):
        body, errors = manifest_payload(root, rel, data)
        record.update(payload_sha256=hashlib.sha256(body).hexdigest(), manifest_errors=errors)
    else:
        record["payload_sha256"] = record["sha256"]
    return record


def code_resources_diff_values(pa, pb) -> list:
    """code_resources_diff() over two parsed property lists."""
    if not isinstance(pa, dict) or not isinstance(pb, dict):
        return [] if pa == pb else ["differs"]
    out = []
    for section in sorted(set(pa) | set(pb)):
        sa, sb = pa.get(section, {}), pb.get(section, {})
        if sa == sb:
            continue
        if not isinstance(sa, dict) or not isinstance(sb, dict):
            out.append(f"{section}: differs")
            continue
        for key in sorted(k for k in set(sa) | set(sb) if sa.get(k) != sb.get(k)):
            va, vb = sa.get(key), sb.get(key)
            if isinstance(va, dict) and isinstance(vb, dict):
                out.append(f"{section}/{key}: {', '.join(sorted(k for k in set(va) | set(vb) if va.get(k) != vb.get(k)))}")
            else:
                out.append(f"{section}/{key}: {'only A' if vb is None else 'only B' if va is None else 'differs'}")
    return out


def code_resources_diff(a: str, b: str) -> list:
    with open(a, "rb") as fa, open(b, "rb") as fb:
        ra, rb = fa.read(), fb.read()
    try:
        pa, pb = plistlib.loads(ra), plistlib.loads(rb)
    except Exception:  # not a plist: only its bytes can be compared
        return [] if ra == rb else ["not a property list; bytes differ"]
    return code_resources_diff_values(pa, pb)


# --strict: every difference fails except the signing time.

SIGNING_TIME = "1.2.840.113549.1.9.5"
TIMESTAMP_TOKEN = "1.2.840.113549.1.9.16.2.14"
MESSAGE_DIGEST = "1.2.840.113549.1.9.4"
APPLE_CDHASHES_PLIST = "1.2.840.113635.100.9.1"
APPLE_CDHASHES = "1.2.840.113635.100.9.2"
CD_HASH_ATTRIBUTES = {MESSAGE_DIGEST, APPLE_CDHASHES_PLIST, APPLE_CDHASHES}
CMS_WRAPPER_MAGIC = 0xFADE0B01
STRING_TAGS = {3, 4, 12, 19, 20, 22, 23, 24, 26, 30}  # universal string types BER may chunk
FRAMING = "framing only (the same content in a different BER/DER encoding): "
FRAMING_CASCADE = FRAMING + "differs only by hashes of nested items whose own differences are framing only"


class Node:
    """One BER/DER TLV: class, constructed bit, tag number, content and children,
    the encoding issues DER forbids in its own header, and its path in the tree."""

    def __init__(self, cls, constructed, number, path):
        self.cls, self.constructed, self.number, self.path = cls, constructed, number, path
        self.children, self.value, self.issues = [], b"", []

    def name(self):
        if self.cls == 0:
            return {1: "BOOLEAN", 2: "INTEGER", 3: "BIT STRING", 4: "OCTET STRING", 5: "NULL", 6: "OID",
                    16: "SEQUENCE", 17: "SET", 23: "UTCTime", 24: "GeneralizedTime"}.get(self.number, f"U{self.number}")
        return ("[%d]" if self.cls == 2 else "%s%%d" % "?AC?"[self.cls]) % self.number


def read_tlv(data: bytes, pos: int = 0, path: str = "", depth: int = 0):
    """(Node, next position) for the TLV at pos. Accepts BER (indefinite lengths,
    long-form lengths, chunked strings) and notes each non-DER form as an issue."""
    if depth > 64 or pos + 2 > len(data):
        raise ValueError("malformed DER: truncated")
    first = data[pos]
    pos += 1
    number = first & 0x1F
    tag_start = pos - 1
    if number == 0x1F:
        number = 0
        while True:
            if pos >= len(data):
                raise ValueError("malformed DER: truncated tag")
            number = (number << 7) | (data[pos] & 0x7F)
            pos += 1
            if not data[pos - 1] & 0x80:
                break
    node = Node(first >> 6, bool(first & 0x20), number, path)
    if number >= 0x1F and data[tag_start + 1] == 0x80 or number < 0x1F and first & 0x1F == 0x1F:
        node.issues.append(f"non-minimal tag ({data[tag_start:pos].hex()})")
    node.path = f"{path}/{node.name()}" if path else node.name()
    length_byte = data[pos]
    pos += 1
    if length_byte == 0x80:
        if not node.constructed:
            raise ValueError("malformed DER: indefinite length on a primitive")
        node.issues.append("indefinite length")
        while data[pos:pos + 2] != b"\0\0":
            child, pos = read_tlv(data, pos, f"{node.path}#{len(node.children)}", depth + 1)
            node.children.append(child)
            if pos + 2 > len(data):
                raise ValueError("malformed DER: unterminated indefinite length")
        end = pos + 2
    else:
        length = length_byte
        if length_byte & 0x80:
            count = length_byte & 0x7F
            raw = data[pos:pos + count]
            if len(raw) != count or count > 8:
                raise ValueError("malformed DER: bad length")
            length = int.from_bytes(raw, "big")
            pos += count
            if raw[:1] == b"\0" or length < 0x80:
                node.issues.append(f"non-minimal length ({length_byte:02x}{raw.hex()})")
        end = pos + length
        if end > len(data):
            raise ValueError("malformed DER: content runs past the end")
        if node.constructed:
            while pos < end:
                child, pos = read_tlv(data[:end], pos, f"{node.path}#{len(node.children)}", depth + 1)
                node.children.append(child)
        else:
            node.value = data[pos:end]
            node.issues += content_issues(node)
    if node.constructed and node.cls == 0 and node.number in STRING_TAGS:
        # Flattened to its value; the exact chunking stays in the issue, so two
        # different BER encodings of the same string never read as the same.
        node.issues.append("constructed (chunked) string, chunks " + ",".join(
            f"{c.number}:{len(c.value)}" + "".join(f"<{i}>" for i in c.issues) for c in node.children))
        node.value = b"".join(c.value for c in node.children)
        node.constructed, node.children = False, []
    return node, end


def content_issues(node: Node) -> list:
    """Non-DER encodings of a primitive's content that decode to the same value."""
    v = node.value
    if node.cls != 0:
        return []
    if node.number == 6:  # OID: no arc starts with 0x80, and the last byte ends an arc
        if not v or v[-1] & 0x80:
            raise ValueError("malformed DER: unterminated OBJECT IDENTIFIER")
        if any(b == 0x80 and (i == 0 or not v[i - 1] & 0x80) for i, b in enumerate(v)):
            return [f"non-minimal OBJECT IDENTIFIER ({v.hex()})"]
    if node.number in (2, 10) and len(v) > 1 and (v[0] == 0 and not v[1] & 0x80 or v[0] == 0xFF and v[1] & 0x80):
        return [f"non-minimal INTEGER ({v[:2].hex()}...)"]
    if node.number == 1 and v not in (b"\x00", b"\xff"):
        return [f"non-DER BOOLEAN ({v.hex()})"]
    if node.number == 5 and v:
        return ["NULL with content"]
    return []


def der(node: Node) -> bytes:
    """The node re-encoded as DER (definite minimal lengths, strings unchunked):
    two nodes with equal der() have the same content however they were framed."""
    body = b"".join(der(c) for c in node.children) if node.constructed else node.value
    if node.number < 0x1F:
        head = bytes([(node.cls << 6) | (0x20 if node.constructed else 0) | node.number])
    else:
        digits, n = [], node.number
        while True:
            digits.insert(0, (n & 0x7F) | (0x80 if digits else 0))
            n >>= 7
            if not n:
                break
        head = bytes([(node.cls << 6) | (0x20 if node.constructed else 0) | 0x1F] + digits)
    n = len(body)
    length = bytes([n]) if n < 0x80 else bytes([0x80 | ((n.bit_length() + 7) // 8)]) + n.to_bytes((n.bit_length() + 7) // 8, "big")
    return head + length + body


def oid(node: Node) -> str:
    if node.cls != 0 or node.number != 6 or not node.value:
        raise ValueError("malformed CMS: expected an OBJECT IDENTIFIER")
    arcs, n = [], 0
    for byte in node.value:
        n = (n << 7) | (byte & 0x7F)
        if not byte & 0x80:
            arcs.append(n)
            n = 0
    first = min(arcs[0] // 40, 2)
    return ".".join(str(a) for a in [first, arcs[0] - 40 * first] + arcs[1:])


def framing_issues(node: Node, skip=()) -> list:
    if any(node.path.startswith(s) for s in skip):
        return []
    out = [f"{node.path}: {issue}" for issue in node.issues]
    if node.cls == 0 and node.number == 17 or node.path.endswith("signedAttrs"):
        encoded = [der(c) for c in node.children]
        if encoded != sorted(encoded):
            order = hashlib.sha256(b"".join(hashlib.sha256(e).digest() for e in encoded)).hexdigest()[:16]
            out.append(f"{node.path}: SET OF elements not in DER order (order {order})")
    for child in node.children:
        out += framing_issues(child, skip)
    return out


def parse_cms(data: bytes) -> dict:
    """The parts of a CMS SignedData a code signature uses; ValueError when it is not one."""
    root, end = read_tlv(data)
    trailing = data[end:]
    if oid(root.children[0]) != "1.2.840.113549.1.7.2" or len(root.children) < 2:
        raise ValueError("malformed CMS: not SignedData")
    sd = root.children[1].children[0].children
    out = {"root": root, "trailing": trailing, "version": sd[0], "digestAlgorithms": sd[1], "encap": sd[2],
           "certificates": [], "crls": None, "signers": []}
    rest = sd[3:]
    if rest and rest[0].cls == 2 and rest[0].number == 0:
        out["certificates"] = rest.pop(0).children
    if rest and rest[0].cls == 2 and rest[0].number == 1:
        out["crls"] = rest.pop(0)
    if len(rest) != 1:
        raise ValueError("malformed CMS: expected one signerInfos SET")
    for info in rest[0].children:
        fields = list(info.children)
        signer = {"node": info, "version": fields.pop(0), "sid": fields.pop(0), "digestAlgorithm": fields.pop(0),
                  "signed": None, "unsigned": None}
        if fields and fields[0].cls == 2 and fields[0].number == 0:
            signer["signed"] = fields.pop(0)
            signer["signed"].path += " signedAttrs"
        signer["signatureAlgorithm"], signer["signature"] = fields.pop(0), fields.pop(0)
        if fields and fields[0].cls == 2 and fields[0].number == 1:
            signer["unsigned"] = fields.pop(0)
        if fields:
            raise ValueError("malformed CMS: unexpected SignerInfo fields")
        out["signers"].append(signer)
    return out


def attributes(node) -> list:
    """[(oid, values node)] of a signed or unsigned attribute set."""
    return [(oid(a.children[0]), a.children[1]) for a in (node.children if node else [])]


def hash_names(blob: bytes, label: str) -> dict:
    """Every digest a signature may record of blob (full and truncated to 20 bytes), named by label."""
    out = {}
    for alg in ("sha1", "sha256", "sha384", "sha512"):
        digest = hashlib.new(alg, blob).digest()
        out[digest] = f"<{alg} of {label}>"
        out.setdefault(digest[:20], f"<{alg}[:20] of {label}>")
    return out


def named(value, names: dict):
    """value (bytes, or a plist of bytes) with each digest in names replaced by its name."""
    if isinstance(value, bytes):
        for digest in sorted(names, key=len, reverse=True):
            name = names[digest]
            value = value.replace(digest, name if isinstance(name, bytes) else name.encode())
        return value
    if isinstance(value, dict):
        return {k: named(v, names) for k, v in value.items()}
    if isinstance(value, list):
        return [named(v, names) for v in value]
    return value


def attribute_value(attr_oid: str, values: Node, names: dict):
    """An attribute's content for comparison. In the CodeDirectory-hash attributes
    (messageDigest, Apple's cdhashes) the side's own CodeDirectory digests are
    named, so two signatures whose CodeDirectories differ only in allowed ways
    compare equal; every other attribute is compared as it is."""
    if attr_oid not in CD_HASH_ATTRIBUTES:
        return der(values)
    return marked_attribute(attr_oid, values, names)


def marked_plist(data: bytes, names: dict, expected: int):
    """An XML property list's bytes with the content of each <data> element that
    holds a named digest replaced by a marker no text can forge (it holds a NUL),
    or None unless exactly `expected` elements were replaced: a copy of a digest
    anywhere else (a comment, another field) is never normalized away."""
    import base64
    import binascii
    import re
    if not data.lstrip().startswith(b"<?xml") and not data.lstrip().startswith(b"<plist"):
        return None if expected else data
    replaced = 0

    def mark(match):
        nonlocal replaced
        text = match.group(1)
        try:
            value = base64.b64decode(re.sub(rb"\s+", b"", text), validate=True)
        except (binascii.Error, ValueError):
            return match.group(0)
        if value not in names or base64.b64encode(value) != re.sub(rb"\s+", b"", text):
            return match.group(0)
        replaced += 1
        layout = re.sub(rb"\S", b"*", text)  # whitespace and length stay compared
        return b"<data>\0<" + names[value].encode() + b">\0" + layout + b"</data>"
    out = re.sub(rb"<data>([^<]*)</data>", mark, data)
    return out if replaced == expected else None


def marked_attribute(attr_oid: str, values: Node, names: dict):
    """A CodeDirectory-hash attribute with only its digest values named."""
    def tag(node):
        return (node.cls, node.constructed, node.number, tuple(node.issues))

    def name(node):
        return (tag(node), ("digest", names[node.value]) if node.value in names else node.value)
    if attr_oid == MESSAGE_DIGEST:
        return [name(v) for v in values.children]
    if attr_oid == APPLE_CDHASHES:
        return [(tag(v), der(v.children[0]), name(v.children[1])) if len(v.children) == 2 else der(v)
                for v in values.children]
    if len(values.children) != 1 or tag(values.children[0]) != (0, False, 4, ()):
        return der(values)
    try:
        plist = plistlib.loads(values.children[0].value)
        count = len(plist["cdhashes"])
    except Exception:
        return der(values)
    return marked_plist(values.children[0].value, names, count) or der(values)


def cd_hash_attribute_errors(attrs: list, names: dict, count: int) -> list:
    """Each CodeDirectory-hash attribute must hold digests of this side's own
    CodeDirectories, one per CodeDirectory, and nothing else."""
    out = []
    for attr_oid, values in attrs:
        if attr_oid == MESSAGE_DIGEST:
            digests = [v.value for v in values.children]
        elif attr_oid == APPLE_CDHASHES_PLIST:
            try:
                plist = plistlib.loads(values.children[0].value) if len(values.children) == 1 else None
                digests = list(plist["cdhashes"]) if isinstance(plist, dict) and list(plist) == ["cdhashes"] else None
            except Exception:
                digests = None
            if digests is None or len(digests) != count:
                out.append(f"{attr_oid}: not a cdhashes property list with one hash per CodeDirectory")
                continue
        elif attr_oid == APPLE_CDHASHES:
            digests = []
            for v in values.children:
                if v.number != 16 or len(v.children) != 2 or v.children[1].number != 4:
                    out.append(f"{attr_oid}: a value is not a (hash algorithm, digest) pair")
                    break
                digests.append(v.children[1].value)
            if len(digests) != count:
                out.append(f"{attr_oid}: {len(digests)} digests for {count} CodeDirectories")
        else:
            continue
        if attr_oid == MESSAGE_DIGEST and len(digests) != 1:
            out.append(f"{attr_oid}: {len(digests)} values")
        for digest in digests:
            if not isinstance(digest, bytes) or digest not in names:
                out.append(f"{attr_oid}: a digest that is not of this signature's own CodeDirectories")
    return out


def openssl_verify(cms: bytes, content: bytes):
    """None when the CMS signature verifies against its own leaf certificate over
    content (its messageDigest included), else the reason."""
    import shutil
    import subprocess
    import tempfile
    tool = shutil.which("openssl")
    if not tool:
        return "openssl is not available, so the signature cannot be verified (strict mode fails closed)"
    with tempfile.TemporaryDirectory() as tmp:
        sig, data = os.path.join(tmp, "sig.der"), os.path.join(tmp, "content")
        with open(sig, "wb") as h:
            h.write(cms)
        with open(data, "wb") as h:
            h.write(content)
        proc = subprocess.run([tool, "cms", "-verify", "-noverify", "-binary", "-inform", "DER", "-in", sig,
                               "-content", data, "-out", os.devnull], capture_output=True, text=True)
    return None if proc.returncode == 0 else "does not verify: " + (proc.stderr.strip().splitlines() or ["?"])[-1]


def cms_side_errors(cms: dict, raw: bytes, cds: dict, label: str) -> list:
    """What one CMS signature must hold on its own: one signer, only one
    timestamp token unsigned, CodeDirectory-hash attributes that match its
    CodeDirectories, and a signature that verifies against its own leaf
    certificate over its CodeDirectory."""
    out = []
    names = {k: v for slot, cd in cds.items() for k, v in hash_names(cd, f"CodeDirectory {slot:#x}").items()}
    if len(cms["signers"]) != 1:
        out.append(f"CMS ({label}): {len(cms['signers'])} signers")
    for signer in cms["signers"]:
        if signer["signed"] is None:
            out.append(f"CMS ({label}): no signed attributes")
        unsigned = attributes(signer["unsigned"])
        if [o for o, _ in unsigned] not in ([], [TIMESTAMP_TOKEN]):
            out.append(f"CMS ({label}): unsigned attributes other than one timestamp token "
                       f"({', '.join(o for o, _ in unsigned)})")
        signed = attributes(signer["signed"])
        ids = [o for o, _ in signed]
        if len(set(ids)) != len(ids):
            out.append(f"CMS ({label}): a signed attribute appears twice")
        for attr_oid, values in signed:
            if attr_oid == SIGNING_TIME and (len(values.children) != 1 or values.children[0].cls != 0
                                             or values.children[0].number not in (23, 24)):
                out.append(f"CMS ({label}): signingTime is not one UTCTime or GeneralizedTime")
        if MESSAGE_DIGEST not in [o for o, _ in signed]:
            out.append(f"CMS ({label}): no messageDigest")
        out += [f"CMS ({label}): {e}" for e in cd_hash_attribute_errors(signed, names, len(cds))]
    reason = openssl_verify(raw, cds.get(0, b""))
    if reason:
        out.append(f"CMS ({label}): {reason}")
    return out


def strict_cms(ca: bytes, cb: bytes, cds_a: dict, cds_b: dict, labels=("A", "B")) -> list:
    """Differences between two CMS signatures other than the signing time, and
    what either signature lacks on its own (checked even when both are equal).
    cds_* are each side's CodeDirectories by slot: their digests in the
    CodeDirectory-hash attributes are compared by name, and slot 0 is the
    signed content."""
    try:
        pa, pb = parse_cms(ca), parse_cms(cb)
    except (ValueError, IndexError, AttributeError) as error:
        return [f"CMS: cannot parse ({error})"]
    out = cms_side_errors(pa, ca, cds_a, labels[0])
    out += cms_side_errors(pb, cb, cds_b, labels[1]) if cb != ca or cds_b != cds_a else []
    if ca == cb:
        return out
    for key in ("version", "digestAlgorithms", "encap"):
        if der(pa[key]) != der(pb[key]):
            out.append(f"CMS: SignedData {key} differs")
    certs_a, certs_b = [der(c) for c in pa["certificates"]], [der(c) for c in pb["certificates"]]
    if certs_a != certs_b:
        out.append(FRAMING + "CMS: the same certificates in a different order" if sorted(certs_a) == sorted(certs_b)
                   else f"CMS: certificates differ ({len(certs_a)} / {len(certs_b)})")
    if (pa["crls"] and der(pa["crls"])) != (pb["crls"] and der(pb["crls"])):
        out.append("CMS: crls differ")
    if len(pa["signers"]) != len(pb["signers"]):
        return out + [f"CMS: {len(pa['signers'])} / {len(pb['signers'])} signers"]
    names_a = {k: v for slot, cd in cds_a.items() for k, v in hash_names(cd, f"CodeDirectory {slot:#x}").items()}
    names_b = {k: v for slot, cd in cds_b.items() for k, v in hash_names(cd, f"CodeDirectory {slot:#x}").items()}
    skip = ([], [])
    for i, (sa, sb) in enumerate(zip(pa["signers"], pb["signers"])):
        where = f"CMS signer {i}"
        for key in ("version", "sid", "digestAlgorithm", "signatureAlgorithm"):
            if der(sa[key]) != der(sb[key]):
                out.append(f"{where}: {key} differs")
        attrs_a, attrs_b = attributes(sa["signed"]), attributes(sb["signed"])
        ids_a, ids_b = [o for o, _ in attrs_a], [o for o, _ in attrs_b]
        if sorted(ids_a) != sorted(ids_b) or len(set(ids_a)) != len(ids_a):
            out.append(f"{where}: signed attributes differ ({', '.join(ids_a)} / {', '.join(ids_b)})")
        else:
            va, vb = dict(attrs_a), dict(attrs_b)
            for attr in ids_a:
                if attr == SIGNING_TIME:
                    continue
                if attribute_value(attr, va[attr], names_a) != attribute_value(attr, vb[attr], names_b):
                    out.append(f"{where}: signed attribute {attr} differs")
        unsigned_a, unsigned_b = attributes(sa["unsigned"]), attributes(sb["unsigned"])
        if bool(unsigned_a) != bool(unsigned_b):
            out.append(f"{where}: a timestamp token only in {labels[0] if unsigned_a else labels[1]}")
        for side_skip, attrs in zip(skip, (unsigned_a, unsigned_b)):
            side_skip += [v.path for o, v in attrs if o == TIMESTAMP_TOKEN]
        # The signature may differ only because what it signs differs.
        same_signed = (sa["signed"] and der(sa["signed"])) == (sb["signed"] and der(sb["signed"]))
        if same_signed and sa["signature"].value != sb["signature"].value:
            out.append(f"{where}: the signature differs although the signed attributes are identical")
    for side, cms in zip(labels, (pa, pb)):
        if cms["trailing"]:
            out.append(f"CMS ({side}): {len(cms['trailing'])} bytes after the CMS")
    if pa["trailing"] != pb["trailing"]:
        out.append(f"CMS: bytes after the CMS differ ({len(pa['trailing'])} / {len(pb['trailing'])} bytes)")
    fa, fb = framing_issues(pa["root"], skip[0]), framing_issues(pb["root"], skip[1])
    for issue in sorted(set(fa) ^ set(fb)):
        out.append(FRAMING + f"CMS ({labels[0] if issue in fa else labels[1]} only): {issue}")
    return out


def blob_offsets(macho: bytes) -> dict:
    """{blob type: offset in the slice} of each blob in the signature superblob."""
    sig = code_signature_command(macho)
    count = struct.unpack(">I", macho[sig[0] + 8:sig[0] + 12])[0]
    entries = (struct.unpack(">II", macho[sig[0] + 12 + 8 * i:sig[0] + 20 + 8 * i]) for i in range(count))
    return {typ: sig[0] + off for typ, off in entries}


def code_directory_errors(cd: bytes) -> list:
    """A CodeDirectory's header, identifier, hash slots and team id must lie inside it."""
    if len(cd) < 44:
        return ["a CodeDirectory shorter than its header"]
    (magic, length, version, _, hash_off, ident_off, n_special, n_code, _, hash_size,
     _, _, _, _) = struct.unpack(">IIIIIIIIIBBBBI", cd[:44])
    errors = []
    if magic != 0xFADE0C02 or length != len(cd):
        errors.append("a CodeDirectory whose magic or length is wrong")
    if not ident_off < len(cd) or b"\0" not in cd[ident_off:]:
        errors.append("a CodeDirectory identifier outside it")
    if hash_size not in (20, 32, 48, 64) or hash_off < 44 + n_special * hash_size \
            or hash_off + n_code * hash_size > len(cd):
        errors.append("CodeDirectory hash slots outside it")
    if version >= 0x20200 and len(cd) >= 52:
        team = struct.unpack(">I", cd[48:52])[0]
        if team and (team >= len(cd) or b"\0" not in cd[team:]):
            errors.append("a CodeDirectory team id outside it")
    return errors


def cd_slots(cd: bytes):
    """(offset, size) of the CodeResources special slot in a CodeDirectory, or None."""
    _, _, _, _, hash_off, _, n_special, _, _, hash_size = struct.unpack(">IIIIIIIIIB", cd[:37])
    return (hash_off - 3 * hash_size, hash_size) if n_special >= 3 else None


def strict_slice(a: bytes, b: bytes, labels=("A", "B")):
    """(differences, [(slot value A, slot value B)]) between two signings of one slice.
    The second list is the CodeResources hash slots that differ: allowed only when
    those CodeResources are themselves equal but for signing time. Identical
    slices are still parsed and their signatures verified."""
    sa, sb = code_signature_command(a), code_signature_command(b)
    if sa != sb or len(a) != len(b):
        return ["signature reservation (LC_CODE_SIGNATURE offset or size) or slice length differs"], []
    ba, bb = blobs(a), blobs(b)
    if list(ba) != list(bb):
        return [f"signature blobs differ ({', '.join(map(hex, ba))} / {', '.join(map(hex, bb))})"], []
    out, slots = [], []
    for side, body in zip(labels, (a, b)):
        sig = code_signature_command(body)
        count = struct.unpack(">I", body[sig[0] + 8:sig[0] + 12])[0]
        if len(blob_offsets(body)) != count:
            out.append(f"the signature index names a blob type twice ({side})")
    if out:
        return out, slots
    for side, blobs_ in zip(labels, (ba, bb)):
        for t, blob in blobs_.items():
            if t == 0 or 0x1000 <= t < 0x2000:
                out += [f"{e} ({side}, slot {t:#x})" for e in code_directory_errors(blob)]
    if out:
        return out, slots
    for side, body in zip(labels, (a, b)):
        sig = code_signature_command(body)
        length = struct.unpack(">I", body[sig[0] + 4:sig[0] + 8])[0]
        for t, at in blob_offsets(body).items():
            declared = struct.unpack(">I", body[at + 4:at + 8])[0]
            if at - sig[0] + declared > length:
                out.append(f"blob {t:#x} declares a length past the superblob ({side})")
    if out:
        return out, slots
    oa, ob = blob_offsets(a), blob_offsets(b)
    head_a, head_b = struct.unpack(">III", a[sa[0]:sa[0] + 12]), struct.unpack(">III", b[sb[0]:sb[0] + 12])
    ends_a = max(o + len(ba[t]) for t, o in oa.items()) - sa[0]
    ends_b = max(o + len(bb[t]) for t, o in ob.items()) - sb[0]
    if oa != ob or head_a[0] != head_b[0] or head_a[1] - ends_a != head_b[1] - ends_b or \
            any(len(ba[t]) != len(bb[t]) for t in ba if t != 0x10000) or max(oa, key=oa.get) != 0x10000:
        return ["the signature superblob layout differs (blob offsets, lengths or padding)"], slots
    for side, blob in zip(labels, (ba.get(0x10000), bb.get(0x10000))):
        if blob is None or struct.unpack(">I", blob[:4])[0] != CMS_WRAPPER_MAGIC:
            out.append(f"no CMS signature blob ({side})" if blob is None else f"the CMS blob's magic is not 0xfade0b01 ({side})")
    if out:
        return out, slots
    masked_a, masked_b = bytearray(a), bytearray(b)
    for typ in ba:
        name = BLOB.get(typ, hex(typ))
        if typ == 0x10000:
            continue
        xa, xb = bytearray(ba[typ]), bytearray(bb[typ])
        is_cd = typ == 0 or 0x1000 <= typ < 0x2000
        slot = cd_slots(ba[typ]) if is_cd else None
        if slot and len(xa) == len(xb):
            va, vb = bytes(xa[slot[0]:slot[0] + slot[1]]), bytes(xb[slot[0]:slot[0] + slot[1]])
            if va != vb:
                slots.append((va, vb))
                xa[slot[0]:slot[0] + slot[1]] = xb[slot[0]:slot[0] + slot[1]] = bytes(slot[1])
                for masked, body in ((masked_a, a), (masked_b, b)):
                    where = blob_offsets(body)[typ] + slot[0]
                    masked[where:where + slot[1]] = bytes(slot[1])
        if xa != xb:
            if is_cd:
                fa, fb = code_directory(bytes(xa)), code_directory(bytes(xb))
                fields = [k for k in sorted(set(fa) | set(fb)) if fa.get(k) != fb.get(k) and k != "CDHash (sha256)"]
                out.append(f"{name}: {', '.join(fields) or 'bytes'} differ")
            else:
                out.append(f"{name}: differs")
    cms_a, cms_b = ba.get(0x10000, b"")[8:], bb.get(0x10000, b"")[8:]
    if not out and outside_cms(bytes(masked_a), bytes(masked_b)):
        out.append("bytes outside the signature blobs differ (superblob layout or padding)")
    cds_a = {t: v for t, v in ba.items() if t == 0 or 0x1000 <= t < 0x2000}
    cds_b = {t: v for t, v in bb.items() if t == 0 or 0x1000 <= t < 0x2000}
    out += strict_cms(cms_a, cms_b, cds_a, cds_b, labels)
    return out, slots


def label_path(name):
    """The item path in a hash_names() label ("<sha256 of PATH>", or "<sha256 of PATH\\0[arm64] CodeDirectory 0x0>":
    no path holds a NUL, so no file name can pose as a CodeDirectory label)."""
    if not name:
        return None
    return name.split(" of ", 1)[1][:-1].split("\0", 1)[0]


HASH_FIELDS = {"hash", "hash2", "cdhash"}
BUNDLE_SUFFIXES = (".app", ".framework", ".bundle", ".appex", ".xpc", ".plugin")


def resources_schema_errors(plist) -> list:
    """What a CodeResources must look like: a dictionary whose files and files2
    map paths to a digest or to a dictionary whose hash fields are digests of
    their algorithm's size, and whose rules are dictionaries."""
    if not isinstance(plist, dict):
        return ["not a property list dictionary"]
    out = []
    for section in ("rules", "rules2"):
        if section in plist and not isinstance(plist[section], dict):
            out.append(f"{section} is not a dictionary")
    sizes = {"hash": 20, "hash2": 32, "cdhash": 20}
    for section in ("files", "files2"):
        entries = plist.get(section, {})
        if not isinstance(entries, dict):
            out.append(f"{section} is not a dictionary")
            continue
        for entry, value in entries.items():
            if isinstance(value, bytes):
                if section == "files2" or len(value) != 20:
                    out.append(f"{section}/{entry}: a bare digest that is not a SHA-1 in files")
            elif isinstance(value, dict):
                fields = [k for k in sizes if k in value]
                if not fields and not ("symlink" in value and isinstance(value["symlink"], str)):
                    out.append(f"{section}/{entry}: no hash field")
                out += [f"{section}/{entry}: {k} is not a {sizes[k]}-byte digest" for k in fields
                        if not isinstance(value[k], bytes) or len(value[k]) != sizes[k]]
            else:
                out.append(f"{section}/{entry}: neither a digest nor a dictionary")
    return out


def resources_named(plist, home: str, names: dict):
    """A CodeResources property list with each digest named, but only in its hash
    fields and only when the digest is of that entry's own path (a file's bytes)
    or of a CodeDirectory of the nested code at that path."""
    used, used_count = {}, [0]
    if not isinstance(plist, dict):
        return plist, used, 0

    def name(digest, entry, field):
        label = names.get(digest) if isinstance(digest, bytes) else None
        path = label_path(label)
        if not path or not entry or entry.startswith("/") or os.path.normpath(entry) != entry \
                or entry.split("/")[0] == "..":
            return digest
        own = os.path.join(home, entry) if home else entry
        alg, code = label[1:].split(" of ", 1)[0], "\0" in label
        if field == "cdhash":  # the CodeDirectory hash of the nested code at (or inside the bundle at) entry
            ok = code and alg in ("sha1", "sha256[:20]") and (
                path == own or path.startswith(own + "/") and own.endswith(BUNDLE_SUFFIXES))
        else:  # a whole-file digest of exactly this entry: hash is SHA-1, hash2 is SHA-256
            ok = not code and path == own and alg == ("sha256" if field == "hash2" else "sha1")
        if ok:
            used[digest] = label
            used_count[0] += 1
            return ("digest of", label)  # a tuple: no property list value equals it
        return digest

    out = dict(plist)
    for section in ("files", "files2"):
        entries = plist.get(section)
        if not isinstance(entries, dict):
            continue
        out[section] = {}
        for entry, value in entries.items():
            if isinstance(value, bytes):
                value = name(value, entry, "hash")
            elif isinstance(value, dict):
                value = {k: name(v, entry, k) if k in HASH_FIELDS else v for k, v in value.items()}
            out[section][entry] = value
    return out, used, used_count[0]


def manifest_named(data: bytes, rel: str, names: dict) -> bytes:
    """A manifest's raw bytes with each binary's checksum named, only when it is
    the sha256 of that binary and appears once."""
    folder = os.path.dirname(rel)
    by_hex = {d.hex(): n for d, n in names.items() if len(d) == 32}
    for entry, digest in json.loads(data)["binaries"].items():
        label = by_hex.get(digest)
        if label and label_path(label) == os.path.join(folder, entry) and data.count(digest.encode()) == 1:
            data = data.replace(digest.encode(), label.encode())
    return data


def is_framing(diffs: list) -> bool:
    return bool(diffs) and all(d.split("] ", 1)[-1].startswith(FRAMING) for d in diffs)


def code_signature_dirs(root: str) -> dict:
    """{relative path: sorted entries} of every real _CodeSignature directory."""
    return {os.path.relpath(d, root): sorted(os.listdir(d)) for d, dirs, _ in os.walk(root)
            if os.path.basename(d) == "_CodeSignature" and not os.path.islink(d)}


def bundle_signature_dirs(root: str) -> set:
    """Where a signature directory must be: Contents/_CodeSignature of the app and
    of every nested .app, and Versions/X/_CodeSignature of every framework version."""
    out = {os.path.join("Contents", "_CodeSignature")}
    for d, dirs, _ in os.walk(root):
        rel = os.path.relpath(d, root)
        if rel != "." and d.endswith(".app") and os.path.isdir(os.path.join(d, "Contents")):
            out.add(os.path.join(rel, "Contents", "_CodeSignature"))
        if os.path.basename(os.path.dirname(d)) == "Versions" and d.split(os.sep)[-3].endswith(".framework") \
                and not os.path.islink(d) and os.path.basename(d) != "Current":
            out.add(os.path.join(rel, "_CodeSignature"))
    return out


def signature_dir_errors(a_root: str, b_root: str, labels) -> dict:
    """The default compare leaves every _CodeSignature directory out of the
    payload. In strict mode each must sit where a bundle's signature goes
    (Contents/_CodeSignature or a framework's Versions/X/_CodeSignature), hold
    regular files only, be on both sides with the same files, and every file
    but CodeResources must be byte-identical."""
    out = {}
    da, db = code_signature_dirs(a_root), code_signature_dirs(b_root)
    for rel in sorted(bundle_signature_dirs(a_root) | bundle_signature_dirs(b_root)):
        if rel not in da or rel not in db:
            missing = [side for side, d in zip(labels, (da, db)) if rel not in d]
            out[rel] = [f"a bundle without its signature directory ({', '.join(missing)})"]
    for rel in sorted(set(da) | set(db)):
        parts = rel.split(os.sep)
        errors = []
        in_app = len(parts) == 2 and parts[0] == "Contents" or len(parts) >= 3 and parts[-2] == "Contents" \
            and parts[-3].endswith(BUNDLE_SUFFIXES)
        in_framework = len(parts) >= 4 and parts[-3] == "Versions" and parts[-4].endswith(".framework")
        if not (in_app or in_framework):
            errors.append("a _CodeSignature directory where no bundle signature goes")
        if rel not in da or rel not in db:
            errors.append(f"only in {labels[0] if rel in da else labels[1]}")
        elif da[rel] != db[rel]:
            errors.append(f"different files ({', '.join(da[rel])} / {', '.join(db[rel])})")
        for side, root, entries in ((labels[0], a_root, da.get(rel, [])), (labels[1], b_root, db.get(rel, []))):
            for name in entries:
                path = os.path.join(root, rel, name)
                if os.path.islink(path) or not os.path.isfile(path):
                    errors.append(f"{name} ({side}) is not a regular file")
        def mode(root, *names):
            path = os.path.join(root, rel, *names)
            return oct(stat.S_IMODE(os.lstat(path).st_mode)) if os.path.lexists(path) else None
        if rel in da and rel in db:
            for name in [None] + sorted(set(da[rel]) & set(db[rel])):
                ma, mb = (mode(r, *([name] if name else [])) for r in (a_root, b_root))
                if ma != mb:
                    errors.append(f"{name or 'the directory'}: mode differs ({ma} / {mb})")
        for name in sorted(set(da.get(rel, [])) & set(db.get(rel, [])) - {"CodeResources"}):
            pa, pb = os.path.join(a_root, rel, name), os.path.join(b_root, rel, name)
            if os.path.isfile(pa) and os.path.isfile(pb):
                with open(pa, "rb") as fa, open(pb, "rb") as fb:
                    if fa.read() != fb.read():
                        errors.append(f"{name} differs")
        if errors:
            out[rel] = errors
    return out


def manifest_errors(data: bytes) -> list:
    try:
        manifest = json.loads(data)
    except ValueError:
        return ["not JSON"]
    binaries = manifest.get("binaries") if isinstance(manifest, dict) else None
    if not isinstance(binaries, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in binaries.items()):
        return ["no binaries map of names to checksums"]
    return [f"{name}: not a plain file name" for name in binaries
            if not name or "/" in name or "\\" in name or name in (".", "..")]


def strict_compare(a_root, b_root, machos: dict, labels, failures: list) -> tuple:
    """Strict verdicts: (report lines, number of differences, verdicts). machos
    holds the Mach-O files whose payload is equal, as (slices A, slices B, bytes
    A, bytes B). A Mach-O, CodeResources or manifest passes once its only
    differences are the signing time and hashes of items that passed; that
    repeats until nothing changes. Then, for the report only, an item whose
    differences are framing, or hashes of items that differ only by framing,
    is marked framing only; it still fails."""
    lines, verdicts, pending, raw, sealed = [], {}, {}, {}, {}
    for rel, (pa, pb, da, db) in sorted(machos.items()):
        raw[rel] = (da, db)
        diffs, slots = container_errors(da, db, pa, pb), []
        for (arch, x), (_, y) in zip(pa, pb):
            try:
                d, s = strict_slice(x, y, labels)
            except (ValueError, IndexError, KeyError, AttributeError, struct.error) as error:
                d, s = [f"cannot parse the signature ({error})"], []
            diffs += [f"[{arch}] {m}" for m in d]
            slots += s
        pending[rel] = ("macho", diffs, slots, (da, db), (pa, pb))
        if slots:
            # The CodeResources slot of a bundle's main executable seals that bundle's CodeResources.
            parts = rel.split("/")
            home = "/".join(parts[:-2]) if len(parts) >= 3 and parts[-2] == "MacOS" and parts[-3] == "Contents" \
                else "/".join(parts[:-1])
            sealed[rel] = (home + "/" if home else "") + "_CodeSignature/CodeResources"

    def resources(root):
        return {os.path.relpath(os.path.join(d, f), root) for d, _, fs in os.walk(root) for f in fs
                if f == "CodeResources" and os.path.basename(d) == "_CodeSignature"}
    ra, rb = resources(a_root), resources(b_root)
    for rel in sorted(ra ^ rb):
        raw[rel] = (None, b"")
        verdicts[rel] = [f"only in {labels[0] if rel in ra else labels[1]}"]
    manifests = {rel for rel in walk(a_root) if is_ssh_manifest(rel) and os.path.isfile(os.path.join(b_root, rel))}
    for rel in sorted(ra & rb) + sorted(manifests):
        with open(os.path.join(a_root, rel), "rb") as ha, open(os.path.join(b_root, rel), "rb") as hb:
            raw[rel] = (ha.read(), hb.read())
        kind = "resources" if rel in ra else "manifest"
        pre = [f"{e} ({side})" for side, x in zip(labels, raw[rel]) for e in manifest_errors(x)] if kind == "manifest" else []
        pending[rel] = (kind, pre, [], raw[rel], None)

    def check(rel, known):
        kind, pre, slots, (xa, xb), _ = pending[rel]
        out = list(pre)
        if kind == "macho":
            want = sealed.get(rel)
            bad = [s for s in slots if not (label_path(known[0].get(s[0])) == want == label_path(known[1].get(s[1]))
                                            and known[0].get(s[0]) == known[1].get(s[1]))]
            if bad:
                out.append(f"CodeResources hash slot differs, and not only by the signing time ({len(bad)} slots)")
            return out
        if kind == "resources":
            for side, x in zip(labels, (xa, xb)):
                try:
                    out += [f"{e} ({side})" for e in resources_schema_errors(plistlib.loads(x))]
                except Exception:
                    out.append(f"not a property list ({side})")
            if out:
                return out
        if xa == xb:
            return out
        if kind == "manifest":  # its sha256 checksums of signed Mach-O files, in hex
            if pre:
                return out + ["differs"]
            na, nb = (manifest_named(x, rel, k) for x, k in ((xa, known[0]), (xb, known[1])))
            return out + ([] if na == nb else ["differs, and not only by checksums of files that differ only by signing time"])
        try:
            pa, pb = plistlib.loads(xa), plistlib.loads(xb)
        except Exception:
            return out + ["not a property list; bytes differ"]
        home = os.path.dirname(os.path.dirname(rel))
        (na, ua, ca), (nb, ub, cb) = resources_named(pa, home, known[0]), resources_named(pb, home, known[1])
        if na == nb:
            # The parsed lists agree; their bytes must too, but for the digests in hash fields.
            ma, mb = marked_plist(xa, ua, ca), marked_plist(xb, ub, cb)
            return out + ([] if ma is not None and ma == mb else
                          ["the same entries in different bytes (formatting, comments or order)"])
        diffs = code_resources_diff_values(na, nb) or ["the property lists differ"]
        return out + [f"{d} (a hash not explained by a nested item that differs only by signing time)" for d in diffs]

    def learn(known, rel):
        _, _, _, (xa, xb), parts = pending[rel]
        for side, data, sl in ((0, xa, parts[0] if parts else []), (1, xb, parts[1] if parts else [])):
            known[side].update(hash_names(data, rel))
            for arch, body in sl:
                for typ, blob in blobs(body).items():
                    if typ == 0 or 0x1000 <= typ < 0x2000:
                        known[side].update(hash_names(blob, f"{rel}\0[{arch}] CodeDirectory {typ:#x}"))

    def settle(known, accept):
        """Accepts pending items until none changes; returns the accepted ones."""
        done, changed = set(), True
        while changed:
            changed = False
            for rel in sorted(set(pending) - done):
                if accept(check(rel, known)):
                    done.add(rel)
                    learn(known, rel)
                    changed = True
        return done

    known = ({}, {})  # digest -> name, per side, of every item that passed
    passed = settle(known, lambda diffs: not diffs)
    lenient = (dict(known[0]), dict(known[1]))
    framed = settle(lenient, lambda diffs: not diffs or is_framing(diffs)) - passed
    for rel in pending:
        if rel in passed:
            verdicts[rel] = []
        elif rel in framed:
            own = [d for d in check(rel, lenient) if d.split("] ", 1)[-1].startswith(FRAMING)]
            verdicts[rel] = own + ([FRAMING_CASCADE] if check(rel, known) != own else [])
        else:
            verdicts[rel] = check(rel, known)
    for rel, errors in signature_dir_errors(a_root, b_root, labels).items():
        verdicts[rel] = (verdicts.get(rel) or []) + errors
        raw.setdefault(rel, (None, b""))
    count, identical, framing_only = len(failures), 0, 0
    for rel in sorted(verdicts):
        if not verdicts[rel]:
            same = raw[rel][0] == raw[rel][1]
            identical += same
            if not same:
                lines.append(f"  PASS {rel}: differs only by the signing time")
            continue
        count += len(verdicts[rel])
        framing = is_framing(verdicts[rel])
        framing_only += len(verdicts[rel]) if framing else 0
        lines.append(f"  FAIL {rel}{' (framing only)' if framing else ''}:")
        lines += [f"         {d}" for d in verdicts[rel]]
    lines.insert(0, f"Strict compare {labels[0]} vs {labels[1]}: {len(verdicts)} signed files, CodeResources and manifests, "
                    f"{identical} byte-identical; {len(failures)} payload differences")
    note = f", {framing_only} of them framing only" if framing_only else ""
    lines.append("strict parity: PASS" if not count else f"strict parity: FAIL ({count} differences{note})")
    return lines, count, verdicts


def container_errors(da: bytes, db: bytes, pa, pb) -> list:
    """A universal file's container (header with offsets and sizes, padding,
    length) must be byte-identical; only the slices may differ."""
    if len(da) != len(db):
        return [f"file length differs ({len(da)} / {len(db)})"]
    fa = fat_header(da)
    if fa is None:
        return []

    def outside(data, parts):
        out, pos = bytearray(data), 0
        for _, body in parts:
            at = data.index(body, pos) if body else pos
            out[at:at + len(body)] = bytes(len(body))
            pos = at + len(body)
        return bytes(out)
    return [] if outside(da, pa) == outside(db, pb) else ["the universal container (header, offsets or padding) differs"]


def special_ok(path: str) -> bool:
    """Only regular files, directories and symlinks belong in an app; a device or
    FIFO would read as an empty file (or hang)."""
    mode = os.lstat(path).st_mode
    return stat.S_ISREG(mode) or stat.S_ISDIR(mode) or stat.S_ISLNK(mode)


def symlink_mode_errors(a_root: str, b_root: str) -> list:
    """The default compare records a symlink's target only; its own mode (macOS
    lchmod) must match too."""
    out = []
    ta, tb = walk(a_root), walk(b_root)
    for rel in sorted(set(ta) & set(tb)):
        if os.path.islink(ta[rel]) and os.path.islink(tb[rel]):
            ma, mb = (oct(stat.S_IMODE(os.lstat(p).st_mode)) for p in (ta[rel], tb[rel]))
            if ma != mb:
                out.append(f"{rel}: symlink mode differs ({ma} / {mb})")
    return out


def tree_errors(root: str) -> list:
    """What strict mode cannot read: os.walk() otherwise skips an unreadable directory."""
    errors = []
    for _ in os.walk(root, onerror=lambda e: errors.append(f"cannot read {e.filename}: {e.strerror}")):
        pass
    return errors


def main() -> int:
    args = parse_args()
    if not args.strict:
        return compare(args)

    def fail(reason: str, details=()) -> int:
        print("\n".join([*details, f"strict parity: FAIL ({reason})"]))
        with open(args.out, "w", encoding="utf-8") as handle:
            json.dump({"strict": {"error": reason, "details": list(details)}}, handle, indent=1)
        return 1
    bad = [p for p in (args.a, args.b) if os.path.islink(p) or not os.path.isdir(p)]
    if bad:
        return fail(f"not a directory: {', '.join(bad)}")
    unreadable = tree_errors(args.a) + tree_errors(args.b)
    if unreadable:
        return fail(f"{len(unreadable)} unreadable paths", unreadable)
    modes = [oct(stat.S_IMODE(os.stat(p).st_mode)) for p in (args.a, args.b)]
    if modes[0] != modes[1]:
        return fail(f"the app directories' modes differ: {modes[0]} / {modes[1]}")
    special = [f"{root}: {rel} is not a regular file, directory or symlink" for root in (args.a, args.b)
               for rel, path in walk(root).items() if not special_ok(path)]
    if special:
        return fail(f"{len(special)} special files", special)
    links = symlink_mode_errors(args.a, args.b)
    if links:
        return fail(f"{len(links)} symlink modes differ", links)
    try:
        return compare(args)
    except Exception as error:  # a malformed input fails strict mode, never crashes it open
        return fail(f"cannot compare: {type(error).__name__}: {error}")


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("a")
    parser.add_argument("b")
    parser.add_argument("out")
    parser.add_argument("--labels", default="A,B")
    parser.add_argument("--report")
    parser.add_argument("--strict", action="store_true", help="also fail on every signature difference "
                        "except the signing time (see STRICT MODE above)")
    parser.add_argument("--input", help="the unsigned app both were signed from: bytes past a new signature "
                        "superblob are accepted only when they are this input's bytes at the same offset")
    return parser.parse_args()


def compare(args) -> int:
    la, lb = args.labels.split(",", 1)
    ta, tb = walk(args.a), walk(args.b)
    failures, records, signatures, resources, machos = [], [], {}, {}, {}
    counts = {"paths": 0, "macho": 0, "equal": 0, "slices": 0, "identical_slices": 0, "only_cms_differs": 0}
    for rel in sorted(set(ta) | set(tb)):
        counts["paths"] += 1
        if rel not in ta or rel not in tb:
            failures.append(f"{rel}: only in {la if rel in ta else lb}")
            continue
        ra, rb = describe(args.a, rel, ta[rel], args.input), describe(args.b, rel, tb[rel], args.input)
        pa, pb = ra.pop("_slices", None), rb.pop("_slices", None)
        keys = ("kind", "target", "mode", "archs", "payload_sha256")
        diff = [k for k in keys if ra.get(k) != rb.get(k)]
        for side, record in ((la, ra), (lb, rb)):
            if record.get("signature_error"):
                failures.append(f"{rel} ({side}): {record['signature_error']}")
            if record.get("padding_error"):
                failures.append(f"{rel} ({side}): {record['padding_error']}")
            for error in record.get("manifest_errors", []):
                failures.append(f"{rel} ({side}): {error}")
            if record["kind"] == "macho" and not record["signed"]:
                failures.append(f"{rel} ({side}): a Mach-O slice has no code signature")
        if diff:
            failures.append(f"{rel}: payload differs ({', '.join(diff)})")
        else:
            counts["equal"] += 1
        if pa is not None and pb is not None and not diff and ra.get("signed") and rb.get("signed"):
            counts["macho"] += 1
            if args.strict:
                with open(ta[rel], "rb") as fa, open(tb[rel], "rb") as fb:
                    machos[rel] = (pa, pb, fa.read(), fb.read())
            sig = {arch: signature_diff(x, y) for (arch, x), (_, y) in zip(pa, pb)}
            counts["slices"] += len(sig)
            counts["identical_slices"] += sum(1 for d in sig.values() if not d)
            counts["only_cms_differs"] += sum(1 for d in sig.values()
                                              if d and all(isinstance(x, str) and x.startswith("CMS signature:") for x in d))
            sig = {arch: d for arch, d in sig.items() if d}
            if sig:
                signatures[rel] = sig
        records.append({"path": rel, la: ra, lb: rb, "differs": diff})
    # Signature output: differences, and a CodeResources on one side only, are
    # reported here and never fail the payload compare.
    def code_resources(root):
        return {os.path.relpath(os.path.join(d, f), root) for d, _, fs in os.walk(root) for f in fs if f == "CodeResources"}
    ca, cb = code_resources(args.a), code_resources(args.b)
    for rel in sorted(ca | cb):
        if rel in ca and rel in cb:
            diff = code_resources_diff(os.path.join(args.a, rel), os.path.join(args.b, rel))
        else:
            diff = [f"only in {la if rel in ca else lb}"]
        if diff:
            resources[rel] = diff
    result = {"labels": [la, lb], "counts": counts, "payload_failures": failures,
              "signature_differences": signatures, "code_resources_differences": resources, "records": records}
    if args.strict:
        strict_lines, strict_count, verdicts = strict_compare(args.a, args.b, machos, (la, lb), failures)
        result["strict"] = {"differences": strict_count, "verdicts": verdicts}
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=1, sort_keys=True)
    lines = [f"Payload compare {la} vs {lb}: {counts['paths']} paths outside _CodeSignature, "
             f"{counts['equal']} identical, {len(failures)} differing; {counts['macho']} Mach-O files "
             f"with identical payload."]
    lines += [f"  PAYLOAD DIFFERS: {f}" for f in failures]
    lines.append(f"Mach-O slices whose bytes differ only inside the CMS blob (signing time, signature): "
                 f"{counts['only_cms_differs']} of {counts['slices']}; identical: {counts['identical_slices']}")
    for record in records:
        for side in (la, lb):
            if record[side].get("input_signature_residue_bytes"):
                lines.append(f"  input-signature residue ({side}): {record['path']}: "
                             f"{record[side]['input_signature_residue_bytes']} bytes past the new superblob, "
                             "equal to the unsigned input's bytes at the same offset")
    summary = {}
    for rel, archs in signatures.items():
        for arch, diffs in archs.items():
            for d in diffs:
                key = json.dumps(sorted(next(iter(d.values())).keys()) if isinstance(d, dict) else d)
                label = (next(iter(d)) + ": " + ", ".join(json.loads(key))) if isinstance(d, dict) else d
                summary.setdefault(label, []).append(f"{rel} [{arch}]")
    lines.append(f"Signature differences ({la} vs {lb}), grouped:")
    for label, paths in sorted(summary.items(), key=lambda kv: -len(kv[1])):
        lines.append(f"  {len(paths):4d} x {label}   e.g. {paths[0]}")
    lines.append(f"CodeResources with differing entries: {len(resources)}")
    for rel, diff in sorted(resources.items()):
        lines.append(f"  {rel}: {len(diff)} entries, e.g. {diff[0]}")
    if args.strict:
        lines += strict_lines
    text = "\n".join(lines)
    print(text)
    if args.report:
        with open(args.report, "w", encoding="utf-8") as handle:
            handle.write(text + "\n")
    return 1 if failures or (args.strict and strict_count) else 0


if __name__ == "__main__":
    sys.exit(main())
