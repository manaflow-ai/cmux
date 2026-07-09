#!/usr/bin/env python3
"""Build PyPI wheels for the cmux TUI with bundled platform binaries."""

from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import io
import re
import stat
import zipfile
from dataclasses import dataclass
from pathlib import Path


VERSION_RE = re.compile(r"^(?:[0-9]+\.[0-9]+\.[0-9]+|[0-9]+\.[0-9]+\.[0-9]+\.dev[0-9]{9,})$")
DIST_NAME = "cmux"
PACKAGE_NAME = "cmux_tui"
ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)


@dataclass(frozen=True)
class Target:
    rust_target: str
    platform_tag: str


TARGETS = [
    Target("aarch64-apple-darwin", "macosx_11_0_arm64"),
    Target("x86_64-apple-darwin", "macosx_10_12_x86_64"),
    Target("x86_64-unknown-linux-gnu", "manylinux_2_17_x86_64.manylinux2014_x86_64"),
    Target("aarch64-unknown-linux-gnu", "manylinux_2_17_aarch64.manylinux2014_aarch64"),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate cmux TUI PyPI wheels with bundled binaries."
    )
    parser.add_argument(
        "--binaries-dir",
        required=True,
        type=Path,
        help="Directory containing cmux-mux-<rust-target> binaries.",
    )
    parser.add_argument(
        "--version",
        required=True,
        help="Package version in X.Y.Z or X.Y.Z.devYYYYMMDDN form.",
    )
    parser.add_argument(
        "--out",
        required=True,
        type=Path,
        help="Output directory for generated wheels.",
    )
    return parser.parse_args()


def text_bytes(text: str) -> bytes:
    return text.encode("utf-8")


def sha256_record_digest(data: bytes) -> str:
    digest = hashlib.sha256(data).digest()
    return "sha256=" + base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


def wheel_info(name: str, data: bytes, mode: int) -> tuple[zipfile.ZipInfo, bytes, int]:
    info = zipfile.ZipInfo(name, ZIP_TIMESTAMP)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 3
    info.external_attr = ((stat.S_IFREG | mode) & 0xFFFF) << 16
    return info, data, mode


def wheel_bytes(version: str, tag: str, binary: bytes) -> list[tuple[str, bytes, int]]:
    dist_info = f"{DIST_NAME}-{version}.dist-info"
    return [
        (
            f"{PACKAGE_NAME}/__init__.py",
            text_bytes(f'"""cmux TUI wheel package."""\n\n__version__ = "{version}"\n'),
            0o644,
        ),
        (
            f"{PACKAGE_NAME}/_main.py",
            text_bytes(
                """from __future__ import annotations

import os
import pathlib
import sys


def main() -> None:
    binary = pathlib.Path(__file__).resolve().parent / "bin" / "cmux-mux"
    os.execv(str(binary), ["cmux", *sys.argv[1:]])
"""
            ),
            0o644,
        ),
        (f"{PACKAGE_NAME}/bin/cmux-mux", binary, 0o755),
        (
            f"{dist_info}/WHEEL",
            text_bytes(
                f"""Wheel-Version: 1.0
Generator: cmux-dist
Root-Is-Purelib: false
Tag: py3-none-{tag}
"""
            ),
            0o644,
        ),
        (
            f"{dist_info}/METADATA",
            text_bytes(
                f"""Metadata-Version: 2.1
Name: {DIST_NAME}
Version: {version}
Summary: cmux \u2014 a tmux-like terminal multiplexer TUI backed by libghostty-vt
License: MIT
Project-URL: Source, https://github.com/manaflow-ai/cmux
"""
            ),
            0o644,
        ),
        (
            f"{dist_info}/entry_points.txt",
            text_bytes(
                """[console_scripts]
cmux = cmux_tui._main:main
"""
            ),
            0o644,
        ),
    ]


def write_wheel(path: Path, files: list[tuple[str, bytes, int]], version: str) -> None:
    dist_info = f"{DIST_NAME}-{version}.dist-info"
    record_name = f"{dist_info}/RECORD"
    rows: list[list[str]] = []

    with zipfile.ZipFile(path, "w") as wheel:
        for name, data, mode in files:
            info, content, _ = wheel_info(name, data, mode)
            wheel.writestr(info, content)
            rows.append([name, sha256_record_digest(content), str(len(content))])

        rows.append([record_name, "", ""])
        record_buffer = io.StringIO(newline="")
        writer = csv.writer(record_buffer, lineterminator="\n")
        writer.writerows(rows)
        record_data = record_buffer.getvalue().encode("utf-8")
        record_info, _, _ = wheel_info(record_name, record_data, 0o644)
        wheel.writestr(record_info, record_data)


def main() -> None:
    args = parse_args()
    if not VERSION_RE.fullmatch(args.version):
        raise SystemExit("--version must match X.Y.Z or X.Y.Z.devYYYYMMDDN")

    binaries_dir = args.binaries_dir.resolve()
    out_dir = args.out.resolve()
    if not binaries_dir.is_dir():
        raise SystemExit(f"--binaries-dir is not a directory: {binaries_dir}")
    out_dir.mkdir(parents=True, exist_ok=True)

    for target in TARGETS:
        binary_path = binaries_dir / f"cmux-mux-{target.rust_target}"
        if not binary_path.is_file():
            raise SystemExit(f"missing binary: {binary_path}")
        wheel_name = f"{DIST_NAME}-{args.version}-py3-none-{target.platform_tag}.whl"
        wheel_path = out_dir / wheel_name
        if wheel_path.exists():
            wheel_path.unlink()
        write_wheel(
            wheel_path,
            wheel_bytes(args.version, target.platform_tag, binary_path.read_bytes()),
            args.version,
        )


if __name__ == "__main__":
    main()
