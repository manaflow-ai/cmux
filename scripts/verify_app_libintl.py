#!/usr/bin/env python3
"""Fail a cmux release when shipped Mach-O code contains GNU libintl.

GNU libintl (gettext) is LGPL-2.1-or-later. cmux builds GhosttyKit and the
bundled ghostty CLI helper with -Di18n=false, so no shipped Mach-O file should
define a ``_libintl_*`` symbol. If one does, the release must carry the
complete corresponding source and the license text as release assets.

Usage:
  verify_app_libintl.py <app-or-dir> [--release-repo OWNER/REPO --release-tag TAG]

Exit 0 when no Mach-O file defines a libintl symbol, or when the release has
both source assets with the pinned sha256 digests. Exit 1 otherwise.

The Mach-O, fat and ar parsing is pure Python so the check and its tests run
on Linux CI as well as on the macOS release runners.
"""

from __future__ import annotations

import argparse
import json
import struct
import subprocess
import sys
from pathlib import Path

GETTEXT_VERSION = "0.24"
SOURCE_ASSETS = {
    # gettext 0.24 from https://ftp.gnu.org/pub/gnu/gettext/gettext-0.24.tar.gz
    # (same bytes as the deps.files.ghostty.org mirror pinned by Ghostty's
    # pkg/libintl/build.zig.zon).
    "gettext-0.24.tar.gz": "c918503d593d70daf4844d175a13d816afacb667c06fba1ec9dcd5002c1518b7",
    # gettext-0.24/gettext-runtime/intl/COPYING.LIB (LGPL 2.1), unchanged.
    "COPYING.LIB": "20e50fe7aae3e56378ebf0417d9de904f55a0e61e4df315333e632a4d3555d95",
}

MH_MAGIC = 0xFEEDFACE
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
LC_SYMTAB = 0x2
N_STAB = 0xE0
N_TYPE = 0x0E
N_UNDF = 0x0
AR_MAGIC = b"!<arch>\n"


def _macho_defined_symbols(data: bytes) -> list[str]:
    if len(data) < 28:
        return []
    magic_le = struct.unpack_from("<I", data, 0)[0]
    if magic_le == MH_MAGIC_64:
        endian, header_size, nlist_size, is64 = "<", 32, 16, True
    elif magic_le == MH_MAGIC:
        endian, header_size, nlist_size, is64 = "<", 28, 12, False
    else:
        return []
    ncmds = struct.unpack_from(endian + "I", data, 16)[0]
    offset = header_size
    names: list[str] = []
    for _ in range(ncmds):
        if offset + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack_from(endian + "II", data, offset)
        if cmd == LC_SYMTAB:
            symoff, nsyms, stroff, strsize = struct.unpack_from(endian + "IIII", data, offset + 8)
            for i in range(nsyms):
                entry = symoff + i * nlist_size
                if entry + nlist_size > len(data):
                    break
                strx, ntype = struct.unpack_from(endian + "IB", data, entry)
                if ntype & N_STAB or (ntype & N_TYPE) == N_UNDF:
                    continue
                start = stroff + strx
                if strx >= strsize or start >= len(data):
                    continue
                end = data.find(b"\0", start, stroff + strsize)
                names.append(data[start : end if end != -1 else stroff + strsize].decode("utf-8", "replace"))
        if cmdsize < 8:
            break
        offset += cmdsize
    _ = is64
    return names


def _ar_members(data: bytes):
    offset = len(AR_MAGIC)
    while offset + 60 <= len(data):
        header = data[offset : offset + 60]
        name = header[0:16].decode("ascii", "replace").strip()
        try:
            size = int(header[48:58].decode("ascii").strip())
        except ValueError:
            return
        body_start = offset + 60
        body = data[body_start : body_start + size]
        if name.startswith("#1/"):
            name_len = int(name[3:])
            name = body[:name_len].rstrip(b"\0").decode("utf-8", "replace")
            body = body[name_len:]
        yield name, body
        offset = body_start + size + (size & 1)


