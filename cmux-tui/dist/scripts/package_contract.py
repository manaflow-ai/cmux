#!/usr/bin/env python3
"""Validate the files and metadata shipped by cmux-tui registries."""

from __future__ import annotations

import base64
import csv
import hashlib
import io
import json
import re
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
NPM_WINDOWS_TARGET = NpmTarget("cmux-tui-win32-x64", "win32", "x64")
NPM_PLATFORM_NAMES = tuple(target.name for target in NPM_TARGETS)
NPM_PLATFORM_NAMES_WITH_WINDOWS = (*NPM_PLATFORM_NAMES, NPM_WINDOWS_TARGET.name)
NPM_RELAY_PLATFORM_NAMES = tuple(
    target.name.replace("cmux-tui", "cmux-relay") for target in NPM_TARGETS
)
NPM_RELAY_PLATFORM_NAMES_WITH_WINDOWS = (
    *NPM_RELAY_PLATFORM_NAMES,
    NPM_WINDOWS_TARGET.name.replace("cmux-tui", "cmux-relay"),
)
NPM_PACKAGE_NAMES = (
    "cmux",
    "cmux-relay",
    *NPM_PLATFORM_NAMES,
    *NPM_RELAY_PLATFORM_NAMES,
)
NPM_PACKAGE_NAMES_WITH_WINDOWS = (
    "cmux",
    "cmux-relay",
    *NPM_PLATFORM_NAMES_WITH_WINDOWS,
    *NPM_RELAY_PLATFORM_NAMES_WITH_WINDOWS,
)
# Every cmux-tui platform package pins the SHA-256 of each remote binary the
# SSH bootstrap may download from npm. It sits next to bin/cmux-tui, where
# cmux-remote looks for it.
NPM_SSH_MANIFEST = "bin/cmux-tui-ssh/manifest.json"
NPM_SSH_MANIFEST_BINARIES = {
    "cmux-tui-aarch64-unknown-linux-musl": "cmux-tui-linux-arm64",
    "cmux-tui-x86_64-unknown-linux-musl": "cmux-tui-linux-x64",
    "cmux-tui-aarch64-apple-darwin": "cmux-tui-darwin-arm64",
    "cmux-tui-x86_64-apple-darwin": "cmux-tui-darwin-x64",
}
# Every package ships the GPL text; npm packs LICENSE without a "files" entry.
NPM_LICENSE_FILE = "LICENSE"
# Every platform package and wheel ships the third-party notices of its
# binaries (package_notices.py generate: <kind>-<rust target>.md); "files"
# must list it, because npm packs only LICENSE on its own.
NOTICE_FILE = "THIRD_PARTY_LICENSES.md"
NPM_RUST_TARGETS = {
    "darwin-arm64": "aarch64-apple-darwin",
    "darwin-x64": "x86_64-apple-darwin",
    "linux-x64": "x86_64-unknown-linux-musl",
    "linux-arm64": "aarch64-unknown-linux-musl",
    "win32-x64": "x86_64-pc-windows-gnu",
}
PYPI_RUST_TARGETS = {
    "macosx_11_0_arm64": "aarch64-apple-darwin",
    "macosx_10_12_x86_64": "x86_64-apple-darwin",
    "manylinux_2_17_x86_64.manylinux2014_x86_64": "x86_64-unknown-linux-musl",
    "musllinux_1_2_x86_64": "x86_64-unknown-linux-musl",
    "manylinux_2_17_aarch64.manylinux2014_aarch64": "aarch64-unknown-linux-musl",
    "musllinux_1_2_aarch64": "aarch64-unknown-linux-musl",
}
NPM_PLATFORM_FILES = frozenset(
    {"package.json", NPM_LICENSE_FILE, "bin/cmux-tui", "bin/cmux-tui-hook", NPM_SSH_MANIFEST, NOTICE_FILE}
)
NPM_LAUNCHER_FILES = frozenset({"package.json", NPM_LICENSE_FILE, "bin/cmux.js"})
NPM_RELAY_PLATFORM_FILES = frozenset(
    {"package.json", NPM_LICENSE_FILE, "bin/chatmux-relay", "bin/cmux-tui", NOTICE_FILE}
)
NPM_RELAY_LAUNCHER_FILES = frozenset({"package.json", NPM_LICENSE_FILE, "bin/cmux-relay.js"})


