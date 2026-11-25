#!/usr/bin/env python3
"""Content-defined chunk manifests for Mac update archives (RFD 0166 row 303, U2).

A manifest lists the archive as FastCDC chunks (16/64/256 KiB, gear hash,
normalized chunking) named by sha256, plus the whole-file sha256. Reassembly
concatenates the chunks and must reproduce the archive bit-exact, so Sparkle's
EdDSA signature and Gatekeeper's staple check the same bytes as today.

    manifest ARCHIVE [-o OUT.json] [--store DIR]   write a manifest (and chunks)
    assemble MANIFEST --store DIR -o ARCHIVE       rebuild; fails unless sha256 matches
    delta OLD.json NEW.json                        bytes a client holding OLD must fetch

This is the measurement and format slice; the Rust `cmux-cas` crate owns the
shipping implementation. Nothing here changes the update path.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

MIN_SIZE = 16 * 1024
AVG_SIZE = 64 * 1024
MAX_SIZE = 256 * 1024
MASK_MASK = 64 - 1

# Gear table: fixed, derived from sha256 so every implementation agrees.
GEAR = [int.from_bytes(hashlib.sha256(b"cmux-cas-gear" + bytes([i])).digest()[:8], "little") for i in range(256)]
U64 = (1 << 64) - 1
# Normalized chunking (FastCDC level 2): a stricter mask before AVG_SIZE, a looser one after.
MASK_S = (1 << 18) - 1  # 2 more bits than log2(AVG) = 16
MASK_L = (1 << 14) - 1  # 2 fewer bits


def cut_points(data: bytes | memoryview) -> list[int]:
    """Return the end offset of every chunk."""
    n = len(data)
    cuts: list[int] = []
    start = 0
    gear = GEAR
    while start < n:
        remaining = n - start
        if remaining <= MIN_SIZE:
            cuts.append(n)
            break
        end = start + min(remaining, MAX_SIZE)
        normal = start + min(remaining, AVG_SIZE)
        h = 0
        i = start + MIN_SIZE
        cut = end
        while i < normal:
            h = ((h << 1) + gear[data[i]]) & U64
            if not (h & MASK_S):
                cut = i + 1
                break
            i += 1
        else:
            while i < end:
                h = ((h << 1) + gear[data[i]]) & U64
                if not (h & MASK_L):
                    cut = i + 1
                    break
                i += 1
        cuts.append(cut)
        start = cut
    return cuts


def build_manifest(path: Path, store: Path | None = None) -> dict:
    data = path.read_bytes()
    chunks = []
    start = 0
    for end in cut_points(data):
        piece = data[start:end]
        digest = hashlib.sha256(piece).hexdigest()
        chunks.append({"sha256": digest, "size": end - start})
        if store is not None:
            dest = store / digest[:2] / digest
            if not dest.exists():
                dest.parent.mkdir(parents=True, exist_ok=True)
                tmp = dest.with_suffix(".tmp")
                tmp.write_bytes(piece)
                os.replace(tmp, dest)
        start = end
    return {
        "format": "cmux-cas-manifest/0",
        "chunker": {"kind": "fastcdc-gear-sha256", "min": MIN_SIZE, "avg": AVG_SIZE, "max": MAX_SIZE},
        "name": path.name,
        "size": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "chunks": chunks,
    }


def assemble(manifest: dict, store: Path, out: Path) -> None:
    whole = hashlib.sha256()
    tmp = out.with_name(out.name + ".part")
    with tmp.open("wb") as f:
        for c in manifest["chunks"]:
            piece = (store / c["sha256"][:2] / c["sha256"]).read_bytes()
            if len(piece) != c["size"] or hashlib.sha256(piece).hexdigest() != c["sha256"]:
                raise SystemExit(f"chunk {c['sha256']} is corrupt")
            whole.update(piece)
            f.write(piece)
    if whole.hexdigest() != manifest["sha256"]:
        tmp.unlink()
        raise SystemExit("assembled archive sha256 differs from the manifest")
    os.replace(tmp, out)


def delta(old: dict, new: dict) -> dict:
    have = {c["sha256"] for c in old["chunks"]}
    need: dict[str, int] = {}
    for c in new["chunks"]:
        if c["sha256"] not in have:
            need[c["sha256"]] = c["size"]
    fetch = sum(need.values())
    return {
        "from": old["name"],
        "to": new["name"],
        "full_bytes": new["size"],
        "fetch_bytes": fetch,
        "fetch_chunks": len(need),
        "total_chunks": len(new["chunks"]),
        "fetch_fraction": round(fetch / new["size"], 4) if new["size"] else 0.0,
    }


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("manifest")
    m.add_argument("archive", type=Path)
    m.add_argument("-o", "--out", type=Path)
    m.add_argument("--store", type=Path)
    a = sub.add_parser("assemble")
    a.add_argument("manifest", type=Path)
    a.add_argument("--store", type=Path, required=True)
    a.add_argument("-o", "--out", type=Path, required=True)
    d = sub.add_parser("delta")
    d.add_argument("old", type=Path)
    d.add_argument("new", type=Path)
    args = p.parse_args(argv)
    if args.cmd == "manifest":
        man = build_manifest(args.archive, args.store)
        text = json.dumps(man, indent=1)
        if args.out:
            args.out.write_text(text)
        else:
            print(text)
        print(f"{man['name']}: {man['size']} bytes, {len(man['chunks'])} chunks, sha256 {man['sha256']}", file=sys.stderr)
    elif args.cmd == "assemble":
        assemble(json.loads(args.manifest.read_text()), args.store, args.out)
        print(f"assembled {args.out}: sha256 matches", file=sys.stderr)
    else:
        print(json.dumps(delta(json.loads(args.old.read_text()), json.loads(args.new.read_text())), indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
