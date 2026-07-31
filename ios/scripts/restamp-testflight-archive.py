#!/usr/bin/env python3
"""Validate and restamp an unsigned iOS archive before trusted signing."""

from __future__ import annotations

import argparse
import os
import plistlib
import re
import stat
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any


BUILD_NUMBER_RE = re.compile(r"[1-9][0-9]{0,17}")
MAX_ARCHIVE_ENTRIES = 200_000
MAX_ARCHIVE_BYTES = 10 * 1024 * 1024 * 1024
NESTED_BUNDLE_SUFFIXES = {".app", ".appex", ".xpc"}
UNSUPPORTED_APP_DIRECTORIES = {"AppClips", "PlugIns", "Watch"}
EXPECTED_APP_NAME = "cmux.app"
EXPECTED_EXECUTABLE = "cmux"


class ArchiveValidationError(RuntimeError):
    pass


def _fail(message: str) -> None:
    raise ArchiveValidationError(message)


def _validate_tree(root: Path) -> None:
    try:
        root_mode = root.lstat().st_mode
    except FileNotFoundError:
        _fail(f"archive does not exist: {root}")
    if not stat.S_ISDIR(root_mode) or stat.S_ISLNK(root_mode):
        _fail("archive path must be a real directory")

    entries = 0
    pending = [root]
    while pending:
        directory = pending.pop()
        try:
            children = list(os.scandir(directory))
        except OSError as exc:
            _fail(f"cannot inspect archive tree: {exc}")
        for child in children:
            entries += 1
            if entries > MAX_ARCHIVE_ENTRIES:
                _fail(f"archive exceeds {MAX_ARCHIVE_ENTRIES} entries")
            try:
                mode = child.stat(follow_symlinks=False).st_mode
            except OSError as exc:
                _fail(f"cannot inspect archive entry: {exc}")
            if stat.S_ISLNK(mode):
                _fail(f"archive contains a symbolic link: {child.name}")
            if stat.S_ISDIR(mode):
                pending.append(Path(child.path))
            elif not stat.S_ISREG(mode):
                _fail(f"archive contains a non-file entry: {child.name}")


def extract_archive_tar(tar_path: Path, archive: Path) -> None:
    try:
        tar_metadata = tar_path.lstat()
    except FileNotFoundError:
        _fail(f"archive tar does not exist: {tar_path}")
    if not stat.S_ISREG(tar_metadata.st_mode) or stat.S_ISLNK(tar_metadata.st_mode):
        _fail("archive tar must be a regular file")
    if tar_metadata.st_size <= 0 or tar_metadata.st_size > MAX_ARCHIVE_BYTES:
        _fail("archive tar has an invalid size")
    if archive.exists() or archive.is_symlink():
        _fail("archive extraction target already exists")

    expected_root = archive.name
    destination = archive.parent
    destination.mkdir(parents=True, exist_ok=True)
    members: list[tuple[tarfile.TarInfo, tuple[str, ...]]] = []
    seen: set[tuple[str, ...]] = set()
    total_size = 0
    root_is_directory = False

    try:
        with tarfile.open(tar_path, mode="r:") as handle:
            for member in handle:
                if len(members) >= MAX_ARCHIVE_ENTRIES:
                    _fail(f"archive tar exceeds {MAX_ARCHIVE_ENTRIES} entries")
                normalized = PurePosixPath(member.name)
                parts = normalized.parts
                if (
                    not parts
                    or normalized.is_absolute()
                    or any(part in {"", ".", ".."} for part in parts)
                    or normalized.as_posix() != member.name
                    or parts[0] != expected_root
                ):
                    _fail(f"archive tar contains an unsafe path: {member.name!r}")
                if parts in seen:
                    _fail(f"archive tar contains a duplicate path: {member.name!r}")
                seen.add(parts)
                if member.type not in {tarfile.REGTYPE, tarfile.AREGTYPE, tarfile.DIRTYPE}:
                    _fail(f"archive tar contains an unsupported entry: {member.name!r}")
                if member.isfile():
                    total_size += member.size
                    if member.size < 0 or total_size > MAX_ARCHIVE_BYTES:
                        _fail("archive tar expands beyond the size limit")
                elif parts == (expected_root,):
                    root_is_directory = True
                members.append((member, parts))

            if not root_is_directory:
                _fail("archive tar is missing its root directory")

            directories = sorted(
                ((member, parts) for member, parts in members if member.isdir()),
                key=lambda item: len(item[1]),
            )
            for _, parts in directories:
                path = destination.joinpath(*parts)
                path.mkdir(mode=0o700, parents=True, exist_ok=False)

            no_follow = getattr(os, "O_NOFOLLOW", 0)
            for member, parts in members:
                if not member.isfile():
                    continue
                source = handle.extractfile(member)
                if source is None:
                    _fail(f"cannot read archive member: {member.name!r}")
                path = destination.joinpath(*parts)
                descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | no_follow, 0o600)
                written = 0
                try:
                    with os.fdopen(descriptor, "wb") as output:
                        while True:
                            chunk = source.read(1024 * 1024)
                            if not chunk:
                                break
                            written += len(chunk)
                            if written > member.size:
                                _fail(f"archive member exceeds declared size: {member.name!r}")
                            output.write(chunk)
                        output.flush()
                        os.fchmod(output.fileno(), member.mode & 0o777)
                    if written != member.size:
                        _fail(f"archive member size mismatch: {member.name!r}")
                finally:
                    source.close()

            for member, parts in reversed(directories):
                os.chmod(destination.joinpath(*parts), member.mode & 0o777)
    except ArchiveValidationError:
        raise
    except (OSError, tarfile.TarError) as exc:
        _fail(f"cannot extract archive tar: {exc}")