def npm_targets(include_windows: bool) -> tuple[NpmTarget, ...]:
    return (*NPM_TARGETS, NPM_WINDOWS_TARGET) if include_windows else NPM_TARGETS


def _target_binary_paths(target: NpmTarget, names: tuple[str, ...]) -> tuple[str, ...]:
    extension = ".exe" if target.os == "win32" else ""
    return tuple(f"{target.name}/bin/{name}{extension}" for name in names)


def npm_executable_files(include_windows: bool = False) -> tuple[str, ...]:
    targets = npm_targets(include_windows)
    relay_targets = tuple(
        NpmTarget(target.name.replace("cmux-tui", "cmux-relay"), target.os, target.cpu)
        for target in targets
    )
    return (
        tuple(path for target in targets for path in _target_binary_paths(target, ("cmux-tui", "cmux-tui-hook")))
        + tuple(
            path
            for target in relay_targets
            for path in _target_binary_paths(target, ("chatmux-relay", "cmux-tui"))
        )
        + ("cmux/bin/cmux.js", "cmux-relay/bin/cmux-relay.js")
    )


NPM_EXECUTABLE_FILES = npm_executable_files()

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
        "{dist_info}/licenses/LICENSE",
        "{dist_info}/licenses/" + NOTICE_FILE,
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


def _require_relay_autostart_guard(path: Path) -> None:
    """Keep the npm launcher aligned with the native autostart safety rule.

    An npm package can be launched through ``npx`` from a disposable ``_npx``
    cache. The launcher must refuse ``--autostart`` in that case instead of
    writing a login service that points at a path npm may delete.
    """

    try:
        source = path.read_text(encoding="utf-8")
    except OSError as error:
        raise _error(f"cmux-relay launcher cannot be read: {path}: {error}") from error
    required_markers = (
        '"--autostart"',
        '"_npx"',
        "npm install --global cmux-relay",
        "unsupported_platform",
        "requires a Unix PTY backend",
    )
    missing = [marker for marker in required_markers if marker not in source]
    if missing:
        raise _error(
            "cmux-relay launcher is missing the ephemeral-npx autostart guard: "
            + ", ".join(missing)
        )


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


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _validate_ssh_manifests(packages_dir: Path, targets: tuple[NpmTarget, ...]) -> None:
    """Require one identical SSH digest manifest that matches the packages.

    The SSH bootstrap trusts a remote binary downloaded from npm only when it
    matches this manifest, so each digest must be the packaged binary's own.
    """

    manifests = {
        target.name: _read_json(packages_dir / target.name / NPM_SSH_MANIFEST)
        for target in targets
    }
    first = next(iter(manifests.values()))
    for name, manifest in manifests.items():
        if manifest != first:
            raise _error(f"{name}: SSH manifest differs from the other platform packages")
    if set(first) != {"commit", "binaries"}:
        raise _error("SSH manifest must contain only commit and binaries")
    commit = first.get("commit")
    if not isinstance(commit, str) or not re.fullmatch(
        r"[0-9a-f]{40}(?:[0-9a-f]{24})?", commit
    ):
        raise _error("SSH manifest commit must be a full lowercase Git commit ID")
    binaries = first.get("binaries")
    if not isinstance(binaries, dict) or set(binaries) != set(NPM_SSH_MANIFEST_BINARIES):
        raise _error(
            "SSH manifest must pin exactly "
            f"{sorted(NPM_SSH_MANIFEST_BINARIES)}, found {sorted(binaries or {})}"
        )
    for artifact, package in NPM_SSH_MANIFEST_BINARIES.items():
        actual = _sha256_file(packages_dir / package / "bin" / "cmux-tui")
        if binaries[artifact] != actual:
            raise _error(
                f"SSH manifest digest for {artifact} does not match {package}/bin/cmux-tui"
            )


