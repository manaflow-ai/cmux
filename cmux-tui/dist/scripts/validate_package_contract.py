#!/usr/bin/env python3
"""Validate and smoke-test cmux-tui npm and PyPI release artifacts."""

from __future__ import annotations

import argparse
import os
import subprocess
import tempfile
import tomllib
from pathlib import Path

from package_contract import (
    NPM_PLATFORM_NAMES_WITH_WINDOWS,
    NPM_RELAY_PLATFORM_NAMES_WITH_WINDOWS,
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
        choices=NPM_PLATFORM_NAMES_WITH_WINDOWS,
        help="Pack all npm packages and install the launcher with this target.",
    )
    parser.add_argument(
        "--install-npm-relay-package",
        choices=NPM_RELAY_PLATFORM_NAMES_WITH_WINDOWS,
        help=(
            "Pack all npm packages and install the cmux-relay launcher with "
            "this target."
        ),
    )
    parser.add_argument(
        "--include-windows",
        action="store_true",
        help="Validate the optional Windows TUI and relay packages.",
    )
    parser.add_argument("--npm", default="npm", help="npm executable")
    args = parser.parse_args()
    if args.npm_packages is None and args.pypi_wheels is None:
        parser.error("at least one of --npm-packages or --pypi-wheels is required")
    if (
        args.install_npm_package is not None or args.install_npm_relay_package is not None
    ) and args.npm_packages is None:
        parser.error("package installation smoke options require --npm-packages")
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
    install_relay_package: str | None,
    include_windows: bool,
) -> None:
    validate_npm_tree(packages_dir, version, include_windows=include_windows)
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
        from package_contract import NPM_PACKAGE_NAMES, NPM_PACKAGE_NAMES_WITH_WINDOWS

        package_names = (
            NPM_PACKAGE_NAMES_WITH_WINDOWS if include_windows else NPM_PACKAGE_NAMES
        )
        for package_name in package_names:
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

        if install_package is None and install_relay_package is None:
            return

        # Keep the install path npx-like so the launcher guard is exercised as
        # part of the same artifact smoke without touching a user's install.
        install_dir = temp_root / "_npx" / "install"
        cache_dir = temp_root / "npm-cache"
        env["npm_config_cache"] = str(cache_dir)
        install_archives = []
        if install_package is not None:
            install_archives.extend((archives["cmux"], archives[install_package]))
        if install_relay_package is not None:
            install_archives.extend(
                (archives["cmux-relay"], archives[install_relay_package])
            )
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
                *(str(archive) for archive in install_archives),
            ],
            env=env,
        )
        if install_package is not None:
            launcher = install_dir / "node_modules" / ".bin" / "cmux"
            if not launcher.is_file():
                raise PackageContractError(f"npm install did not create launcher: {launcher}")
            _run([str(launcher), "--version"], env=env)
        if install_relay_package is not None:
            _smoke_relay_launcher(
                install_dir,
                env,
                temp_root,
            )


