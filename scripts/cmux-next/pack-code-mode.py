#!/usr/bin/env python3
"""Pack the app's code-mode folder into one xz tar (CMUX-570, app size).

`cmux run` and the code-mode MCP read `Resources/code-mode` (the TypeScript SDK, its runner
scripts and the operation catalogs): 3.5 MB in 54 files, about 0.3 MB packed. The app ships
`Resources/code-mode.tar.xz`; `bin/cmux-code-mode-unpack` unpacks it into the user's cache the
first time code mode runs and every later run reads that copy. Nothing is downloaded.

The archive is deterministic (sorted names, no owners, mtime 0) so an unchanged folder gives the
same bytes, and this script reads it back and fails unless every file comes out byte for byte
with its mode.

  pack-code-mode.py FOLDER ARCHIVE     # FOLDER/<name>/... becomes <name>/... in ARCHIVE
"""
from __future__ import annotations

import io
import lzma
import os
import sys
import tarfile
import tempfile
from pathlib import Path

PRESET = 9 | lzma.PRESET_EXTREME


def entries(folder: Path) -> list[tuple[str, Path]]:
    """(archive name, path) for every directory and file under folder, its own name first."""
    out = [(folder.name, folder)]
    for path in sorted(folder.rglob("*")):
        if path.is_symlink():
            raise SystemExit(f"pack-code-mode: {path} is a symlink; the archive holds files only")
        out.append((f"{folder.name}/{path.relative_to(folder).as_posix()}", path))
    return out


def pack(folder: Path) -> bytes:
    buffer = io.BytesIO()
    with lzma.LZMAFile(buffer, "wb", format=lzma.FORMAT_XZ, preset=PRESET) as xz:
        with tarfile.open(fileobj=xz, mode="w", format=tarfile.PAX_FORMAT) as tar:
            for name, path in entries(folder):
                info = tarfile.TarInfo(name)
                info.mode = path.stat().st_mode & 0o777
                info.mtime = 0
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                if path.is_dir():
                    info.type = tarfile.DIRTYPE
                    tar.addfile(info)
                else:
                    data = path.read_bytes()
                    info.size = len(data)
                    tar.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def verify(folder: Path, packed: bytes) -> None:
    """Every file and folder comes back with its bytes and mode, and nothing else is in it."""
    want = {name: path for name, path in entries(folder)}
    seen = set()
    with tarfile.open(fileobj=io.BytesIO(lzma.decompress(packed)), mode="r:") as tar:
        for info in tar:
            path = want.get(info.name)
            if path is None:
                raise SystemExit(f"pack-code-mode: {info.name} is in the archive but not in {folder}")
            if info.mode != path.stat().st_mode & 0o777:
                raise SystemExit(f"pack-code-mode: {info.name} lost its mode")
            if info.isfile():
                data = tar.extractfile(info).read()
                if data != path.read_bytes():
                    raise SystemExit(f"pack-code-mode: {info.name} does not unpack to its bytes")
            elif not (info.isdir() and path.is_dir()):
                raise SystemExit(f"pack-code-mode: {info.name} changed type")
            seen.add(info.name)
    missing = sorted(set(want) - seen)
    if missing:
        raise SystemExit(f"pack-code-mode: missing from the archive: {', '.join(missing[:5])}")


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    folder, archive = Path(argv[1]), Path(argv[2])
    if not folder.is_dir():
        print(f"pack-code-mode: {folder} is not a folder", file=sys.stderr)
        return 2
    packed = pack(folder)
    verify(folder, packed)
    if archive.exists() and archive.read_bytes() == packed:
        return 0
    archive.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{archive.name}.", dir=archive.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(packed)
        os.chmod(temporary, 0o644)
        os.replace(temporary, archive)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise
    raw = sum(p.stat().st_size for _, p in entries(folder) if p.is_file())
    print(f"pack-code-mode: {archive.name} {len(packed)} bytes ({raw} unpacked)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
