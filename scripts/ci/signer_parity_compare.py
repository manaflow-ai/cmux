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


def signature_range(macho: bytes):
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
    sig = signature_range(macho)
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
    sig = signature_range(macho)
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


def signature_diff(a: bytes, b: bytes) -> list:
    out = []
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
            if "_CodeSignature" in rel.split(os.sep):
                continue
            out[rel] = path
    return out


def describe(root: str, rel: str, path: str) -> dict:
    st = os.lstat(path)
    if stat.S_ISLNK(st.st_mode):
        return {"kind": "symlink", "target": os.readlink(path)}
    if stat.S_ISDIR(st.st_mode):
        return {"kind": "dir", "mode": oct(stat.S_IMODE(st.st_mode))}
    with open(path, "rb") as handle:
        data = handle.read()
    record = {"kind": "file", "mode": oct(stat.S_IMODE(st.st_mode)), "sha256": hashlib.sha256(data).hexdigest()}
    parts = slices(data)
    if parts is not None:
        digest = hashlib.sha256()
        fat = fat_header(data)
        digest.update(b"thin\0" if fat is None else b"fat\0" + fat[0])
        if fat is not None and not fat[1]:
            record["padding_error"] = "bytes outside the fat slices are not zero padding"
        for arch, body in parts:
            digest.update(arch.encode() + b"\0" + payload(body))
        record.update(kind="macho", archs=[a for a, _ in parts], payload_sha256=digest.hexdigest(),
                      signed=all(signature_range(body) for _, body in parts))
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
    args = parser.parse_args()
    la, lb = args.labels.split(",", 1)
    ta, tb = walk(args.a), walk(args.b)
    failures, records, signatures, resources = [], [], {}, {}
    counts = {"paths": 0, "macho": 0, "equal": 0}
    for rel in sorted(set(ta) | set(tb)):
        counts["paths"] += 1
        if rel not in ta or rel not in tb:
            failures.append(f"{rel}: only in {la if rel in ta else lb}")
            continue
        ra, rb = describe(args.a, rel, ta[rel]), describe(args.b, rel, tb[rel])
        pa, pb = ra.pop("_slices", None), rb.pop("_slices", None)
        keys = ("kind", "target", "mode", "archs", "payload_sha256")
        diff = [k for k in keys if ra.get(k) != rb.get(k)]
        for side, record in ((la, ra), (lb, rb)):
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
        if pa is not None and pb is not None and not diff:
            counts["macho"] += 1
            sig = {arch: signature_diff(x, y) for (arch, x), (_, y) in zip(pa, pb)}
            sig = {arch: d for arch, d in sig.items() if d}
            if sig:
                signatures[rel] = sig
        records.append({"path": rel, la: ra, lb: rb, "differs": diff})
    for rel in sorted(set(os.path.relpath(os.path.join(d, f), args.a)
                          for d, _, fs in os.walk(args.a) for f in fs if f == "CodeResources")):
        other = os.path.join(args.b, rel)
        if os.path.isfile(other):
            diff = code_resources_diff(os.path.join(args.a, rel), other)
            if diff:
                resources[rel] = diff
        else:
            failures.append(f"{rel}: only in {la}")
    result = {"labels": [la, lb], "counts": counts, "payload_failures": failures,
              "signature_differences": signatures, "code_resources_differences": resources, "records": records}
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(result, handle, indent=1, sort_keys=True)
    lines = [f"Payload compare {la} vs {lb}: {counts['paths']} paths outside _CodeSignature, "
             f"{counts['equal']} identical, {len(failures)} differing; {counts['macho']} Mach-O files "
             f"with identical payload."]
    lines += [f"  PAYLOAD DIFFERS: {f}" for f in failures]
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
