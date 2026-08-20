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

MANYLINUX_IMAGES = {
    "x64": (
        "manylinux2014-x64",
        "quay.io/pypa/manylinux2014_x86_64@sha256:"
        "95440e0e72dd3a81dc8d2cf59a84d57af661456620f5bc821ff92048d0e54ff9",
    ),
    "arm64": (
        "manylinux2014-arm64",
        "quay.io/pypa/manylinux2014_aarch64@sha256:"
        "b63ff749fee6f3f2a6b67ed3101a073db3211df1791da19e9acf96f43c0dd6ff",
    ),
}

MANYLINUX_WHEEL_TAGS = {
    "x64": "manylinux_2_17_x86_64.manylinux2014_x86_64",
    "arm64": "manylinux_2_17_aarch64.manylinux2014_aarch64",
}

MANYLINUX_GLIBC_FLOOR_CHECK = """
glibc_version="$(getconf GNU_LIBC_VERSION | awk '{print $2}')"
if [ "$glibc_version" != "2.17" ]; then
  echo "expected manylinux2014 glibc 2.17, got $glibc_version" >&2
  exit 1
fi
""".strip()

ARCHITECTURES = {
    "x64": ("linux/amd64", "cmux-tui-linux-x64"),
    "arm64": ("linux/arm64", "cmux-tui-linux-arm64"),
}


def manylinux_image(architecture: str) -> tuple[str, str]:
    try:
        return MANYLINUX_IMAGES[architecture]
    except KeyError as error:
        raise SystemExit(f"unsupported Linux architecture: {architecture}") from error


def manylinux_wheel_tag(architecture: str) -> str:
    try:
        return MANYLINUX_WHEEL_TAGS[architecture]
    except KeyError as error:
        raise SystemExit(f"unsupported Linux architecture: {architecture}") from error


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
    packages: pathlib.Path,
    platform: str,
    package_name: str,
    architecture: str,
) -> None:
    binary = packages / package_name / "bin" / "cmux-tui"
    if not binary.is_file():
        raise SystemExit(f"missing Linux binary: {binary}")
    images = (*BINARY_IMAGES, manylinux_image(architecture))
    for distro, image in images:
        is_manylinux = image.startswith("quay.io/pypa/manylinux2014_")
        script = "/cmux-tui --version"
        if is_manylinux:
            script = f"{MANYLINUX_GLIBC_FLOOR_CHECK}\n{script}"
        run(
            f"native binary on {distro}",
            container_command(
                image,
                platform=platform,
                mounts=((binary, "/cmux-tui"),),
                script=script,
                entrypoint="" if is_manylinux else None,
            ),
        )


def test_pypi_manylinux_binary(
    wheels: pathlib.Path, version: str, platform: str, architecture: str
) -> None:
    wheel_name = f"cmux-{version}-py3-none-{manylinux_wheel_tag(architecture)}.whl"
    wheel = wheels / wheel_name
    if not wheel.is_file():
        raise SystemExit(f"missing manylinux wheel: {wheel}")
    script = f"""
set -eu
{MANYLINUX_GLIBC_FLOOR_CHECK}
unzip -p "/wheels/{wheel_name}" cmux_tui/bin/cmux-tui > /tmp/cmux-tui
test -s /tmp/cmux-tui
chmod 0755 /tmp/cmux-tui
/tmp/cmux-tui --version
"""
    distro, image = manylinux_image(architecture)
    run(
        f"PyPI binary on {distro}",
        container_command(
            image,
            platform=platform,
            entrypoint="",
            mounts=((wheels, "/wheels"),),
            script=script,
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
        test_native_binary(npm_packages, platform, package_name, args.architecture)
    if args.pypi_wheels is not None:
        pypi_wheels = args.pypi_wheels.resolve()
        test_uvx(pypi_wheels, args.version, platform)
        test_pypi_manylinux_binary(
            pypi_wheels, args.version, platform, args.architecture
        )


if __name__ == "__main__":
    main()