def _smoke_relay_launcher(
    install_dir: Path,
    env: dict[str, str],
    temp_root: Path,
) -> None:
    """Run the installed Rust relay through the npm launcher.

    Keep this smoke offline and deterministic. Informational commands must not
    construct a network client or start onboarding, even when the environment
    contains an unusable backend URL. The config paths are isolated so this
    check cannot read or write a developer's real pairing.
    """

    launcher = install_dir / "node_modules" / ".bin" / "cmux-relay"
    if not launcher.is_file():
        raise PackageContractError(f"npm install did not create relay launcher: {launcher}")

    smoke_home = temp_root / "relay-home"
    smoke_config_home = temp_root / "relay-config-home"
    smoke_config_home.mkdir()
    relay_env = env.copy()
    relay_env.update(
        {
            "HOME": str(smoke_home),
            "USERPROFILE": str(smoke_home),
            "APPDATA": str(smoke_config_home),
            "XDG_CONFIG_HOME": str(smoke_config_home),
            # If --status accidentally falls through into startup, this value
            # must fail before any real network request can be made.
            "CHATMUX_BACKEND_URL": "not-a-url",
        }
    )
    smoke_home.mkdir()

    relay_version = _relay_binary_version()
    version_result = _run([str(launcher), "--version"], env=relay_env)
    if version_result.stdout.strip() != relay_version:
        raise PackageContractError(
            "cmux-relay --version output mismatch: "
            f"expected {relay_version!r}, found {version_result.stdout.strip()!r}"
        )

    autostart_result = subprocess.run(
        [str(launcher), "--autostart"],
        check=False,
        capture_output=True,
        text=True,
        env=relay_env,
    )
    if (
        autostart_result.returncode != 2
        or "Install cmux-relay globally" not in autostart_result.stderr
    ):
        raise PackageContractError(
            "cmux-relay npx autostart guard returned "
            f"{autostart_result.returncode} / {autostart_result.stderr!r}"
        )

    status_result = subprocess.run(
        [str(launcher), "--status"],
        check=False,
        capture_output=True,
        text=True,
        env=relay_env,
    )
    if (
        status_result.returncode != 1
        or status_result.stdout != "Not paired\n"
        or status_result.stderr
    ):
        raise PackageContractError(
            "cmux-relay --status without config returned "
            f"{status_result.returncode} / {status_result.stdout!r} / "
            f"{status_result.stderr!r}"
        )

    malformed = smoke_config_home / "chatmux-relay" / "malformed.json"
    malformed.parent.mkdir()
    malformed.write_text("{not-json", encoding="utf-8")
    malformed_result = subprocess.run(
        [str(launcher), "--status", "--config", str(malformed)],
        check=False,
        capture_output=True,
        text=True,
        env=relay_env,
    )
    if (
        malformed_result.returncode != 1
        or malformed_result.stdout != "Not paired\n"
        or malformed_result.stderr
    ):
        raise PackageContractError(
            "cmux-relay --status with malformed config returned "
            f"{malformed_result.returncode} / {malformed_result.stdout!r} / "
            f"{malformed_result.stderr!r}"
        )

    paired = smoke_config_home / "chatmux-relay" / "paired.json"
    paired.write_text(
        '{"name":"smoke-machine","deviceId":"device-smoke","token":"token-smoke"}\n',
        encoding="utf-8",
    )
    paired_result = _run(
        [str(launcher), "--status", "--config", str(paired)],
        env=relay_env,
    )
    if not paired_result.stdout.startswith("Paired as smoke-machine (device-smoke)\n"):
        raise PackageContractError(
            "cmux-relay --status with a valid isolated config returned "
            f"unexpected output: {paired_result.stdout!r}"
        )


def _relay_binary_version() -> str:
    """Read the Rust relay's CLI version, which is separate from npm's version."""

    manifest = Path(__file__).resolve().parents[2] / "crates" / "chatmux-relay" / "Cargo.toml"
    try:
        package = tomllib.loads(manifest.read_text(encoding="utf-8"))["package"]
        relay_version = package["version"]
    except (KeyError, OSError, TypeError, tomllib.TOMLDecodeError) as error:
        raise PackageContractError(f"could not read chatmux-relay version: {error}") from error
    if not isinstance(relay_version, str) or not relay_version:
        raise PackageContractError(
            f"chatmux-relay Cargo.toml has invalid version: {relay_version!r}"
        )
    return relay_version


def _validate_npm_archive(archive: Path, package_name: str) -> None:
    import tarfile

    from package_contract import (
        NPM_LAUNCHER_FILES,
        NPM_RELAY_LAUNCHER_FILES,
    )

    if package_name == "cmux":
        expected = NPM_LAUNCHER_FILES
    elif package_name == "cmux-relay":
        expected = NPM_RELAY_LAUNCHER_FILES
    elif package_name.startswith("cmux-relay-"):
        extension = ".exe" if "win32" in package_name else ""
        expected = frozenset(
            {
                "package.json",
                f"bin/chatmux-relay{extension}",
                f"bin/cmux-tui{extension}",
            }
        )
    else:
        extension = ".exe" if "win32" in package_name else ""
        expected = frozenset(
            {
                "package.json",
                f"bin/cmux-tui{extension}",
                f"bin/cmux-tui-hook{extension}",
            }
        )
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
            is_executable = (
                member.name.endswith("/bin/cmux.js")
                or member.name.endswith("/bin/cmux-relay.js")
                or member.name.endswith("/bin/cmux-tui")
                or member.name.endswith("/bin/cmux-tui-hook")
                or member.name.endswith("/bin/cmux-tui.exe")
                or member.name.endswith("/bin/cmux-tui-hook.exe")
                or member.name.endswith("/bin/chatmux-relay")
                or member.name.endswith("/bin/chatmux-relay.exe")
                or member.name.endswith("/bin/cmux-tui")
                or member.name.endswith("/bin/cmux-tui.exe")
            )
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
                args.install_npm_relay_package,
                args.include_windows,
            )
        if args.pypi_wheels is not None:
            validate_pypi_wheels(args.pypi_wheels.resolve(), args.version)
    except PackageContractError as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
