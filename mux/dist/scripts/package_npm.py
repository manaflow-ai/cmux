#!/usr/bin/env python3
"""Build npm packages for the cmux TUI launcher and platform binaries."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import stat
from pathlib import Path


TARGETS = [
    {
        "rust_target": "aarch64-apple-darwin",
        "package": "cmux-tui-darwin-arm64",
        "os": "darwin",
        "cpu": "arm64",
    },
    {
        "rust_target": "x86_64-apple-darwin",
        "package": "cmux-tui-darwin-x64",
        "os": "darwin",
        "cpu": "x64",
    },
    {
        "rust_target": "x86_64-unknown-linux-gnu",
        "package": "cmux-tui-linux-x64",
        "os": "linux",
        "cpu": "x64",
    },
    {
        "rust_target": "aarch64-unknown-linux-gnu",
        "package": "cmux-tui-linux-arm64",
        "os": "linux",
        "cpu": "arm64",
    },
]

VERSION_RE = re.compile(
    r"^(?:[0-9]+\.[0-9]+\.[0-9]+|[0-9]+\.[0-9]+\.[0-9]+-nightly\.[0-9]{8}\.[0-9]+)$"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate cmux TUI npm launcher and platform packages."
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
        help="Package version in X.Y.Z or X.Y.Z-nightly.YYYYMMDD.N form.",
    )
    parser.add_argument(
        "--out",
        required=True,
        type=Path,
        help="Output directory for generated npm package directories.",
    )
    return parser.parse_args()


def write_json(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def copy_executable(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)
    mode = dst.stat().st_mode
    dst.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def recreate_dir(path: Path) -> None:
    if path.exists():
        if not path.is_dir():
            raise SystemExit(f"{path} exists and is not a directory")
        shutil.rmtree(path)
    path.mkdir(parents=True)


def package_platforms(binaries_dir: Path, version: str, out_dir: Path) -> None:
    for target in TARGETS:
        src = binaries_dir / f"cmux-mux-{target['rust_target']}"
        if not src.is_file():
            raise SystemExit(f"missing binary: {src}")

        package_dir = out_dir / target["package"]
        recreate_dir(package_dir)
        copy_executable(src, package_dir / "bin" / "cmux-mux")

        write_json(
            package_dir / "package.json",
            {
                "name": target["package"],
                "version": version,
                "description": (
                    "Prebuilt cmux-mux TUI binary for "
                    f"{target['os']}-{target['cpu']}."
                ),
                "repository": {
                    "type": "git",
                    "url": "git+https://github.com/manaflow-ai/cmux.git",
                    "directory": "mux/dist",
                },
                "license": "MIT",
                "os": [target["os"]],
                "cpu": [target["cpu"]],
                "files": ["bin/cmux-mux"],
            },
        )


def package_launcher(version: str, out_dir: Path) -> None:
    source_dir = Path(__file__).resolve().parents[1] / "npm" / "cmux"
    if not source_dir.is_dir():
        raise SystemExit(f"missing launcher template: {source_dir}")

    launcher_dir = out_dir / "cmux"
    recreate_dir(launcher_dir)
    shutil.copytree(source_dir, launcher_dir, dirs_exist_ok=True)

    package_json_path = launcher_dir / "package.json"
    package_json = json.loads(package_json_path.read_text())
    package_json["version"] = version
    package_json["optionalDependencies"] = {
        target["package"]: version for target in TARGETS
    }
    write_json(package_json_path, package_json)

    launcher_bin = launcher_dir / "bin" / "cmux.js"
    if launcher_bin.exists():
        launcher_bin.chmod(
            launcher_bin.stat().st_mode
            | stat.S_IXUSR
            | stat.S_IXGRP
            | stat.S_IXOTH
        )


def main() -> None:
    args = parse_args()
    if not VERSION_RE.fullmatch(args.version):
        raise SystemExit("--version must match X.Y.Z or X.Y.Z-nightly.YYYYMMDD.N")

    binaries_dir = args.binaries_dir.resolve()
    out_dir = args.out.resolve()
    if not binaries_dir.is_dir():
        raise SystemExit(f"--binaries-dir is not a directory: {binaries_dir}")
    out_dir.mkdir(parents=True, exist_ok=True)

    package_platforms(binaries_dir, args.version, out_dir)
    package_launcher(args.version, out_dir)


if __name__ == "__main__":
    main()
