#!/usr/bin/env python3
"""Validate and smoke-test cmux-tui npm and PyPI release artifacts."""

from __future__ import annotations

import argparse
import os
import subprocess
import tempfile
from pathlib import Path

from package_contract import (
    NPM_PLATFORM_NAMES,
    PackageContractError,
    validate_npm_tree,
    validate_pypi_wheels,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--npm-packages", type=Path)
    parser.add_argument("--pypi-wheels", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument(
        "--install-npm-package",
        choices=NPM_PLATFORM_NAMES,
        help="Pack all npm packages and install the launcher with this target.",
    )
    parser.add_argument("--npm", default="npm", help="npm executable")
    args = parser.parse_args()
    if args.npm_packages is None and args.pypi_wheels is None:
        parser.error("at least one of --npm-packages or --pypi-wheels is required")
    if args.install_npm_package is not None and args.npm_packages is None:
        parser.error("--install-npm-package requires --npm-packages")
    return args


def _run(command: list[str], *, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )
    if result.returncode != 0:
        details = result.stderr.strip() or result.stdout.strip()
        raise PackageContractError(
            f"command failed ({result.returncode}): {' '.join(command)}\n{details}"
        )
    return result


def _pack_npm_packages(
    packages_dir: Path,
    version: str,
    npm: str,
    install_package: str | None,
) -> None:
    validate_npm_tree(packages_dir, version)
    with tempfile.TemporaryDirectory(prefix="cmux-tui-npm-contract-") as temp:
        temp_root = Path(temp)
        packed_dir = temp_root / "packed"
        packed_dir.mkdir()
        env = os.environ.copy()
        env.update(
            {
                "npm_config_audit": "false",
                "npm_config_fund": "false",
                "npm_config_update_notifier": "false",
            }
        )
        archives: dict[str, Path] = {}
        for package_name in ("cmux", *NPM_PLATFORM_NAMES):
            before = set(packed_dir.glob("*.tgz"))
            _run(
                [
                    npm,
                    "pack",
                    str(packages_dir / package_name),
                    "--ignore-scripts",
                    "--json",
                    "--pack-destination",
                    str(packed_dir),
                ],
                env=env,
            )
            after = set(packed_dir.glob("*.tgz"))
            new_archives = after - before
            if len(new_archives) != 1:
                raise PackageContractError(
                    f"npm pack for {package_name} produced {len(new_archives)} archives"
                )
            archive = next(iter(new_archives))
            archives[package_name] = archive
            _validate_npm_archive(archive, package_name)

        if install_package is None:
            return

        install_dir = temp_root / "install"
        cache_dir = temp_root / "npm-cache"
        env["npm_config_cache"] = str(cache_dir)
        _run(
            [
                npm,
                "install",
                "--offline",
                "--include=optional",
                "--ignore-scripts",
                "--no-audit",
                "--no-fund",
                "--no-package-lock",
                "--prefix",
                str(install_dir),
                str(archives["cmux"]),
                str(archives[install_package]),
            ],
            env=env,
        )
        launcher = install_dir / "node_modules" / ".bin" / "cmux"
        if not launcher.is_file():
            raise PackageContractError(f"npm install did not create launcher: {launcher}")
        _run([str(launcher), "--version"], env=env)


def _validate_npm_archive(archive: Path, package_name: str) -> None:
    import tarfile

    from package_contract import (
        NPM_LAUNCHER_FILES,
        NPM_PLATFORM_FILES,
    )

    expected = NPM_LAUNCHER_FILES if package_name == "cmux" else NPM_PLATFORM_FILES
    expected_names = {f"package/{path}" for path in expected}
    try:
        tar = tarfile.open(archive, "r:gz")
    except (OSError, tarfile.TarError) as error:
        raise PackageContractError(f"invalid npm archive {archive}: {error}") from error
    with tar:
        members = tar.getmembers()
        names = {member.name for member in members if member.isfile()}
        if names != expected_names:
            raise PackageContractError(
                f"{package_name}: packed file set mismatch: "
                f"expected {sorted(expected_names)}, found {sorted(names)}"
            )
        if len(members) != len(names):
            raise PackageContractError(f"{package_name}: npm archive has non-file members")
        for member in members:
            is_executable = member.name.endswith("/bin/cmux.js") or member.name.endswith(
                "/bin/cmux-tui"
            ) or member.name.endswith("/bin/cmux-tui-hook")
            expected_mode = 0o755 if is_executable else 0o644
            if member.mode != expected_mode:
                raise PackageContractError(
                    f"{package_name}: packed mode {member.mode:o} != "
                    f"{expected_mode:o}: {member.name}"
                )


def main() -> None:
    args = parse_args()
    try:
        if args.npm_packages is not None:
            _pack_npm_packages(
                args.npm_packages.resolve(),
                args.version,
                args.npm,
                args.install_npm_package,
            )
        if args.pypi_wheels is not None:
            validate_pypi_wheels(args.pypi_wheels.resolve(), args.version)
    except PackageContractError as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