def _validate_package_files(
    package_dir: Path,
    target: NpmTarget,
    *,
    binary_names: tuple[str, ...],
    expected_files: frozenset[str],
    label: str,
    version: str,
    data_files: tuple[str, ...] = (),
) -> None:
    metadata = _read_json(package_dir / "package.json")
    if metadata.get("name") != target.name:
        raise _error(f"{label}: package name is incorrect")
    _validate_version(metadata.get("version"), version, label)
    if metadata.get("os") != [target.os] or metadata.get("cpu") != [target.cpu]:
        raise _error(f"{label}: os/cpu selectors are incorrect")
    extension = ".exe" if target.os == "win32" else ""
    files = [f"bin/{name}{extension}" for name in binary_names] + list(data_files)
    if metadata.get("files") != files:
        raise _error(f"{label}: files must be {files}")
    files_on_disk = _files_below(package_dir)
    entries = _entries_below(package_dir)
    expected_entries = expected_files | {
        str(parent.as_posix())
        for path in expected_files
        for parent in Path(path).parents
        if parent != Path(".")
    }
    if entries != expected_entries:
        raise _error(
            f"{label}: directory tree mismatch: expected "
            f"{sorted(expected_entries)}, found {sorted(entries)}"
        )
    if files_on_disk != expected_files:
        missing = sorted(expected_files - files_on_disk)
        extra = sorted(files_on_disk - expected_files)
        raise _error(
            f"{label}: package files mismatch; missing={missing}, unexpected={extra}"
        )
    for name in binary_names:
        _require_executable(package_dir / "bin" / f"{name}{extension}", f"{label} {name}")


def _notice_problem(data: bytes, notices_dir: Path | None, kind: str, rust_target: str, label: str) -> str | None:
    """None when the shipped notice is the generated one (or no generated set is given)."""
    if not data.strip():
        return f"{label}: {NOTICE_FILE} is empty"
    if notices_dir is None:
        return None
    generated = notices_dir / f"{kind}-{rust_target}.md"
    if not generated.is_file():
        return f"{label}: no generated notice {generated.name} in {notices_dir} (package_notices.py generate)"
    if generated.read_bytes() != data:
        return f"{label}: {NOTICE_FILE} differs from the generated {generated.name}"
    return None


def _validate_npm_notice(package_dir: Path, target: NpmTarget, kind: str, notices_dir: Path | None) -> None:
    path = package_dir / NOTICE_FILE
    if not path.is_file():
        raise _error(f"{target.name}: missing {NOTICE_FILE}")
    rust_target = NPM_RUST_TARGETS[f"{target.os}-{target.cpu}"]
    problem = _notice_problem(path.read_bytes(), notices_dir, kind, rust_target, target.name)
    if problem:
        raise _error(problem)