def _load_plist(path: Path) -> tuple[dict[str, Any], plistlib.PlistFormat]:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        _fail(f"missing plist: {path.name}")
    if not stat.S_ISREG(mode) or stat.S_ISLNK(mode):
        _fail(f"plist must be a regular file: {path.name}")
    try:
        raw = path.read_bytes()
        value = plistlib.loads(raw)
    except (OSError, plistlib.InvalidFileException) as exc:
        _fail(f"invalid plist {path.name}: {exc}")
    if not isinstance(value, dict):
        _fail(f"plist root must be a dictionary: {path.name}")
    plist_format = plistlib.FMT_BINARY if raw.startswith(b"bplist00") else plistlib.FMT_XML
    return value, plist_format


def _write_plist(path: Path, value: dict[str, Any], plist_format: plistlib.PlistFormat) -> None:
    original_mode = stat.S_IMODE(path.stat().st_mode)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            plistlib.dump(value, handle, fmt=plist_format, sort_keys=False)
            handle.flush()
            os.fchmod(handle.fileno(), original_mode)
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def _expect(value: Any, expected: str, label: str) -> None:
    if value != expected:
        _fail(f"unexpected {label}: {value!r} (expected {expected!r})")


def _archive_app(archive: Path) -> Path:
    applications = archive / "Products" / "Applications"
    if not applications.is_dir() or applications.is_symlink():
        _fail("archive is missing Products/Applications")
    children = list(applications.iterdir())
    apps = [child for child in children if child.suffix == ".app" and child.is_dir() and not child.is_symlink()]
    if len(children) != 1 or len(apps) != 1:
        _fail("archive must contain exactly one application and no sibling payloads")
    if apps[0].name != EXPECTED_APP_NAME:
        _fail(f"unexpected application name: {apps[0].name!r}")
    return apps[0]


def _validate_no_nested_payloads(app: Path) -> None:
    for name in UNSUPPORTED_APP_DIRECTORIES:
        if (app / name).exists():
            _fail(f"unsupported nested payload directory: {name}")
    for path in app.rglob("*"):
        if path != app and path.suffix in NESTED_BUNDLE_SUFFIXES:
            _fail(f"unsupported nested bundle: {path.name}")


