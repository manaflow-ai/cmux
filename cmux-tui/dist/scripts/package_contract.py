#!/usr/bin/env python3
"""Validate the files and metadata shipped by cmux-tui registries."""

from __future__ import annotations

import base64
import csv
import hashlib
import io
import json
import zipfile
from dataclasses import dataclass
from pathlib import Path


class PackageContractError(ValueError):
    """Raised when a generated package does not match the release contract."""


@dataclass(frozen=True)
class NpmTarget:
    name: str
    os: str
    cpu: str


NPM_TARGETS = (
    NpmTarget("cmux-tui-darwin-arm64", "darwin", "arm64"),
    NpmTarget("cmux-tui-darwin-x64", "darwin", "x64"),
    NpmTarget("cmux-tui-linux-x64", "linux", "x64"),
    NpmTarget("cmux-tui-linux-arm64", "linux", "arm64"),
)
NPM_PLATFORM_NAMES = tuple(target.name for target in NPM_TARGETS)
NPM_PACKAGE_NAMES = ("cmux", *NPM_PLATFORM_NAMES)
NPM_PLATFORM_FILES = frozenset(
    {"package.json", "bin/cmux-tui", "bin/cmux-tui-hook"}
)
NPM_LAUNCHER_FILES = frozenset({"package.json", "bin/cmux.js"})
NPM_EXECUTABLE_FILES = tuple(
    f"{target.name}/bin/{binary}"
    for target in NPM_TARGETS
    for binary in ("cmux-tui", "cmux-tui-hook")
) + ("cmux/bin/cmux.js",)

PYPI_WHEEL_TAGS = (
    "macosx_11_0_arm64",
    "macosx_10_12_x86_64",
    "manylinux_2_17_x86_64.manylinux2014_x86_64",
    "musllinux_1_2_x86_64",
    "manylinux_2_17_aarch64.manylinux2014_aarch64",
    "musllinux_1_2_aarch64",
)
PYPI_WHEEL_FILES = frozenset(
    {
        "cmux_tui/__init__.py",
        "cmux_tui/_main.py",
        "cmux_tui/bin/cmux-tui",
        "cmux_tui/bin/cmux-tui-hook",
        "{dist_info}/WHEEL",
        "{dist_info}/METADATA",
        "{dist_info}/entry_points.txt",
        "{dist_info}/RECORD",
    }
)


def _error(message: str) -> PackageContractError:
    return PackageContractError(message)


def _files_below(root: Path) -> set[str]:
    files: set[str] = set()
    for path in root.rglob("*"):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            raise _error(f"{root}: symlink is not allowed: {relative}")
        if path.is_file():
            files.add(relative)
        elif not path.is_dir():
            raise _error(f"{root}: unsupported entry: {relative}")
    return files


def _entries_below(root: Path) -> set[str]:
    entries: set[str] = set()
    for path in root.rglob("*"):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            raise _error(f"{root}: symlink is not allowed: {relative}")
        if not (path.is_file() or path.is_dir()):
            raise _error(f"{root}: unsupported entry: {relative}")
        entries.add(relative)
    return entries


def _require_executable(path: Path, label: str) -> None:
    mode = path.stat().st_mode
    if mode & 0o111 != 0o111:
        raise _error(f"{label} is not executable: {path}")


def _read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise _error(f"invalid JSON: {path}: {error}") from error
    if not isinstance(value, dict):
        raise _error(f"package metadata must be an object: {path}")
    return value


def _validate_version(actual: object, expected: str | None, label: str) -> str:
    if not isinstance(actual, str) or not actual:
        raise _error(f"{label}: version is missing")
    if expected is not None and actual != expected:
        raise _error(f"{label}: version {actual!r} != {expected!r}")
    return actual


