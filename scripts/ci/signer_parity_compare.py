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
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
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
    ncmds = struct.unpack("<I", macho[16:20])[0]
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", macho[off:off + 8])
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
    ncmds = struct.unpack("<I", macho[16:20])[0]
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", macho[off:off + 8])
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
    ncmds = struct.unpack("<I", macho[16:20])[0]
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", macho[off:off + 8])
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


def code_resources_diff(a: str, b: str) -> list:
    with open(a, "rb") as fa, open(b, "rb") as fb:
        ra, rb = fa.read(), fb.read()
    try:
        pa, pb = plistlib.loads(ra), plistlib.loads(rb)
    except Exception:  # not a plist: only its bytes can be compared
        return [] if ra == rb else ["not a property list; bytes differ"]
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
        for key in sorted(set(sa) | set(sb)):
            if sa.get(key) == sb.get(key):
                continue
            va, vb = sa.get(key), sb.get(key)
            if isinstance(va, dict) and isinstance(vb, dict):
                fields = sorted(k for k in set(va) | set(vb) if va.get(k) != vb.get(k))
                out.append(f"{section}/{key}: {', '.join(fields)}")
            else:
                out.append(f"{section}/{key}: {'only A' if vb is None else 'only B' if va is None else 'differs'}")
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("a")
    parser.add_argument("b")
    parser.add_argument("out")
    parser.add_argument("--labels", default="A,B")
    parser.add_argument("--report")
    parser.add_argument("--input", help="the unsigned app both were signed from: bytes past a new signature "
                        "superblob are accepted only when they are this input's bytes at the same offset")
    args = parser.parse_args()
    la, lb = args.labels.split(",", 1)
    ta, tb = walk(args.a), walk(args.b)
    failures, records, signatures, resources = [], [], {}, {}
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
    text = "\n".join(lines)
    print(text)
    if args.report:
        with open(args.report, "w", encoding="utf-8") as handle:
            handle.write(text + "\n")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
