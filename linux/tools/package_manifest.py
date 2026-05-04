#!/usr/bin/env python3
from __future__ import annotations

from typing import Any


SCHEMA_VERSION = 1
PACKAGE_NAME = "cmux-linux-x86_64"
MANIFEST_RELATIVE_PATH = "share/cmux/package-manifest.json"
MANIFEST_MEMBER = f"{PACKAGE_NAME}/{MANIFEST_RELATIVE_PATH}"

REQUIRED_RELATIVE_MEMBERS = (
    "bin/cmux-linux",
    "bin/cmux",
    "lib/cmux_linux/__init__.py",
    "lib/cmux_linux/__main__.py",
    "lib/cmux_linux/app.py",
    "lib/cmux_linux/auth.py",
    "lib/cmux_linux/browser.py",
    "lib/cmux_linux/capabilities.py",
    "lib/cmux_linux/cli.py",
    "lib/cmux_linux/feedback.py",
    "lib/cmux_linux/remote.py",
    "lib/cmux_linux/shortcuts.py",
    "lib/cmux_linux/terminal.py",
    "share/applications/com.cmuxterm.cmux.desktop",
    "README.md",
    MANIFEST_RELATIVE_PATH,
)

EXECUTABLE_RELATIVE_MEMBERS = (
    "bin/cmux-linux",
    "bin/cmux",
)

OPTIONAL_EXECUTABLE_RELATIVE_MEMBERS = (
    "bin/cmuxd-remote",
)

PACKAGE_FORMAT_BACKENDS = {
    "tarball": "linux/package.sh",
    "deb": "linux/package-deb.sh",
    "appimage": "linux/package-appimage.sh",
    "rpm": "linux/package-rpm.sh",
    "flatpak": "linux/package-flatpak.sh",
}
ARTIFACT_FORMATS = tuple(PACKAGE_FORMAT_BACKENDS)
PACKAGE_DISTRIBUTIONS = ARTIFACT_FORMATS


def tarball_member(relative_path: str) -> str:
    return f"{PACKAGE_NAME}/{relative_path}"


def required_members() -> tuple[str, ...]:
    return tuple(tarball_member(path) for path in REQUIRED_RELATIVE_MEMBERS)


def optional_executable_members() -> tuple[str, ...]:
    return tuple(tarball_member(path) for path in OPTIONAL_EXECUTABLE_RELATIVE_MEMBERS)


def executable_members(*, require_remote_daemon: bool) -> list[str]:
    members = [tarball_member(path) for path in EXECUTABLE_RELATIVE_MEMBERS]
    if require_remote_daemon:
        members.extend(optional_executable_members())
    return members


def package_formats() -> dict[str, dict[str, Any]]:
    return {
        name: {
            "available": True,
            "backend": backend,
            "mode": "artifact",
            "detail": "validator_enabled",
            "validator": "linux/tools/validate_package.py",
        }
        for name, backend in PACKAGE_FORMAT_BACKENDS.items()
    }


def build_manifest(
    *,
    remote_daemon_included: bool,
    swift_cli_included: bool = False,
    distribution: str = "tarball",
) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "package_name": PACKAGE_NAME,
        "distribution": distribution,
        "architecture": "x86_64",
        "validator": "linux/tools/validate_package.py",
        "required_members": list(REQUIRED_RELATIVE_MEMBERS),
        "optional_members": list(OPTIONAL_EXECUTABLE_RELATIVE_MEMBERS),
        "executables": list(EXECUTABLE_RELATIVE_MEMBERS)
        + (list(OPTIONAL_EXECUTABLE_RELATIVE_MEMBERS) if remote_daemon_included else []),
        "included": {
            "gtk_app": True,
            "cli": True,
            "auth_bridge": swift_cli_included,
            "python_lib": True,
            "desktop_file": True,
            "remote_daemon": remote_daemon_included,
        },
        "formats": package_formats(),
    }


def validate_manifest(
    manifest: Any,
    *,
    require_remote_daemon: bool,
    require_swift_cli: bool = False,
    distribution: str = "tarball",
) -> list[str]:
    errors: list[str] = []
    if not isinstance(manifest, dict):
        return ["package manifest must be a JSON object"]
    expected = build_manifest(
        remote_daemon_included=require_remote_daemon,
        swift_cli_included=require_swift_cli,
        distribution=distribution,
    )
    for key in ("schema_version", "package_name", "distribution", "architecture", "validator"):
        if manifest.get(key) != expected[key]:
            errors.append(f"manifest {key} must be {expected[key]}")
    for key in ("required_members", "optional_members"):
        if manifest.get(key) != expected[key]:
            errors.append(f"manifest {key} does not match package contract")
    executables = manifest.get("executables")
    if not isinstance(executables, list):
        errors.append("manifest executables must be a list")
    else:
        for executable in EXECUTABLE_RELATIVE_MEMBERS:
            if executable not in executables:
                errors.append(f"manifest executables missing {executable}")
        if require_remote_daemon and OPTIONAL_EXECUTABLE_RELATIVE_MEMBERS[0] not in executables:
            errors.append("manifest executables missing remote daemon")
    included = manifest.get("included")
    if not isinstance(included, dict):
        errors.append("manifest included must be an object")
    else:
        for key in ("gtk_app", "cli", "python_lib", "desktop_file"):
            if included.get(key) is not True:
                errors.append(f"manifest included.{key} must be true")
        if require_remote_daemon and included.get("remote_daemon") is not True:
            errors.append("manifest included.remote_daemon must be true")
        if require_swift_cli and included.get("auth_bridge") is not True:
            errors.append("manifest included.auth_bridge must be true")
    formats = manifest.get("formats")
    if not isinstance(formats, dict):
        errors.append("manifest formats must be an object")
    else:
        for name, backend in PACKAGE_FORMAT_BACKENDS.items():
            format_payload = formats.get(name)
            if not isinstance(format_payload, dict):
                errors.append(f"manifest {name} format missing")
                continue
            if format_payload.get("available") is not True:
                errors.append(f"manifest {name} format must be available")
            if format_payload.get("backend") != backend:
                errors.append(f"manifest {name} backend must be {backend}")
            if format_payload.get("mode") != "artifact":
                errors.append(f"manifest {name} format must be an artifact")
            if format_payload.get("validator") != "linux/tools/validate_package.py":
                errors.append(f"manifest {name} format must use package validator")
    return errors