def validate_npm_tree(
    packages_dir: Path,
    version: str | None = None,
    *,
    include_windows: bool = False,
    notices_dir: Path | None = None,
) -> str:
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
    targets = npm_targets(include_windows)
    relay_targets = tuple(
        NpmTarget(target.name.replace("cmux-tui", "cmux-relay"), target.os, target.cpu)
        for target in targets
    )
    expected_packages = tuple(
        sorted(("cmux", "cmux-relay", *(target.name for target in targets), *(target.name for target in relay_targets)))
    )
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
    expected_dependencies = {target.name: package_version for target in targets}
    if launcher_metadata.get("optionalDependencies") != expected_dependencies:
        raise _error(
            "cmux: optionalDependencies mismatch: "
            f"expected {expected_dependencies}, "
            f"found {launcher_metadata.get('optionalDependencies')}"
        )
    _require_executable(launcher_dir / "bin/cmux.js", "cmux launcher")

    relay_launcher_dir = packages_dir / "cmux-relay"
    relay_launcher_metadata = _read_json(relay_launcher_dir / "package.json")
    if relay_launcher_metadata.get("name") != "cmux-relay":
        raise _error("cmux-relay: package name is incorrect")
    _validate_version(relay_launcher_metadata.get("version"), package_version, "cmux-relay")
    relay_launcher_files = _files_below(relay_launcher_dir)
    relay_launcher_entries = _entries_below(relay_launcher_dir)
    expected_relay_launcher_entries = NPM_RELAY_LAUNCHER_FILES | {"bin"}
    if relay_launcher_entries != expected_relay_launcher_entries:
        raise _error(
            f"cmux-relay: directory tree mismatch: expected "
            f"{sorted(expected_relay_launcher_entries)}, found {sorted(relay_launcher_entries)}"
        )
    if relay_launcher_files != NPM_RELAY_LAUNCHER_FILES:
        raise _error(
            f"cmux-relay: package files mismatch: expected "
            f"{sorted(NPM_RELAY_LAUNCHER_FILES)}, found {sorted(relay_launcher_files)}"
        )
    if relay_launcher_metadata.get("files") != ["bin/cmux-relay.js"]:
        raise _error("cmux-relay: files must contain only bin/cmux-relay.js")
    if relay_launcher_metadata.get("bin") != {"cmux-relay": "bin/cmux-relay.js"}:
        raise _error("cmux-relay: bin mapping is incorrect")
    expected_relay_dependencies = {target.name: package_version for target in relay_targets}
    if relay_launcher_metadata.get("optionalDependencies") != expected_relay_dependencies:
        raise _error(
            "cmux-relay: optionalDependencies mismatch: "
            f"expected {expected_relay_dependencies}, "
            f"found {relay_launcher_metadata.get('optionalDependencies')}"
        )
    _require_executable(relay_launcher_dir / "bin/cmux-relay.js", "cmux-relay launcher")
    _require_relay_autostart_guard(relay_launcher_dir / "bin/cmux-relay.js")

    for target in targets:
        _validate_npm_notice(packages_dir / target.name, target, "cmux-tui", notices_dir)
        _validate_package_files(
            packages_dir / target.name,
            target,
            binary_names=("cmux-tui", "cmux-tui-hook"),
            expected_files=frozenset(
                {
                    "package.json",
                    NPM_LICENSE_FILE,
                    f"bin/cmux-tui{'.exe' if target.os == 'win32' else ''}",
                    f"bin/cmux-tui-hook{'.exe' if target.os == 'win32' else ''}",
                    NPM_SSH_MANIFEST,
                    NOTICE_FILE,
                }
            ),
            label=target.name,
            version=package_version,
            data_files=(NPM_SSH_MANIFEST, NOTICE_FILE),
        )
    _validate_ssh_manifests(packages_dir, targets)
    for target in relay_targets:
        _validate_npm_notice(packages_dir / target.name, target, "relay", notices_dir)
        _validate_package_files(
            packages_dir / target.name,
            target,
            binary_names=("chatmux-relay", "cmux-tui"),
            expected_files=frozenset(
                {
                    "package.json",
                    NPM_LICENSE_FILE,
                    f"bin/chatmux-relay{'.exe' if target.os == 'win32' else ''}",
                    f"bin/cmux-tui{'.exe' if target.os == 'win32' else ''}",
                    NOTICE_FILE,
                }
            ),
            label=target.name,
            version=package_version,
            data_files=(NOTICE_FILE,),
        )

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


def validate_wheel(path: Path, version: str, notices_dir: Path | None = None) -> None:
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
        if _metadata_value(metadata, "License-Expression") != "GPL-3.0-or-later":
            raise _error(f"{path.name}: METADATA License-Expression is not GPL-3.0-or-later")
        license_files = [line[len(b"License-File:"):].strip().decode() for line in metadata.splitlines() if line.startswith(b"License-File:")]
        if license_files != ["LICENSE", NOTICE_FILE]:
            raise _error(f"{path.name}: METADATA License-File must name LICENSE and {NOTICE_FILE}, not {license_files}")
        problem = _notice_problem(
            wheel.read(f"{dist_info}/licenses/{NOTICE_FILE}"), notices_dir, "cmux-tui", PYPI_RUST_TARGETS[tag], path.name
        )
        if problem:
            raise _error(problem)

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


def validate_pypi_wheels(wheels_dir: Path, version: str, notices_dir: Path | None = None) -> tuple[str, ...]:
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
        validate_wheel(wheels_dir / name, version, notices_dir)
    return actual