def _validated_plists(
    archive: Path,
    expected_bundle_id: str,
    expected_display_name: str,
    expected_marketing_version: str,
) -> tuple[Path, dict[str, Any], plistlib.PlistFormat, Path, dict[str, Any], plistlib.PlistFormat]:
    app = _archive_app(archive)
    _validate_no_nested_payloads(app)

    app_plist_path = app / "Info.plist"
    app_plist, app_format = _load_plist(app_plist_path)
    _expect(app_plist.get("CFBundleIdentifier"), expected_bundle_id, "app bundle identifier")
    _expect(app_plist.get("CFBundleDisplayName"), expected_display_name, "app display name")
    _expect(app_plist.get("CFBundleExecutable"), EXPECTED_EXECUTABLE, "app executable")
    _expect(app_plist.get("CFBundleShortVersionString"), expected_marketing_version, "app marketing version")
    executable = app / EXPECTED_EXECUTABLE
    try:
        executable_mode = executable.lstat().st_mode
    except FileNotFoundError:
        _fail("app executable is missing")
    if not stat.S_ISREG(executable_mode) or stat.S_ISLNK(executable_mode) or executable_mode & 0o111 == 0:
        _fail("app executable must be an executable regular file")

    archive_plist_path = archive / "Info.plist"
    archive_plist, archive_format = _load_plist(archive_plist_path)
    properties = archive_plist.get("ApplicationProperties")
    if not isinstance(properties, dict):
        _fail("archive Info.plist is missing ApplicationProperties")
    _expect(properties.get("ApplicationPath"), f"Applications/{app.name}", "archive application path")
    _expect(properties.get("CFBundleIdentifier"), expected_bundle_id, "archive bundle identifier")
    _expect(
        properties.get("CFBundleShortVersionString"),
        expected_marketing_version,
        "archive marketing version",
    )
    current_app_build = str(app_plist.get("CFBundleVersion", ""))
    current_archive_build = str(properties.get("CFBundleVersion", ""))
    if not BUILD_NUMBER_RE.fullmatch(current_app_build) or current_app_build != current_archive_build:
        _fail("archive and app must start with the same positive numeric CFBundleVersion")
    return app_plist_path, app_plist, app_format, archive_plist_path, archive_plist, archive_format


def restamp(
    archive: Path,
    expected_bundle_id: str,
    expected_display_name: str,
    expected_marketing_version: str,
    build_number: str,
) -> None:
    if archive.suffix != ".xcarchive":
        _fail("archive path must end in .xcarchive")
    if not BUILD_NUMBER_RE.fullmatch(build_number):
        _fail("build number must be a positive integer of at most 18 digits")
    _validate_tree(archive)
    app_path, app_plist, app_format, archive_path, archive_plist, archive_format = _validated_plists(
        archive,
        expected_bundle_id,
        expected_display_name,
        expected_marketing_version,
    )

    app_plist["CFBundleVersion"] = build_number
    archive_plist["ApplicationProperties"]["CFBundleVersion"] = build_number
    _write_plist(app_path, app_plist, app_format)
    _write_plist(archive_path, archive_plist, archive_format)

    _validate_tree(archive)
    _, checked_app, _, _, checked_archive, _ = _validated_plists(
        archive,
        expected_bundle_id,
        expected_display_name,
        expected_marketing_version,
    )
    _expect(str(checked_app.get("CFBundleVersion")), build_number, "restamped app build number")
    _expect(
        str(checked_archive["ApplicationProperties"].get("CFBundleVersion")),
        build_number,
        "restamped archive build number",
    )


def validate(
    archive: Path,
    expected_bundle_id: str,
    expected_display_name: str,
    expected_marketing_version: str,
) -> None:
    if archive.suffix != ".xcarchive":
        _fail("archive path must end in .xcarchive")
    _validate_tree(archive)
    _validated_plists(
        archive,
        expected_bundle_id,
        expected_display_name,
        expected_marketing_version,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--archive-tar", type=Path)
    parser.add_argument("--expected-bundle-id", required=True)
    parser.add_argument("--expected-display-name", required=True)
    parser.add_argument("--expected-marketing-version", required=True)
    operation = parser.add_mutually_exclusive_group(required=True)
    operation.add_argument("--build-number")
    operation.add_argument("--validate-only", action="store_true")
    args = parser.parse_args()
    if args.archive_tar:
        extract_archive_tar(args.archive_tar, args.archive)
    if args.validate_only:
        validate(
            args.archive,
            args.expected_bundle_id,
            args.expected_display_name,
            args.expected_marketing_version,
        )
        print(f"validated {args.archive.name}")
    else:
        restamp(
            args.archive,
            args.expected_bundle_id,
            args.expected_display_name,
            args.expected_marketing_version,
            args.build_number,
        )
        print(f"restamped {args.archive.name} to build {args.build_number}")


if __name__ == "__main__":
    try:
        main()
    except ArchiveValidationError as exc:
        print(f"restamp-testflight-archive: {exc}", file=sys.stderr)
        raise SystemExit(1)