def libintl_symbols(data: bytes, label: str = "") -> list[str]:
    """Return '<member/arch>: <symbol>' lines for defined libintl symbols."""
    hits: list[str] = []
    if data.startswith(AR_MAGIC):
        for name, body in _ar_members(data):
            hits += libintl_symbols(body, f"{label}({name})")
        return hits
    if len(data) >= 8:
        magic_be = struct.unpack_from(">I", data, 0)[0]
        if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
            nfat = struct.unpack_from(">I", data, 4)[0]
            # Java class files share 0xCAFEBABE; real fat headers have few archs.
            if 0 < nfat < 32:
                entry_size = 32 if magic_be == FAT_MAGIC_64 else 20
                for i in range(nfat):
                    base = 8 + i * entry_size
                    if magic_be == FAT_MAGIC_64:
                        cputype, _, off, size = struct.unpack_from(">iiQQ", data, base)
                    else:
                        cputype, _, off, size = struct.unpack_from(">iiII", data, base)
                    hits += libintl_symbols(data[off : off + size], f"{label}[cpu {cputype}]")
                return hits
    for symbol in _macho_defined_symbols(data):
        if symbol.startswith("_libintl_") or symbol.startswith("__libintl_"):
            hits.append(f"{label}: {symbol}")
    return hits


def scan(root: Path) -> dict[str, list[str]]:
    results: dict[str, list[str]] = {}
    paths = [root] if root.is_file() else sorted(p for p in root.rglob("*") if p.is_file() and not p.is_symlink())
    for path in paths:
        with path.open("rb") as handle:
            head = handle.read(8)
        if not (head.startswith(AR_MAGIC) or (len(head) >= 4 and (
            struct.unpack_from("<I", head, 0)[0] in (MH_MAGIC, MH_MAGIC_64)
            or struct.unpack_from(">I", head, 0)[0] in (FAT_MAGIC, FAT_MAGIC_64)
        ))):
            continue
        hits = libintl_symbols(path.read_bytes())
        if hits:
            results[str(path.relative_to(root) if root.is_dir() else path)] = hits
    return results


def _gh_json(path: str):
    proc = subprocess.run(["gh", "api", path], capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        return None, proc.stderr.strip()
    return json.loads(proc.stdout), ""


def _find_release(repo: str, tag: str):
    release, err = _gh_json(f"repos/{repo}/releases/tags/{tag}")
    if isinstance(release, dict) and "assets" in release:
        return release, ""
    # The stable workflow keeps a new release as a draft until it is verified,
    # and the by-tag endpoint does not return drafts. Newest releases come first.
    listing, err2 = _gh_json(f"repos/{repo}/releases?per_page=100")
    if isinstance(listing, list):
        for candidate in listing:
            if candidate.get("tag_name") == tag:
                return candidate, ""
    return None, err or err2 or "not found"


def release_has_source(repo: str, tag: str) -> tuple[bool, str]:
    release, err = _find_release(repo, tag)
    if release is None:
        return False, f"cannot read release {repo}@{tag}: {err}"
    assets = {a.get("name"): a for a in release.get("assets", [])}
    problems = []
    for name, sha in SOURCE_ASSETS.items():
        asset = assets.get(name)
        if asset is None:
            problems.append(f"missing asset {name}")
        elif asset.get("digest") != f"sha256:{sha}":
            problems.append(f"asset {name} digest {asset.get('digest')} != sha256:{sha}")
    return (not problems), "; ".join(problems)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("path")
    parser.add_argument("--release-repo")
    parser.add_argument("--release-tag")
    args = parser.parse_args(argv)
    if bool(args.release_repo) != bool(args.release_tag):
        parser.error("--release-repo and --release-tag go together")

    root = Path(args.path)
    if not root.exists():
        print(f"error: {root} does not exist", file=sys.stderr)
        return 1
    results = scan(root)
    if not results:
        print(f"verified: no Mach-O file under {root} defines a libintl symbol")
        return 0

    for path, hits in results.items():
        print(f"libintl symbols in {path}:")
        for hit in hits[:8]:
            print(f"  {hit}")
        if len(hits) > 8:
            print(f"  ... {len(hits) - 8} more")

    if args.release_repo:
        ok, why = release_has_source(args.release_repo, args.release_tag)
        if ok:
            print(
                f"allowed: {args.release_repo}@{args.release_tag} carries the GNU gettext "
                f"{GETTEXT_VERSION} source and COPYING.LIB with the pinned digests"
            )
            return 0
        print(f"error: libintl is shipped but the release lacks its LGPL source: {why}", file=sys.stderr)
    else:
        print(
            "error: libintl (LGPL-2.1-or-later) is shipped. Build GhosttyKit and the ghostty CLI "
            "helper with -Di18n=false, or pass --release-repo/--release-tag of a release that "
            "carries " + " and ".join(SOURCE_ASSETS),
            file=sys.stderr,
        )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
