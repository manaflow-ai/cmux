#!/usr/bin/env python3
"""Stores the markdown viewer's diagram libraries packed in the app (CMUX-570, app size).

    pack-markdown-libraries.py MARKDOWN_VIEWER_DIR [--cache DIR]

Mermaid, Ondine and Vega (`Resources/markdown-viewer/*.min.js`, 6.4 MB) run only when a page
draws a diagram or a chart, never on a page's first load. The app build ("Pack markdown-viewer
libraries" phase of the cmux-next target) replaces each with `<name>.xz` (LZMA2 in the xz
container, 1.6 MB together) in the built app; the app unpacks one into its caches the first time
something asks for it and reads it from there after (CmuxNextPages PackedResource.swift). They stay
in the app: offline, from the first use, every diagram type as before.

xz, not zstd: the system's Compression framework reads it (`NSData.decompressed(using: .lzma)`), so
the app gains no decoder, and it packs these files about 7% smaller than zstd -19.

Idempotent: a file already packed is skipped, so the phase can run on every incremental build
(Xcode copies the folder again and the raw files come back). --cache keeps each packed file by
the hash of its source, so an unchanged library is not compressed again. A Python without `lzma`
leaves the files as they are and says so: the app reads either form.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
import tempfile
from pathlib import Path

# What runs only when a page draws a diagram or a chart (MarkdownPageResource.libraryFiles, Home's
# Ondine renderer); vega-embed.min.js only the dev host loads.
PACKED = ("mermaid.min.js", "ondine.min.js", "vega.min.js", "vega-lite.min.js", "vega-embed.min.js")
SUFFIX = ".xz"


def pack_bytes(raw: bytes) -> bytes:
    import lzma

    # The largest library is 3.6 MB: an 8 MiB dictionary holds any of them whole, and the
    # decoder allocates no more than that (preset 9's own is 64 MiB).
    filters = [{"id": lzma.FILTER_LZMA2, "preset": 9 | lzma.PRESET_EXTREME, "dict_size": 8 << 20}]
    packed = lzma.compress(raw, format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC64, filters=filters)
    if lzma.decompress(packed) != raw:
        raise SystemExit("pack-markdown-libraries: a packed library does not unpack to itself")
    return packed


def write_atomic(path: Path, data: bytes) -> None:
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def pack_folder(folder: Path, cache: Path | None = None) -> list[tuple[str, int, int]]:
    """Packs every PACKED file `folder` holds raw; returns (name, raw bytes, packed bytes) for each."""
    done = []
    for name in PACKED:
        raw_path, packed_path = folder / name, folder / (name + SUFFIX)
        if not raw_path.is_file():
            continue
        raw = raw_path.read_bytes()
        packed = None
        cached = cache / f"{hashlib.sha256(raw).hexdigest()}{SUFFIX}" if cache else None
        if cached and cached.is_file():
            packed = cached.read_bytes()
            try:  # a cache entry is never trusted: it must unpack to this very source
                import lzma

                if lzma.decompress(packed) != raw:
                    packed = None
            except Exception:
                packed = None
        if packed is None:
            packed = pack_bytes(raw)
            if cached:
                cache.mkdir(parents=True, exist_ok=True)
                write_atomic(cached, packed)
        write_atomic(packed_path, packed)
        # The unpacked bytes' SHA-256, inside the signed app: the app's own cache of the unpacked
        # file is served only when it matches (PackedResource.swift).
        write_atomic(folder / (name + SUFFIX + ".sha256"), hashlib.sha256(raw).hexdigest().encode())
        raw_path.unlink()
        done.append((name, len(raw), len(packed)))
    return done


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("folder", type=Path)
    parser.add_argument("--cache", type=Path)
    args = parser.parse_args(argv)
    if not args.folder.is_dir():
        print(f"pack-markdown-libraries: no {args.folder}; nothing to pack")
        return 0
    try:
        import lzma  # noqa: F401
    except ImportError:
        print("warning: pack-markdown-libraries: this Python has no lzma module; the libraries stay unpacked")
        return 0
    for name, raw, packed in pack_folder(args.folder, args.cache):
        print(f"packed {name}: {raw} -> {packed} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
