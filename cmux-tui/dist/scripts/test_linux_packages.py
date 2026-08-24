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

ARCHITECTURES = {
    "x64": ("linux/amd64", "cmux-tui-linux-x64"),
    "arm64": ("linux/arm64", "cmux-tui-linux-arm64"),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Exercise generated npm and PyPI cmux packages in Linux containers."
    )
    parser.add_argument("--npm-packages", type=pathlib.Path)
    parser.add_argument("--pypi-wheels", type=pathlib.Path)
    parser.add_argument("--version", required=True)
    parser.add_argument(
        "--architecture",
        choices=ARCHITECTURES,
        default="x64",
        help="Linux package architecture to exercise (default: x64).",
    )
    args = parser.parse_args()
    if args.npm_packages is None and args.pypi_wheels is None:
        parser.error("at least one of --npm-packages or --pypi-wheels is required")
    return args


def run(label: str, command: list[str]) -> None:
    print(f"\n=== {label} ===", flush=True)
    subprocess.run(command, check=True)


def container_command(
    image: str,
    *,
    platform: str,
    mounts: tuple[tuple[pathlib.Path, str], ...],
    script: str,
    entrypoint: str | None = None,
) -> list[str]:
    command = [
        "docker",
        "run",
        "--rm",
        "--platform",
        platform,
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
  if [ "$attempt" -ge 600 ]; then
    cat /tmp/cmux-server.log >&2
    echo "timed out waiting for $socket" >&2
    exit 1
  fi
  sleep 0.05
done
{command} --socket "$socket" session main ping
kill -TERM "$server_pid"
wait "$server_pid" || true
server_pid=""
"""


def test_npm(packages: pathlib.Path, platform: str, package_name: str) -> None:
    launcher = packages / "cmux"
    platform_package = packages / package_name
    for path in (launcher, platform_package):
        if not path.is_dir():
            raise SystemExit(f"missing npm package directory: {path}")

    with tempfile.TemporaryDirectory(prefix="cmux-npm-smoke-") as temp:
        root = pathlib.Path(temp)
        node_modules = root / "node_modules"
        node_modules.mkdir()
        shutil.copytree(launcher, node_modules / launcher.name)
        shutil.copytree(platform_package, node_modules / platform_package.name)
        bin_dir = node_modules / ".bin"
        bin_dir.mkdir()
        (bin_dir / "cmux").symlink_to("../cmux/bin/cmux.js")
        script = "cd /test\n" + launcher_smoke("npx --offline --no-install cmux")
        for distro, image in NPM_IMAGES:
            run(
                f"npx on {distro}",
                container_command(
                    image,
                    platform=platform,
                    mounts=((root, "/test"),),
                    script=script,
                ),
            )


def test_uvx(wheels: pathlib.Path, version: str, platform: str) -> None:
    if not any(wheels.glob("*.whl")):
        raise SystemExit(f"missing PyPI wheels: {wheels}")
    command = f"uvx --offline --find-links /wheels 'cmux=={version}'"
    script = "export UV_CACHE_DIR=/tmp/uv-cache\n" + launcher_smoke(command)
    for distro, image in UVX_IMAGES:
        run(
            f"uvx on {distro}",
            container_command(
                image,
                platform=platform,
                entrypoint="",
                mounts=((wheels, "/wheels"),),
                script=script,
            ),
        )


def test_native_binary(
    packages: pathlib.Path, platform: str, package_name: str
) -> None:
    binary = packages / package_name / "bin" / "cmux-tui"
    if not binary.is_file():
        raise SystemExit(f"missing Linux binary: {binary}")
    for distro, image in BINARY_IMAGES:
        run(
            f"native binary on {distro}",
            container_command(
                image,
                platform=platform,
                mounts=((binary, "/cmux-tui"),),
                script="/cmux-tui --version",
            ),
        )


def main() -> None:
    args = parse_args()
    if shutil.which("docker") is None:
        raise SystemExit("docker is required")
    platform, package_name = ARCHITECTURES[args.architecture]
    if args.npm_packages is not None:
        npm_packages = args.npm_packages.resolve()
        test_npm(npm_packages, platform, package_name)
        test_native_binary(npm_packages, platform, package_name)
    if args.pypi_wheels is not None:
        test_uvx(args.pypi_wheels.resolve(), args.version, platform)


if __name__ == "__main__":
    main()
