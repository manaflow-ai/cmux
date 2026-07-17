#!/usr/bin/env python3
"""Transfer generated npm package directories without losing executable modes."""

from __future__ import annotations

import argparse
import stat
import tarfile
from pathlib import Path, PurePosixPath


PACKAGE_ROOT = "npm-packages"
EXECUTABLES = (
    "cmux-tui-darwin-arm64/bin/cmux-tui",
    "cmux-tui-darwin-x64/bin/cmux-tui",
    "cmux-tui-linux-x64/bin/cmux-tui",
    "cmux-tui-linux-arm64/bin/cmux-tui",
    "cmux/bin/cmux.js",
)
MAX_MEMBERS = 1_024
MAX_EXPANDED_BYTES = 512 * 1024 * 1024


def verify_executables(packages_dir: Path) -> None:
    if not packages_dir.is_dir():
        raise SystemExit(f"missing npm package directory: {packages_dir}")
    if packages_dir.name != PACKAGE_ROOT:
        raise SystemExit(f"npm package directory must be named {PACKAGE_ROOT}")

    for relative_path in EXECUTABLES:
        executable = packages_dir / relative_path
        if not executable.is_file():
            raise SystemExit(f"missing npm package executable: {executable}")
        if not executable.stat().st_mode & stat.S_IXUSR:
            raise SystemExit(f"npm package entry is not executable: {executable}")


def create_archive(packages_dir: Path, archive: Path) -> None:
    packages_dir = packages_dir.resolve()
    archive = archive.resolve()
    verify_executables(packages_dir)
    if archive == packages_dir or packages_dir in archive.parents:
        raise SystemExit("npm package archive must be outside the package directory")
    archive.parent.mkdir(parents=True, exist_ok=True)
    if archive.exists():
        archive.unlink()
    with tarfile.open(archive, "w:gz") as output:
        output.add(packages_dir, arcname=PACKAGE_ROOT, recursive=True)


def validated_members(archive: tarfile.TarFile) -> list[tarfile.TarInfo]:
    members = archive.getmembers()
    if not members:
        raise SystemExit("npm package archive is empty")
    if len(members) > MAX_MEMBERS:
        raise SystemExit("npm package archive has too many entries")

    seen: set[str] = set()
    expanded_bytes = 0
    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts:
            raise SystemExit(f"unsafe npm package archive path: {member.name}")
        if not path.parts or path.parts[0] != PACKAGE_ROOT:
            raise SystemExit(f"npm package archive entry is outside {PACKAGE_ROOT}")
        normalized_name = path.as_posix()
        if normalized_name in seen:
            raise SystemExit(f"duplicate npm package archive entry: {member.name}")
        seen.add(normalized_name)
        if not (member.isfile() or member.isdir()):
            raise SystemExit(f"unsupported npm package archive entry: {member.name}")
        member.mode &= 0o777
        expanded_bytes += member.size
        if expanded_bytes > MAX_EXPANDED_BYTES:
            raise SystemExit("npm package archive exceeds expanded size limit")
    return members


def extract_archive(archive_path: Path, out_dir: Path) -> None:
    archive_path = archive_path.resolve()
    out_dir = out_dir.resolve()
    packages_dir = out_dir / PACKAGE_ROOT
    if packages_dir.exists():
        raise SystemExit(f"refusing to replace existing directory: {packages_dir}")
    out_dir.mkdir(parents=True, exist_ok=True)

    with tarfile.open(archive_path, "r:gz") as archive:
        members = validated_members(archive)
        archive.extractall(out_dir, members=members, filter="tar")
    verify_executables(packages_dir)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    create = subparsers.add_parser("create")
    create.add_argument("--packages-dir", required=True, type=Path)
    create.add_argument("--archive", required=True, type=Path)

    extract = subparsers.add_parser("extract")
    extract.add_argument("--archive", required=True, type=Path)
    extract.add_argument("--out", required=True, type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.command == "create":
        create_archive(args.packages_dir, args.archive)
    else:
        extract_archive(args.archive, args.out)


if __name__ == "__main__":
    main()
