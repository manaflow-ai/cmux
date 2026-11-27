#!/usr/bin/env python3
"""Stores the viewers' lazy chunks raw-deflated in the app (CMUX-570, app size).

    pack-webviews-chunks.py WEBVIEWS_APP_DIR

The markdown, diff and editor pages share one build, `Resources/markdown-viewer/webviews-app`;
its `chunks/` folder (about 13 MB of JavaScript in about 470 files) is what their entries import.
The agent pane's `chunks/` (`CmuxNext_CmuxNextAgentPane.bundle/Contents/Resources/agent-pane`,
about 4.6 MB: KaTeX, emoji data, the editors, the new-tab screen) are code `pane.js` imports when
used, never at first paint; the same phase packs them, and acpmux's disk read of the pane
(app_assets.rs) and its handler (AgentPaneSchemeHandler) inflate them as the pages' readers do.
The app build ("Pack webviews-app chunks" phase of the cmux-next target) replaces each chunk with
`<name>.deflate` (raw DEFLATE, level 9: the format pack-pages.mjs gives the pages' `__shared`
scripts) in the built app, when that takes fewer 4 KiB disk blocks. Every reader inflates the
packed copy in memory when a page asks for the chunk, and only when the file itself is missing:
Chromium's cmux-page:// handler (CEFShim cmux_page_packed.h), and the app's own handler for WebKit,
the live web loop and an overlay (CmuxNextPages PagePackedFile.swift). Nothing is written outside
the signed bundle and nothing is downloaded.

The source tree's build (`scripts/build-webviews-app.sh`), the web updates and the overlay stay
raw: only the app's copy is packed, so the bundle checks and the updates read what they did.

Idempotent: an incremental build copies the raw chunks again, and this packs them again (a raw
file beside its packed copy is the newer one; the readers prefer it too).
"""

from __future__ import annotations

import argparse
import os
import sys
import tempfile
import zlib
from pathlib import Path

SUFFIX = ".deflate"
# The file types the page handler serves from chunks/ (CEFShim cmux_page_path.h PageMimeType).
PACKED_EXTENSIONS = (".mjs", ".js", ".css", ".json", ".wasm")
BLOCK = 4096


def deflate_raw(raw: bytes) -> bytes:
    """Raw DEFLATE (RFC 1951, no zlib header), level 9; checks that it inflates back."""
    packer = zlib.compressobj(9, zlib.DEFLATED, -15, 9)
    packed = packer.compress(raw) + packer.flush()
    if zlib.decompress(packed, -15) != raw:
        raise SystemExit("pack-webviews-chunks: a packed chunk does not inflate to itself")
    return packed


def blocks(size: int) -> int:
    return (size + BLOCK - 1) // BLOCK


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


def pack_folder(app: Path) -> list[tuple[str, int, int]]:
    """Packs every raw chunk under `app`/chunks that packs into fewer blocks.

    Returns (path relative to `app`, raw bytes, packed bytes) for each packed file."""
    chunks = app / "chunks"
    done = []
    if not chunks.is_dir():
        return done
    for path in sorted(chunks.rglob("*")):
        if path.is_symlink() or not path.is_file() or path.suffix not in PACKED_EXTENSIONS:
            continue
        raw = path.read_bytes()
        packed = deflate_raw(raw)
        target = path.with_name(path.name + SUFFIX)
        if blocks(len(packed)) >= blocks(len(raw)):
            # Kept raw; a packed copy an older build left would only be unread weight.
            if target.exists():
                target.unlink()
            continue
        write_atomic(target, packed)
        path.unlink()
        done.append((str(path.relative_to(app)), len(raw), len(packed)))
    return done


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("app", type=Path, help="the built app's markdown-viewer/webviews-app or agent-pane folder")
    args = parser.parse_args(argv)
    if not args.app.is_dir():
        print(f"pack-webviews-chunks: no {args.app}; nothing to pack")
        return 0
    done = pack_folder(args.app)
    raw = sum(item[1] for item in done)
    packed = sum(item[2] for item in done)
    print(f"pack-webviews-chunks: packed {len(done)} chunks, {raw} -> {packed} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
