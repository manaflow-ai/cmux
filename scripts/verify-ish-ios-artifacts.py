#!/usr/bin/env python3
"""Validate the generated iSH XCFramework and its Alpine rootfs provenance.

The shell wrapper owns provisioning and repository-state checks.  This module
contains the artifact checks shared by the quiet preflight and the diagnostic
verification pass.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import subprocess
import sys
import tarfile
from pathlib import Path
from typing import Any, NoReturn


class ValidationError(Exception):
    """A deterministic artifact validation failure."""


def fail(message: str) -> NoReturn:
    raise ValidationError(message)


def sha256_file(path: Path, description: str) -> str:
    if path.is_symlink() or not path.is_file():
        fail(f"missing {description}: {path}")
    try:
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()
    except OSError as exc:
        fail(f"cannot read {description} {path}: {exc}")


def run_checked(command: list[str], description: str) -> str:
    try:
        result = subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = ""
        if isinstance(exc, subprocess.CalledProcessError):
            detail = (exc.stderr or exc.stdout or "").strip()
        suffix = f": {detail}" if detail else ""
        fail(f"cannot {description}{suffix}")
    return result.stdout


def read_json(path: Path, description: str) -> Any:
    if path.is_symlink() or not path.is_file():
        fail(f"missing {description}: {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"invalid {description} {path}: {exc}")


def read_ish_revision(ish_dir: Path) -> str:
    return run_checked(
        ["git", "-C", str(ish_dir), "rev-parse", "HEAD"],
        "read vendor/ish revision",
    ).strip()


def shim_hash(shim_dir: Path) -> str:
    try:
        shim_paths = sorted(shim_dir.glob("*.c")) + sorted(shim_dir.glob("*.h"))
    except OSError as exc:
        fail(f"cannot inspect cmux iSH shim sources under {shim_dir}: {exc}")
    if not shim_paths:
        fail(f"no cmux iSH shim sources under {shim_dir}")
    lines = "".join(
        f"{sha256_file(path, 'shim source')}  {path.name}\n" for path in shim_paths
    )
    return hashlib.sha256(lines.encode("utf-8")).hexdigest()


def validate_xcframework(
    xcframework: Path,
    device_only: bool,
    rootfs_sha: str,
    ish_revision: str,
    shim_sha: str,
    deployment_target: str,
) -> set[str]:
    info_path = xcframework / "Info.plist"
    if info_path.is_symlink() or not info_path.is_file():
        fail(f"missing xcframework metadata: {info_path}")
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (OSError, ValueError, TypeError) as exc:
        fail(f"invalid xcframework Info.plist: {exc}")
    if not isinstance(info, dict):
        fail("invalid xcframework Info.plist: root is not a dictionary")

    libraries = info.get("AvailableLibraries")
    if not isinstance(libraries, list) or not libraries:
        fail("IshKernel.xcframework has no AvailableLibraries")
    identifiers = {
        entry.get("LibraryIdentifier")
        for entry in libraries
        if isinstance(entry, dict)
    }
    required = {"ios-arm64"}
    if not device_only:
        required.add("ios-arm64-simulator")
    missing = sorted(required - identifiers)
    if missing:
        fail(
            "IshKernel.xcframework is missing slice(s): "
            + ", ".join(missing)
            + ". Rebuild with ./scripts/build-ish-ios.sh"
        )

    for entry in libraries:
        if not isinstance(entry, dict):
            fail("malformed AvailableLibraries entry")
        identifier = entry.get("LibraryIdentifier")
        if identifier not in required:
            continue
        # Require the static archive shape used by CmuxLocalLinux. Wrapping an
        # archive in a framework can make Xcode embed an inert framework even
        # though the symbols are linked into the app executable.
        library_path = entry.get("LibraryPath")
        binary_path = entry.get("BinaryPath")
        if library_path != "libIshKernel.a" or binary_path != "libIshKernel.a":
            fail(f"incomplete metadata for {identifier}")
        if "HeadersPath" in entry:
            fail(f"incomplete metadata for {identifier}")

        slice_dir = xcframework / identifier
        if slice_dir.is_symlink():
            fail(f"{identifier} contains symlinked library paths")
        binary = slice_dir / binary_path
        sidecar = slice_dir / "cmux-ish-provenance.json"
        for path in (binary, sidecar):
            if path.is_symlink() or not path.is_file():
                fail(f"{identifier} is missing {path}")

        sidecar_data = read_json(sidecar, f"provenance sidecar for {identifier}")
        if not isinstance(sidecar_data, dict):
            fail(f"provenance sidecar for {identifier} is not an object")
        expected_sidecar = {
            "format": "cmux-ish-provenance-v1",
            "ishCommit": ish_revision,
            "rootfsSHA256": rootfs_sha,
            "shimSHA256": shim_sha,
            "deploymentTarget": deployment_target,
            "slice": "iphoneos" if identifier == "ios-arm64" else "iphonesimulator",
            "architecture": "arm64",
        }
        for key, expected in expected_sidecar.items():
            if sidecar_data.get(key) != expected:
                fail(
                    f"stale provenance for {identifier}, field {key!r} "
                    f"is {sidecar_data.get(key)!r}, expected {expected!r}; "
                    "rebuild with ./scripts/build-ish-ios.sh"
                )

        if binary.stat().st_size == 0:
            fail(f"empty IshKernel binary: {binary}")
        archs = run_checked(
            ["xcrun", "lipo", "-archs", str(binary)],
            f"inspect IshKernel architecture {binary}",
        ).strip().split()
        if archs != ["arm64"]:
            fail(
                f"IshKernel binary {binary} must contain only arm64, "
                f"got {' '.join(archs) or '<none>'}"
            )
        symbols = run_checked(
            ["xcrun", "nm", "-gU", str(binary)],
            f"inspect IshKernel symbols {binary}",
        )
        if "_cmux_ish_boot" not in symbols:
            fail(f"{binary} does not export cmux_ish_boot")

    return required


def parse_installed_packages(rootfs: Path) -> dict[str, dict[str, str]]:
    try:
        with tarfile.open(rootfs, "r:gz") as archive:
            installed_member = next(
                (
                    member
                    for member in archive.getmembers()
                    if member.name.lstrip("./") == "lib/apk/db/installed"
                ),
                None,
            )
            if installed_member is None:
                fail("rootfs has no Alpine package database")
            installed_stream = archive.extractfile(installed_member)
            if installed_stream is None:
                fail("cannot read Alpine package database")
            records: dict[str, dict[str, str]] = {}
            record: dict[str, str] = {}
            for line in installed_stream.read().decode("utf-8").splitlines() + [""]:
                if not line:
                    name = record.get("P")
                    if name:
                        records[name] = record
                    record = {}
                    continue
                key, separator, value = line.partition(":")
                if separator:
                    record[key] = value
            return records
    except (OSError, UnicodeDecodeError, tarfile.TarError) as exc:
        fail(f"invalid Alpine rootfs archive: {exc}")


def validate_rootfs(rootfs: Path, provenance: Path, actual_hash: str) -> None:
    metadata = read_json(provenance, "rootfs provenance")
    if not isinstance(metadata, dict):
        fail("rootfs provenance is not an object")
    if metadata.get("archive") != rootfs.name:
        fail("rootfs provenance archive name does not match resource")
    if metadata.get("sha256") != actual_hash:
        fail(
            "Alpine rootfs SHA-256 mismatch: "
            f"expected {metadata.get('sha256')}, got {actual_hash}"
        )

    expected_packages = metadata.get("packages")
    if not isinstance(expected_packages, list) or not expected_packages:
        fail("rootfs provenance has no package manifest")
    records = parse_installed_packages(rootfs)
    for package in expected_packages:
        if not isinstance(package, dict):
            fail("malformed rootfs package manifest entry")
        name = package.get("name")
        if not isinstance(name, str):
            fail("malformed rootfs package manifest entry name")
        actual = records.get(name)
        if actual is None:
            fail(f"rootfs package manifest names missing package {name!r}")
        for field, key in (("version", "V"), ("license", "L")):
            if package.get(field) != actual.get(key):
                fail(
                    f"rootfs package {name!r} {field} mismatch: "
                    f"expected {package.get(field)!r}, got {actual.get(key)!r}"
                )



def validate(args: argparse.Namespace) -> str:
    xcframework = args.xcframework
    if xcframework.is_symlink() or not xcframework.is_dir():
        fail(f"missing xcframework: {xcframework}")
    rootfs_sha = sha256_file(args.rootfs, "rootfs resource")
    ish_revision = read_ish_revision(args.ish_dir)
    shim_sha = shim_hash(args.shim_dir)
    required = validate_xcframework(
        xcframework,
        args.device_only,
        rootfs_sha,
        ish_revision,
        shim_sha,
        args.deployment_target,
    )
    validate_rootfs(args.rootfs, args.provenance, rootfs_sha)
    return "IshKernel artifacts OK: " + ", ".join(sorted(required)) + f"; rootfs sha256={rootfs_sha}"


def argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate iSH XCFramework slices and Alpine rootfs provenance."
    )
    parser.add_argument("--xcframework", type=Path, required=True)
    parser.add_argument("--rootfs", type=Path, required=True)
    parser.add_argument("--provenance", type=Path, required=True)
    parser.add_argument("--ish-dir", type=Path, required=True)
    parser.add_argument("--shim-dir", type=Path, required=True)
    parser.add_argument("--deployment-target", required=True)
    parser.add_argument("--device-only", action="store_true")
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="suppress diagnostics and success output while preserving the exit status",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = argument_parser().parse_args(argv)
    try:
        message = validate(args)
    except ValidationError as exc:
        if not args.quiet:
            print(f"error: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:  # Keep preflight failures concise and traceback-free.
        if not args.quiet:
            print(f"error: unexpected validation failure: {exc}", file=sys.stderr)
        return 1
    if not args.quiet:
        print(message)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