def validate_npm_tree(packages_dir: Path, version: str | None = None) -> str:
    """Validate the generated npm package directory tree.

    Returns the package version. If ``version`` is omitted, the launcher version
    is used and every package must match it.
    """

    packages_dir = packages_dir.resolve()
    if not packages_dir.is_dir():
        raise _error(f"missing npm package directory: {packages_dir}")

    root_paths = tuple(packages_dir.iterdir())
    for path in root_paths:
        if path.is_symlink():
            raise _error(f"npm package root contains symlink: {path.name}")
    actual_root_entries = tuple(sorted(path.name for path in root_paths))
    expected_packages = tuple(sorted(NPM_PACKAGE_NAMES))
    if actual_root_entries != expected_packages:
        raise _error(
            f"npm package set mismatch: expected {expected_packages}, "
            f"found {actual_root_entries}"
        )

    launcher_dir = packages_dir / "cmux"
    launcher_metadata = _read_json(launcher_dir / "package.json")
    if launcher_metadata.get("name") != "cmux":
        raise _error("cmux: package name is incorrect")
    package_version = _validate_version(
        launcher_metadata.get("version"), version, "cmux"
    )

    launcher_files = _files_below(launcher_dir)
    launcher_entries = _entries_below(launcher_dir)
    expected_launcher_entries = NPM_LAUNCHER_FILES | {"bin"}
    if launcher_entries != expected_launcher_entries:
        raise _error(
            f"cmux: directory tree mismatch: expected "
            f"{sorted(expected_launcher_entries)}, "
            f"found {sorted(launcher_entries)}"
        )
    if launcher_files != NPM_LAUNCHER_FILES:
        raise _error(
            f"cmux: package files mismatch: expected "
            f"{sorted(NPM_LAUNCHER_FILES)}, found {sorted(launcher_files)}"
        )
    if launcher_metadata.get("files") != ["bin/cmux.js"]:
        raise _error("cmux: files must contain only bin/cmux.js")
    if launcher_metadata.get("bin") != {"cmux": "bin/cmux.js"}:
        raise _error("cmux: bin mapping is incorrect")
    expected_dependencies = {
        target.name: package_version for target in NPM_TARGETS
    }
    if launcher_metadata.get("optionalDependencies") != expected_dependencies:
        raise _error(
            "cmux: optionalDependencies mismatch: "
            f"expected {expected_dependencies}, "
            f"found {launcher_metadata.get('optionalDependencies')}"
        )
    _require_executable(launcher_dir / "bin/cmux.js", "cmux launcher")

    for target in NPM_TARGETS:
        package_dir = packages_dir / target.name
        metadata = _read_json(package_dir / "package.json")
        label = target.name
        if metadata.get("name") != target.name:
            raise _error(f"{label}: package name is incorrect")
        _validate_version(metadata.get("version"), package_version, label)
        if metadata.get("os") != [target.os] or metadata.get("cpu") != [target.cpu]:
            raise _error(f"{label}: os/cpu selectors are incorrect")
        if metadata.get("files") != ["bin/cmux-tui", "bin/cmux-tui-hook"]:
            raise _error(f"{label}: files must contain the binary and hook only")
        files = _files_below(package_dir)
        entries = _entries_below(package_dir)
        expected_entries = NPM_PLATFORM_FILES | {"bin"}
        if entries != expected_entries:
            raise _error(
                f"{label}: directory tree mismatch: expected "
                f"{sorted(expected_entries)}, found {sorted(entries)}"
            )
        if files != NPM_PLATFORM_FILES:
            missing = sorted(NPM_PLATFORM_FILES - files)
            extra = sorted(files - NPM_PLATFORM_FILES)
            raise _error(
                f"{label}: package files mismatch; missing={missing}, "
                f"unexpected={extra}"
            )
        _require_executable(package_dir / "bin/cmux-tui", f"{label} binary")
        _require_executable(package_dir / "bin/cmux-tui-hook", f"{label} hook")

    return package_version


def _wheel_expected_files(version: str) -> set[str]:
    dist_info = f"cmux-{version}.dist-info"
    return {path.format(dist_info=dist_info) for path in PYPI_WHEEL_FILES}


def _record_digest(data: bytes) -> str:
    digest = hashlib.sha256(data).digest()
    return "sha256=" + base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


def _metadata_value(data: bytes, key: str) -> str | None:
    prefix = f"{key}:".encode("utf-8")
    for line in data.splitlines():
        if line.startswith(prefix):
            return line[len(prefix) :].strip().decode("utf-8")
    return None


