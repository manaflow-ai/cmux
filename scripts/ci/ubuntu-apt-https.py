#!/usr/bin/env python3
"""Switch Ubuntu package sources to HTTPS on runners with HTTP blocked."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


# Keep this deliberately narrow: third-party repositories may not provide HTTPS,
# and changing their configuration would make an unrelated package install fail.
BLACKSMITH_MIRROR = re.compile(
    r"(?<!\S)mirror\+file:/etc/apt/blacksmith-ubuntu-mirrors\.txt/?(?=\s|$)"
)
UBUNTU_ARCHIVE = re.compile(
    r"(?<!\S)http://(?:[A-Za-z0-9-]+\.)?archive\.ubuntu\.com/ubuntu(?P<trailing>/?)"
    r"(?=\s|$)"
)
UBUNTU_SECURITY = re.compile(
    r"(?<!\S)http://security\.ubuntu\.com/ubuntu(?P<trailing>/?)(?=\s|$)"
)


def source_files(apt_root: Path) -> list[Path]:
    files = []
    root_sources = apt_root / "sources.list"
    if root_sources.is_file():
        files.append(root_sources)
    source_dir = apt_root / "sources.list.d"
    if source_dir.is_dir():
        files.extend(
            path
            for path in sorted(source_dir.iterdir())
            if path.is_file() and path.suffix in {".list", ".sources"}
        )
    return files


def normalize(contents: str) -> str:
    contents = BLACKSMITH_MIRROR.sub("https://archive.ubuntu.com/ubuntu", contents)
    contents = UBUNTU_ARCHIVE.sub(
        lambda match: "https://archive.ubuntu.com/ubuntu" + match.group("trailing"),
        contents,
    )
    return UBUNTU_SECURITY.sub(
        lambda match: "https://security.ubuntu.com/ubuntu" + match.group("trailing"),
        contents,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "apt_root",
        nargs="?",
        type=Path,
        default=Path("/etc/apt"),
        help="APT configuration directory (default: /etc/apt)",
    )
    args = parser.parse_args()

    for path in source_files(args.apt_root):
        original = path.read_text(encoding="utf-8")
        updated = normalize(original)
        if updated == original:
            continue
        path.write_text(updated, encoding="utf-8")
        print(f"Updated Ubuntu APT source: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
