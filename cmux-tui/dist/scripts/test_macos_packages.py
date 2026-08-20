#!/usr/bin/env python3
"""Install and execute the cmux TUI wheel on native macOS runners."""

from __future__ import annotations

import argparse
import platform
import subprocess
import tempfile
import venv
from pathlib import Path


WHEEL_TAGS = {
    "arm64": "macosx_11_0_arm64",
    "x64": "macosx_10_12_x86_64",
}


def wheel_name(version: str, architecture: str) -> str:
    try:
        tag = WHEEL_TAGS[architecture]
    except KeyError as error:
        raise SystemExit(f"unsupported macOS architecture: {architecture}") from error
    return f"cmux-{version}-py3-none-{tag}.whl"


def host_architecture() -> str:
    if platform.system() != "Darwin":
        raise SystemExit(f"macOS wheel smoke requires Darwin, got {platform.system()}")
    machine = platform.machine().lower()
    if machine in {"arm64", "aarch64"}:
        return "arm64"
    if machine in {"x86_64", "amd64"}:
        return "x64"
    raise SystemExit(f"unsupported macOS machine: {machine}")


def run(wheels_dir: Path, version: str, architecture: str) -> None:
    wheel = wheels_dir / wheel_name(version, architecture)
    if not wheel.is_file():
        raise SystemExit(f"missing wheel for {architecture}: {wheel}")

    with tempfile.TemporaryDirectory(prefix="cmux-tui-macos-wheel-") as raw:
        root = Path(raw)
        environment = root / "venv"
        venv.EnvBuilder(with_pip=True, clear=True).create(environment)
        python = environment / "bin" / "python"
        command = [
            str(python),
            "-m",
            "pip",
            "install",
            "--disable-pip-version-check",
            "--no-index",
            "--no-deps",
            str(wheel.resolve()),
        ]
        subprocess.run(command, check=True)
        executable = environment / "bin" / "cmux"
        try:
            subprocess.run([str(executable), "--version"], check=True)
        except subprocess.CalledProcessError:
            subprocess.run([str(executable), "--help"], check=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wheels", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument(
        "--architecture",
        choices=tuple(WHEEL_TAGS),
        default=None,
        help="Expected wheel architecture; defaults to the native host.",
    )
    args = parser.parse_args()
    if not args.wheels.is_dir():
        parser.error(f"wheel directory does not exist: {args.wheels}")
    return args


def main() -> None:
    args = parse_args()
    actual_architecture = host_architecture()
    architecture = args.architecture or actual_architecture
    if actual_architecture != architecture:
        raise SystemExit(
            f"runner architecture does not match requested wheel: "
            f"{actual_architecture} != {architecture}"
        )
    run(args.wheels.resolve(), args.version, architecture)


if __name__ == "__main__":
    main()
