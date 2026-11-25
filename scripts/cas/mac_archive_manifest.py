#!/usr/bin/env python3
"""Content-defined chunk manifests for Mac update archives (RFD 0166 row 303, U2).

A manifest lists the archive as FastCDC chunks (16/64/256 KiB, gear hash,
normalized chunking) named by sha256, plus the whole-file sha256. Reassembly
concatenates the chunks and must reproduce the archive bit-exact, so Sparkle's
EdDSA signature and Gatekeeper's staple check the same bytes as today.

    manifest ARCHIVE [-o OUT.json] [--store DIR]   write a manifest (and chunks)
    assemble MANIFEST --store DIR -o ARCHIVE       rebuild; fails unless sha256 matches
    tree APP_DIR [-o OUT.json] [--store DIR]       manifest an unpacked .app: per file, FastCDC inside big files
    restore MANIFEST --store DIR -o DIR            rebuild the tree; every file's sha256 must match
    delta OLD.json NEW.json                        bytes a client holding OLD must fetch

Chunking the .dmg itself is the "before": the DMG is LZFSE-compressed, so a change
moves every chunk after it (95% of the file between two consecutive NIGHTLYs). The
"after" is the uncompressed .app tree, whose unchanged files and code pages dedup;
the fetch is reported raw and compressed (zlib level 6 per chunk, a floor zstd beats).

This is the measurement and format slice; the Rust `cmux-cas` crate owns the
shipping implementation. Nothing here changes the update path.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import tempfile
import zlib
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
        _store_put(store, digest, piece)
        start = end
    return {
        "format": "cmux-cas-manifest/0",
        "chunker": {"kind": "fastcdc-gear-sha256", "min": MIN_SIZE, "avg": AVG_SIZE, "max": MAX_SIZE},
        "name": path.name,
        "size": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "chunks": chunks,
    }


def _store_put(store: Path | None, digest: str, piece: bytes) -> None:
    if store is None:
        return
    dest = store / digest[:2] / digest
    if dest.exists():
        return  # content-addressed: whoever wrote it first wrote the same bytes
    dest.parent.mkdir(parents=True, exist_ok=True)
    # A unique temp name per writer (pid plus random suffix), so parallel
    # builds sharing one store never rename each other's file.
    fd, tmp = tempfile.mkstemp(prefix=f"{digest}.{os.getpid()}.", suffix=".tmp", dir=dest.parent)
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(piece)
        os.replace(tmp, dest)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        if not dest.exists():
            raise


def _chunk_list(data: bytes, store: Path | None) -> list[dict]:
    out = []
    start = 0
    cuts = [len(data)] if len(data) <= MAX_SIZE else cut_points(data)
    for end in cuts:
        piece = data[start:end]
        digest = hashlib.sha256(piece).hexdigest()
        out.append({"sha256": digest, "size": end - start, "z": len(zlib.compress(piece, 6))})
        _store_put(store, digest, piece)
        start = end
    return out


def build_tree_manifest(root: Path, store: Path | None = None) -> dict:
    """Manifest every entry under root in sorted order: dirs, symlinks, files (mode, chunks)."""
    entries = []
    whole = hashlib.sha256()
    total = 0
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames.sort()
        base = Path(dirpath)
        for name in sorted(dirnames + filenames):
            path = base / name
            rel = path.relative_to(root).as_posix()
            st = path.lstat()
            if stat.S_ISLNK(st.st_mode):
                entries.append({"path": rel, "kind": "link", "target": os.readlink(path)})
                whole.update(f"L {rel} {os.readlink(path)}\n".encode())
            elif stat.S_ISDIR(st.st_mode):
                entries.append({"path": rel, "kind": "dir", "mode": stat.S_IMODE(st.st_mode)})
                whole.update(f"D {rel}\n".encode())
            elif stat.S_ISREG(st.st_mode):
                data = path.read_bytes()
                digest = hashlib.sha256(data).hexdigest()
                entries.append({"path": rel, "kind": "file", "mode": stat.S_IMODE(st.st_mode),
                                "size": len(data), "sha256": digest, "chunks": _chunk_list(data, store)})
                whole.update(f"F {rel} {digest}\n".encode())
                total += len(data)
    chunks = [c for e in entries if e["kind"] == "file" for c in e["chunks"]]
    return {
        "format": "cmux-cas-tree/0",
        "chunker": {"kind": "fastcdc-gear-sha256", "min": MIN_SIZE, "avg": AVG_SIZE, "max": MAX_SIZE,
                    "whole_file_below": MAX_SIZE},
        "name": root.name,
        "size": total,
        "sha256": whole.hexdigest(),
        "entries": entries,
        "chunks": chunks,
    }


def restore_tree(manifest: dict, store: Path, out: Path) -> None:
    out.mkdir(parents=True, exist_ok=False)
    for e in manifest["entries"]:
        dest = out / e["path"]
        if e["kind"] == "dir":
            dest.mkdir(exist_ok=True)
        elif e["kind"] == "link":
            os.symlink(e["target"], dest)
        else:
            h = hashlib.sha256()
            with dest.open("wb") as f:
                for c in e["chunks"]:
                    piece = (store / c["sha256"][:2] / c["sha256"]).read_bytes()
                    if hashlib.sha256(piece).hexdigest() != c["sha256"]:
                        raise SystemExit(f"chunk {c['sha256']} is corrupt")
                    h.update(piece)
                    f.write(piece)
            if h.hexdigest() != e["sha256"]:
                raise SystemExit(f"{e['path']}: restored sha256 differs from the manifest")
            os.chmod(dest, e["mode"])
    for e in reversed(manifest["entries"]):
        if e["kind"] == "dir":
            os.chmod(out / e["path"], e["mode"])


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
    zsize = {c["sha256"]: c["z"] for c in new["chunks"] if "z" in c}
    return {
        "from": old["name"],
        "to": new["name"],
        "full_bytes": new["size"],
        "fetch_bytes": fetch,
        "fetch_chunks": len(need),
        "total_chunks": len(new["chunks"]),
        "fetch_fraction": round(fetch / new["size"], 4) if new["size"] else 0.0,
        **({"fetch_bytes_compressed": sum(zsize[h] for h in need),
            "full_bytes_compressed": sum(zsize[c["sha256"]] for c in {c["sha256"]: c for c in new["chunks"]}.values())}
           if len(zsize) == len({c["sha256"] for c in new["chunks"]}) else {}),
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
    t = sub.add_parser("tree")
    t.add_argument("root", type=Path)
    t.add_argument("-o", "--out", type=Path)
    t.add_argument("--store", type=Path)
    r = sub.add_parser("restore")
    r.add_argument("manifest", type=Path)
    r.add_argument("--store", type=Path, required=True)
    r.add_argument("-o", "--out", type=Path, required=True)
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
    elif args.cmd == "tree":
        man = build_tree_manifest(args.root, args.store)
        text = json.dumps(man, indent=1)
        if args.out:
            args.out.write_text(text)
        else:
            print(text)
        print(f"{man['name']}: {man['size']} bytes, {len(man['entries'])} entries, {len(man['chunks'])} chunks", file=sys.stderr)
    elif args.cmd == "restore":
        restore_tree(json.loads(args.manifest.read_text()), args.store, args.out)
        print(f"restored {args.out}: every file's sha256 matches", file=sys.stderr)
    elif args.cmd == "assemble":
        assemble(json.loads(args.manifest.read_text()), args.store, args.out)
        print(f"assembled {args.out}: sha256 matches", file=sys.stderr)
    else:
        print(json.dumps(delta(json.loads(args.old.read_text()), json.loads(args.new.read_text())), indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
