#!/usr/bin/env python3
"""Hash every source and build input that determines cmux-terminal-backend."""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import stat
import sys


EXCLUDED_DIRECTORIES = {
    ".build",
    ".git",
    ".zig-cache",
    "node_modules",
    "target",
    "zig-cache",
    "zig-out",
}


def source_files(root: pathlib.Path) -> list[pathlib.Path]:
    scan_roots = [
        root / "Packages/macOS/CmuxTerminalRenderer",
        root / "Packages/macOS/CmuxTerminalRenderTransport",
        root / "cmux-tui",
        root / "ghostty/include",
        root / "ghostty/src",
    ]
    explicit = [
        root / "ghostty/build.zig",
        root / "ghostty/build.zig.zon",
        root / "scripts/build-terminal-backend.sh",
        root / "scripts/build-terminal-renderer.sh",
        root / "scripts/audit-terminal-renderer-linkage.sh",
        root / "scripts/ensure-ghosttykit.sh",
        root / "scripts/test-terminal-renderer-helper.sh",
        root / "scripts/terminal-backend-build-fingerprint.py",
        root / "Resources/cmux-terminal-backend.entitlements",
    ]
    discovered: list[pathlib.Path] = []
    for scan_root in scan_roots:
        if not scan_root.exists():
            raise FileNotFoundError(scan_root)
        for directory, names, filenames in os.walk(scan_root):
            names[:] = sorted(name for name in names if name not in EXCLUDED_DIRECTORIES)
            for filename in sorted(filenames):
                path = pathlib.Path(directory) / filename
                if path.name != ".DS_Store":
                    discovered.append(path)
    discovered.extend(path for path in explicit if path.exists())
    return sorted(set(discovered), key=lambda path: path.relative_to(root).as_posix())


def digest(root: pathlib.Path, metadata: list[str], files: list[pathlib.Path]) -> str:
    result = hashlib.sha256()
    for item in sorted(metadata):
        result.update(b"metadata\0")
        result.update(item.encode("utf-8"))
        result.update(b"\0")
    for path in files:
        relative = path.relative_to(root).as_posix().encode("utf-8")
        mode = path.lstat().st_mode
        result.update(b"path\0" + relative + b"\0")
        result.update(b"executable\0" + (b"1" if mode & stat.S_IXUSR else b"0") + b"\0")
        if path.is_symlink():
            result.update(b"symlink\0" + os.readlink(path).encode("utf-8") + b"\0")
        else:
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    result.update(chunk)
            result.update(b"\0")
    return result.hexdigest()


def makefile_escape(value: str) -> str:
    return (
        value.replace("\\", "\\\\")
        .replace(" ", "\\ ")
        .replace("#", "\\#")
        .replace(":", "\\:")
        .replace("$", "$$")
    )


def write_dependency_file(
    path: pathlib.Path,
    target: pathlib.Path,
    files: list[pathlib.Path],
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f"{path.name}.tmp.{os.getpid()}")
    dependencies = " \\\n  ".join(makefile_escape(str(item)) for item in files)
    temporary.write_text(
        f"{makefile_escape(str(target))}: \\\n  {dependencies}\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parents[1],
    )
    parser.add_argument("--metadata", action="append", default=[])
    parser.add_argument("--dependency-file", type=pathlib.Path)
    parser.add_argument("--dependency-target", type=pathlib.Path)
    args = parser.parse_args()
    try:
        root = args.root.resolve()
        files = source_files(root)
        if (args.dependency_file is None) != (args.dependency_target is None):
            parser.error("--dependency-file and --dependency-target must be used together")
        if args.dependency_file is not None:
            write_dependency_file(
                args.dependency_file,
                args.dependency_target,
                files,
            )
        print(digest(root, args.metadata, files))
    except OSError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
