#!/usr/bin/env python3
"""Create a deterministic, source-only cmux web tarball for CI."""

from __future__ import annotations

import gzip
import os
import stat
import sys
import tarfile
from pathlib import Path


EXCLUDED_NAMES = {
    "node_modules",
    ".next",
    ".turbo",
    ".cache",
    ".env",
    ".envrc",
    ".DS_Store",
    "coverage",
}


def excluded(name: str) -> bool:
    return name in EXCLUDED_NAMES or name.startswith(".env.")


def normalized_info(path: Path, name: str, mode: int, directory: bool) -> tarfile.TarInfo:
    info = tarfile.TarInfo(name)
    info.type = tarfile.DIRTYPE if directory else tarfile.REGTYPE
    info.mode = mode
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.mtime = 0
    if not directory:
        info.size = path.stat().st_size
    return info


def add_tree(archive: tarfile.TarFile, root: Path) -> None:
    archive.addfile(normalized_info(root, "web", 0o755, True))
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        directories.sort()
        files.sort()
        kept_directories: list[str] = []
        for name in directories:
            if excluded(name):
                continue
            path = current_path / name
            if path.is_symlink():
                raise ValueError(f"source contains a symlink: {path}")
            relative = path.relative_to(root).as_posix()
            archive.addfile(normalized_info(path, f"web/{relative}", 0o755, True))
            kept_directories.append(name)
        directories[:] = kept_directories
        for name in files:
            if excluded(name):
                continue
            path = current_path / name
            metadata = path.lstat()
            if stat.S_ISLNK(metadata.st_mode):
                raise ValueError(f"source contains a symlink: {path}")
            if not stat.S_ISREG(metadata.st_mode):
                raise ValueError(f"source contains a non-regular file: {path}")
            relative = path.relative_to(root).as_posix()
            mode = 0o755 if metadata.st_mode & 0o111 else 0o644
            info = normalized_info(path, f"web/{relative}", mode, False)
            with path.open("rb") as input_file:
                archive.addfile(info, input_file)


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
