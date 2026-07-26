#!/usr/bin/env python3
"""Run packaged cmux TUI entrypoints across Linux runtime families."""

from __future__ import annotations

import argparse
import pathlib
import shutil
import subprocess
import tempfile


NPM_IMAGES = (
    ("debian-12", "node:22-bookworm-slim"),
    ("debian-11", "node:22-bullseye-slim"),
    ("alpine", "node:22-alpine"),
)

UVX_IMAGES = (
    ("debian-12", "ghcr.io/astral-sh/uv:python3.12-bookworm-slim"),
    ("alpine", "ghcr.io/astral-sh/uv:python3.12-alpine"),
)

BINARY_IMAGES = (
    ("ubuntu-20.04", "ubuntu:20.04"),
    ("rocky-linux-9", "rockylinux:9"),
    ("fedora-42", "fedora:42"),
    ("alpine-3.22", "alpine:3.22"),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Exercise generated npm and PyPI cmux packages in Linux containers."
    )
    parser.add_argument("--npm-packages", required=True, type=pathlib.Path)
    parser.add_argument("--pypi-wheels", required=True, type=pathlib.Path)
    parser.add_argument("--version", required=True)
    return parser.parse_args()


def run(label: str, command: list[str]) -> None:
    print(f"\n=== {label} ===", flush=True)
    subprocess.run(command, check=True)


def container_command(
    image: str,
    *,
    mounts: tuple[tuple[pathlib.Path, str], ...],
    script: str,
    entrypoint: str | None = None,
) -> list[str]:
    command = [
        "docker",
        "run",
        "--rm",
        "--platform",
        "linux/amd64",
        "--network",
        "none",
    ]
    if entrypoint is not None:
        command.extend(("--entrypoint", entrypoint))
    for source, destination in mounts:
        command.extend(("--volume", f"{source.resolve()}:{destination}:ro"))
    command.extend((image, "sh", "-c", script))
    return command


def launcher_smoke(command: str) -> str:
    return f"""
set -eu
export HOME=/tmp/cmux-home
mkdir -p "$HOME"
socket="/tmp/cmux-package-smoke-$$.sock"
server_pid=""
cleanup() {{
  if [ -n "$server_pid" ]; then
    kill -TERM "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -f "$socket"
}}
trap cleanup EXIT HUP INT TERM
{command} --version
{command} --headless --socket "$socket" >/tmp/cmux-server.log 2>&1 &
server_pid=$!
attempt=0
while [ ! -S "$socket" ]; do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    cat /tmp/cmux-server.log >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 100 ]; then
    cat /tmp/cmux-server.log >&2
    echo "timed out waiting for $socket" >&2
    exit 1
  fi
  sleep 0.05
done
{command} --socket "$socket" ping
kill -TERM "$server_pid"
wait "$server_pid" || true
server_pid=""
"""


def test_npm(packages: pathlib.Path) -> None:
    launcher = packages / "cmux"
    platform = packages / "cmux-tui-linux-x64"
    for path in (launcher, platform):
        if not path.is_dir():
            raise SystemExit(f"missing npm package directory: {path}")

    with tempfile.TemporaryDirectory(prefix="cmux-npm-smoke-") as temp:
        root = pathlib.Path(temp)
        node_modules = root / "node_modules"
        node_modules.mkdir()
        shutil.copytree(launcher, node_modules / launcher.name)
        shutil.copytree(platform, node_modules / platform.name)
        bin_dir = node_modules / ".bin"
        bin_dir.mkdir()
        (bin_dir / "cmux").symlink_to("../cmux/bin/cmux.js")
        script = "cd /test\n" + launcher_smoke("npx --offline --no-install cmux")
        for distro, image in NPM_IMAGES:
            run(
                f"npx on {distro}",
                container_command(
                    image,
                    mounts=((root, "/test"),),
                    script=script,
                ),
            )


def test_uvx(wheels: pathlib.Path, version: str) -> None:
    if not any(wheels.glob("*.whl")):
        raise SystemExit(f"missing PyPI wheels: {wheels}")
    command = f"uvx --offline --find-links /wheels 'cmux=={version}'"
    script = "export UV_CACHE_DIR=/tmp/uv-cache\n" + launcher_smoke(command)
    for distro, image in UVX_IMAGES:
        run(
            f"uvx on {distro}",
            container_command(
                image,
                entrypoint="",
                mounts=((wheels, "/wheels"),),
                script=script,
            ),
        )


def test_native_binary(packages: pathlib.Path) -> None:
    binary = packages / "cmux-tui-linux-x64" / "bin" / "cmux-tui"
    if not binary.is_file():
        raise SystemExit(f"missing Linux binary: {binary}")
    for distro, image in BINARY_IMAGES:
        run(
            f"native binary on {distro}",
            container_command(
                image,
                mounts=((binary, "/cmux-tui"),),
                script="/cmux-tui --version",
            ),
        )


def main() -> None:
    args = parse_args()
    if shutil.which("docker") is None:
        raise SystemExit("docker is required")
    test_npm(args.npm_packages.resolve())
    test_uvx(args.pypi_wheels.resolve(), args.version)
    test_native_binary(args.npm_packages.resolve())


if __name__ == "__main__":
    main()