def _wheel_mode(info: zipfile.ZipInfo) -> int:
    return (info.external_attr >> 16) & 0o777


def validate_wheel(path: Path, version: str) -> None:
    expected_prefix = f"cmux-{version}-py3-none-"
    if not path.name.startswith(expected_prefix) or not path.name.endswith(".whl"):
        raise _error(f"unexpected wheel filename: {path.name}")
    tag = path.name[len(expected_prefix) : -len(".whl")]
    if tag not in PYPI_WHEEL_TAGS:
        raise _error(f"unsupported wheel platform tag: {path.name}")
    dist_info = f"cmux-{version}.dist-info"
    expected_files = _wheel_expected_files(version)

    try:
        wheel = zipfile.ZipFile(path)
    except (OSError, zipfile.BadZipFile) as error:
        raise _error(f"invalid wheel {path}: {error}") from error
    with wheel:
        infos = wheel.infolist()
        names = [info.filename for info in infos]
        if len(names) != len(set(names)):
            raise _error(f"{path.name}: duplicate ZIP member")
        if set(names) != expected_files:
            raise _error(
                f"{path.name}: file set mismatch; expected "
                f"{sorted(expected_files)}, found {sorted(names)}"
            )

        wheel_info = wheel.getinfo(f"{dist_info}/WHEEL")
        wheel_data = wheel.read(wheel_info)
        if _metadata_value(wheel_data, "Tag") != f"py3-none-{tag}":
            raise _error(f"{path.name}: WHEEL Tag does not match filename")
        metadata = wheel.read(f"{dist_info}/METADATA")
        if _metadata_value(metadata, "Name") != "cmux":
            raise _error(f"{path.name}: METADATA Name is not cmux")
        if _metadata_value(metadata, "Version") != version:
            raise _error(f"{path.name}: METADATA Version does not match filename")

        executable_names = {
            "cmux_tui/bin/cmux-tui",
            "cmux_tui/bin/cmux-tui-hook",
        }
        for name in names:
            mode = _wheel_mode(wheel.getinfo(name))
            expected_mode = 0o755 if name in executable_names else 0o644
            if mode != expected_mode:
                raise _error(
                    f"{path.name}: {name} mode {mode:o} != {expected_mode:o}"
                )

        record_name = f"{dist_info}/RECORD"
        record_data = wheel.read(record_name)
        rows = list(csv.reader(io.StringIO(record_data.decode("utf-8"))))
        expected_rows = set(expected_files)
        seen_rows: set[str] = set()
        for row in rows:
            if len(row) != 3:
                raise _error(f"{path.name}: malformed RECORD row")
            name, digest, size = row
            if name not in expected_rows:
                raise _error(f"{path.name}: RECORD names unknown file {name}")
            if name in seen_rows:
                raise _error(f"{path.name}: RECORD contains duplicate {name}")
            seen_rows.add(name)
            if name == record_name:
                if digest or size:
                    raise _error(f"{path.name}: RECORD self-entry must be empty")
                continue
            data = wheel.read(name)
            if digest != _record_digest(data) or size != str(len(data)):
                raise _error(f"{path.name}: RECORD integrity mismatch for {name}")
        if seen_rows != expected_rows:
            raise _error(f"{path.name}: RECORD does not cover every wheel file")


def validate_pypi_wheels(wheels_dir: Path, version: str) -> tuple[str, ...]:
    """Validate the exact six wheels emitted for one cmux TUI version."""

    wheels_dir = wheels_dir.resolve()
    if not wheels_dir.is_dir():
        raise _error(f"missing PyPI wheel directory: {wheels_dir}")
    expected = tuple(
        sorted(f"cmux-{version}-py3-none-{tag}.whl" for tag in PYPI_WHEEL_TAGS)
    )
    actual = tuple(sorted(path.name for path in wheels_dir.iterdir()))
    if actual != expected:
        raise _error(f"PyPI wheel set mismatch: expected {expected}, found {actual}")
    for name in actual:
        validate_wheel(wheels_dir / name, version)
    return actual
