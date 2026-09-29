#!/usr/bin/env python3
"""Create a deterministic, source-only web archive for the CI backend."""

from __future__ import annotations

import gzip
import os
import stat
import sys
import tarfile
from pathlib import Path

EXCLUDED = {"node_modules", ".next", ".turbo", ".cache", ".env", ".envrc", ".DS_Store", "coverage"}


def info(path: Path, name: str, mode: int, directory: bool) -> tarfile.TarInfo:
    result = tarfile.TarInfo(name)
    result.type = tarfile.DIRTYPE if directory else tarfile.REGTYPE
    result.mode = mode
    result.uid = result.gid = 0
    result.uname = result.gname = ""
    result.mtime = 0
    if not directory:
        result.size = path.stat().st_size
    return result


def add_tree(archive: tarfile.TarFile, root: Path) -> None:
    archive.addfile(info(root, "web", 0o755, True))
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        directories[:] = sorted(name for name in directories if name not in EXCLUDED)
        files = sorted(name for name in files if name not in EXCLUDED and not name.startswith(".env."))
        for name in directories:
            path = current_path / name
            if path.is_symlink():
                raise ValueError(f"source contains a symlink: {path}")
            archive.addfile(info(path, f"web/{path.relative_to(root).as_posix()}", 0o755, True))
        for name in files:
            path = current_path / name
            metadata = path.lstat()
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                raise ValueError(f"source contains an unsupported file: {path}")
            mode = 0o755 if metadata.st_mode & 0o111 else 0o644
            member = info(path, f"web/{path.relative_to(root).as_posix()}", mode, False)
            with path.open("rb") as source:
                archive.addfile(member, source)


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} CHECKOUT OUTPUT", file=sys.stderr)
        return 2
    checkout = Path(sys.argv[1]).resolve()
    output = Path(sys.argv[2]).resolve()
    root = checkout / "web"
    if root.is_symlink() or not root.is_dir():
        print(f"checkout has no web/ directory: {checkout}", file=sys.stderr)
        return 1
    output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        with output.open("wb") as raw:
            with gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                    add_tree(archive, root)
    except (OSError, ValueError, tarfile.TarError) as error:
        print(f"could not create source archive: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
