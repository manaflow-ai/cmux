#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path

from package_manifest import (  # noqa: E402
    MANIFEST_MEMBER,
    MANIFEST_RELATIVE_PATH,
    optional_executable_members,
    required_members,
    executable_members,
    validate_manifest,
)

DESKTOP_RELATIVE_PATH = "share/applications/com.cmuxterm.cmux.desktop"
DESKTOP_MEMBER = "cmux-linux-x86_64/" + DESKTOP_RELATIVE_PATH
DEB_PACKAGE = "cmux-linux"
DEB_REQUIRED_ROOT_PATHS = tuple(
    Path("/usr") / path
    for path in (
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
        DESKTOP_RELATIVE_PATH,
        "share/doc/cmux/README.md",
        "share/cmux/package-manifest.json",
    )
)
DEB_EXECUTABLE_ROOT_PATHS = (Path("/usr/bin/cmux-linux"), Path("/usr/bin/cmux"))
DEB_OPTIONAL_EXECUTABLE_ROOT_PATH = Path("/usr/bin/cmuxd-remote")
SWIFT_CLI_ROOT_PATH = Path("/usr/bin/cmux")
SWIFT_CLI_TARBALL_MEMBER = "cmux-linux-x86_64/bin/cmux"
APPIMAGE_ROOT_DESKTOP = Path("com.cmuxterm.cmux.desktop")
APPIMAGE_ROOT_LAUNCHER = Path("AppRun")
FLATPAK_DEFAULT_APP_REF_PREFIX = "app/com.cmuxterm.cmux/"
DESKTOP_REQUIRED_FIELDS = {
    "Type": "Application",
    "Name": "cmux",
    "Exec": "cmux-linux",
    "TryExec": "cmux-linux",
    "Terminal": "false",
}
DESKTOP_REQUIRED_CATEGORIES = {"System", "TerminalEmulator", "Development"}
REMOTE_DAEMON_PROBE_TIMEOUT_SECONDS = 5.0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate cmux Linux package artifacts.")
    parser.add_argument("archive", type=Path, help="Path to a cmux Linux tarball, deb, AppImage, rpm, or Flatpak bundle.")
    parser.add_argument(
        "--require-remote-daemon",
        action="store_true",
        help="Require bin/cmuxd-remote to be present and executable.",
    )
    parser.add_argument(
        "--require-swift-cli",
        action="store_true",
        help="Require the packaged bin/cmux to be the Swift CLI with auth-bridge support.",
    )
    parser.add_argument(
        "--probe-remote-daemon",
        action="store_true",
        help="Run the packaged cmuxd-remote serve --stdio hello/ping smoke.",
    )
    return parser.parse_args()


def mode_is_executable(member: tarfile.TarInfo) -> bool:
    return bool(member.mode & 0o111)


def parse_desktop_entry(content: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for raw_line in content.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or line.startswith("["):
            continue
        if "=" not in line:
            raise ValueError(f"invalid desktop entry line: {raw_line}")
        key, value = line.split("=", 1)
        fields[key] = value
    return fields


def validate_desktop_entry(fields: dict[str, str]) -> list[str]:
    errors = [
        f"desktop field {key} must be {expected}"
        for key, expected in DESKTOP_REQUIRED_FIELDS.items()
        if fields.get(key) != expected
    ]
    categories = {category for category in fields.get("Categories", "").split(";") if category}
    missing_categories = sorted(DESKTOP_REQUIRED_CATEGORIES - categories)
    if missing_categories:
        errors.append("desktop categories missing: " + ", ".join(missing_categories))
    return errors


def parse_deb_control_fields(output: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for raw_line in output.splitlines():
        if not raw_line.strip():
            continue
        if ":" not in raw_line:
            raise ValueError(f"invalid deb control line: {raw_line}")
        key, value = raw_line.split(":", 1)
        fields[key.strip()] = value.strip()
    return fields


def require_tool(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise SystemExit(f"{name} is required to validate this artifact")
    return path


def resolve_root_path(root: Path, package_path: Path, install_prefix: Path) -> Path:
    return root / install_prefix / package_path.relative_to("/usr")


def swift_cli_validation_error(content: bytes, label: str) -> str | None:
    if content.startswith(b"#!"):
        return f"{label} must be the Swift CLI binary with auth-bridge support, not the fallback script"
    if not content:
        return f"{label} must not be empty when Swift CLI auth bridge is required"
    if not content.startswith(b"\x7fELF"):
        return f"{label} must be an ELF Swift CLI binary with auth-bridge support"
    return None


def remote_daemon_probe_error(binary: Path) -> str | None:
    requests = "\n".join(
        [
            json.dumps({"id": "hello", "method": "hello", "params": {}}),
            json.dumps({"id": "ping", "method": "ping", "params": {}}),
        ]
    )
    try:
        completed = subprocess.run(
            [str(binary), "serve", "--stdio"],
            input=requests + "\n",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            text=True,
            timeout=REMOTE_DAEMON_PROBE_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as error:
        return f"remote daemon probe timed out for {binary}: {error}"
    except OSError as error:
        return f"remote daemon probe failed to start {binary}: {error}"

    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip() or f"exit code {completed.returncode}"
        return f"remote daemon probe failed for {binary}: {detail}"

    lines = [line for line in completed.stdout.splitlines() if line.strip()]
    if len(lines) != 2:
        return f"remote daemon probe expected 2 response lines, got {len(lines)}"

    responses: dict[str, dict[str, object]] = {}
    for line in lines:
        try:
            payload = json.loads(line)
        except json.JSONDecodeError as error:
            return f"remote daemon probe returned invalid JSON: {error}"
        if not isinstance(payload, dict):
            return "remote daemon probe response must be a JSON object"
        response_id = payload.get("id")
        if not isinstance(response_id, str):
            return "remote daemon probe response id must be a string"
        responses[response_id] = payload

    hello = responses.get("hello")
    if hello is None or hello.get("ok") is not True:
        return f"remote daemon hello response must be ok=true: {hello}"
    hello_result = hello.get("result")
    if not isinstance(hello_result, dict):
        return f"remote daemon hello response missing result object: {hello}"
    capabilities = hello_result.get("capabilities")
    if not isinstance(capabilities, list) or "proxy.stream.push" not in capabilities:
        return f"remote daemon hello response missing proxy.stream.push capability: {hello_result}"

    ping = responses.get("ping")
    if ping is None or ping.get("ok") is not True:
        return f"remote daemon ping response must be ok=true: {ping}"
    ping_result = ping.get("result")
    if not isinstance(ping_result, dict) or ping_result.get("pong") is not True:
        return f"remote daemon ping response missing pong=true: {ping}"
    return None


def validate_root_tree(
    root: Path,
    args: argparse.Namespace,
    *,
    distribution: str,
    label: str,
    install_prefix: Path = Path("usr"),
) -> None:
    missing = [
        str(path)
        for path in DEB_REQUIRED_ROOT_PATHS
        if not resolve_root_path(root, path, install_prefix).exists()
    ]
    if args.require_remote_daemon and not resolve_root_path(
        root,
        DEB_OPTIONAL_EXECUTABLE_ROOT_PATH,
        install_prefix,
    ).exists():
        missing.append(str(DEB_OPTIONAL_EXECUTABLE_ROOT_PATH))
    if missing:
        raise SystemExit(f"missing {label} package members: " + ", ".join(missing))

    forbidden = [
        str(path.relative_to(root))
        for path in root.rglob("*")
        if "__pycache__" in path.parts or path.name.endswith(".pyc") or path.name == ".DS_Store"
    ]
    if forbidden:
        raise SystemExit(f"forbidden {label} package members: " + ", ".join(forbidden))

    executable_paths = [resolve_root_path(root, path, install_prefix) for path in DEB_EXECUTABLE_ROOT_PATHS]
    if args.require_remote_daemon:
        executable_paths.append(resolve_root_path(root, DEB_OPTIONAL_EXECUTABLE_ROOT_PATH, install_prefix))
    non_executable = [str(path) for path in executable_paths if not os.access(path, os.X_OK)]
    if non_executable:
        raise SystemExit(f"non-executable {label} package members: " + ", ".join(non_executable))
    if args.require_swift_cli:
        swift_cli_path = resolve_root_path(root, SWIFT_CLI_ROOT_PATH, install_prefix)
        swift_cli_error = swift_cli_validation_error(swift_cli_path.read_bytes(), str(SWIFT_CLI_ROOT_PATH))
        if swift_cli_error:
            raise SystemExit(swift_cli_error)
    if args.probe_remote_daemon:
        remote_daemon_path = resolve_root_path(root, DEB_OPTIONAL_EXECUTABLE_ROOT_PATH, install_prefix)
        remote_probe_error = remote_daemon_probe_error(remote_daemon_path)
        if remote_probe_error:
            raise SystemExit(remote_probe_error)

    desktop_bytes = resolve_root_path(
        root,
        Path("/usr") / DESKTOP_RELATIVE_PATH,
        install_prefix,
    ).read_bytes()
    manifest_bytes = resolve_root_path(
        root,
        Path("/usr") / MANIFEST_RELATIVE_PATH,
        install_prefix,
    ).read_bytes()
    validate_desktop_and_manifest(
        desktop_bytes,
        manifest_bytes,
        args=args,
        distribution=distribution,
    )


def validate_tarball(args: argparse.Namespace) -> None:
    with tarfile.open(args.archive, "r:gz") as archive:
        members = {member.name: member for member in archive.getmembers()}
        desktop_bytes = archive.extractfile(DESKTOP_MEMBER).read() if DESKTOP_MEMBER in members else b""
        manifest_bytes = archive.extractfile(MANIFEST_MEMBER).read() if MANIFEST_MEMBER in members else b""
        swift_cli_bytes = archive.extractfile(SWIFT_CLI_TARBALL_MEMBER).read() if SWIFT_CLI_TARBALL_MEMBER in members else b""
        remote_daemon_member = optional_executable_members()[0]
        remote_daemon_bytes = (
            archive.extractfile(remote_daemon_member).read() if remote_daemon_member in members else b""
        )

    missing = [name for name in required_members() if name not in members]
    if args.require_remote_daemon and optional_executable_members()[0] not in members:
        missing.append(optional_executable_members()[0])
    if missing:
        raise SystemExit("missing package members: " + ", ".join(missing))

    forbidden = [
        name
        for name in members
        if "__pycache__" in name or name.endswith(".pyc") or "/.DS_Store" in name
    ]
    if forbidden:
        raise SystemExit("forbidden package members: " + ", ".join(forbidden))

    executables = executable_members(require_remote_daemon=args.require_remote_daemon)
    non_executable = [name for name in executables if not mode_is_executable(members[name])]
    if non_executable:
        raise SystemExit("non-executable package members: " + ", ".join(non_executable))
    if args.require_swift_cli:
        swift_cli_error = swift_cli_validation_error(swift_cli_bytes, SWIFT_CLI_TARBALL_MEMBER)
        if swift_cli_error:
            raise SystemExit(swift_cli_error)
    if args.probe_remote_daemon:
        with tempfile.TemporaryDirectory(prefix="cmux-tarball-remote-probe-") as temp:
            remote_daemon_path = Path(temp) / "cmuxd-remote"
            remote_daemon_path.write_bytes(remote_daemon_bytes)
            remote_daemon_path.chmod(0o755)
            remote_probe_error = remote_daemon_probe_error(remote_daemon_path)
            if remote_probe_error:
                raise SystemExit(remote_probe_error)

    validate_desktop_and_manifest(
        desktop_bytes,
        manifest_bytes,
        args=args,
        distribution="tarball",
    )


def validate_deb(args: argparse.Namespace) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-deb-validate-") as temp:
        root = Path(temp) / "root"
        control = subprocess.run(
            ["dpkg-deb", "-f", str(args.archive), "Package", "Architecture", "Version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            text=True,
        )
        if control.returncode != 0:
            raise SystemExit(control.stderr.strip() or "dpkg-deb failed to read package control")
        try:
            fields = parse_deb_control_fields(control.stdout)
        except ValueError as error:
            raise SystemExit(str(error)) from error
        if fields.get("Package") != DEB_PACKAGE:
            raise SystemExit("deb control package must be cmux-linux")
        if fields.get("Architecture") != "amd64":
            raise SystemExit("deb control architecture must be amd64")
        if not fields.get("Version"):
            raise SystemExit("deb control version is missing")

        extract = subprocess.run(
            ["dpkg-deb", "-x", str(args.archive), str(root)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            text=True,
        )
        if extract.returncode != 0:
            raise SystemExit(extract.stderr.strip() or "dpkg-deb failed to extract package")

        validate_root_tree(root, args, distribution="deb", label="deb")


def validate_appimage(args: argparse.Namespace) -> None:
    require_tool("unsquashfs")
    with tempfile.TemporaryDirectory(prefix="cmux-appimage-validate-") as temp:
        root = Path(temp) / "root"
        extract = subprocess.run(
            ["unsquashfs", "-q", "-d", str(root), str(args.archive)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            text=True,
        )
        if extract.returncode != 0:
            raise SystemExit(extract.stderr.strip() or "unsquashfs failed to extract AppImage")
        missing_root_files = [
            str(path)
            for path in (APPIMAGE_ROOT_LAUNCHER, APPIMAGE_ROOT_DESKTOP)
            if not (root / path).exists()
        ]
        if missing_root_files:
            raise SystemExit("missing AppImage root members: " + ", ".join(missing_root_files))
        if not os.access(root / APPIMAGE_ROOT_LAUNCHER, os.X_OK):
            raise SystemExit("AppImage AppRun must be executable")
        validate_root_tree(root, args, distribution="appimage", label="AppImage")


def validate_rpm(args: argparse.Namespace) -> None:
    require_tool("rpm2cpio")
    require_tool("cpio")
    with tempfile.TemporaryDirectory(prefix="cmux-rpm-validate-") as temp:
        root = Path(temp) / "root"
        root.mkdir(parents=True)
        rpm2cpio = subprocess.Popen(
            ["rpm2cpio", str(args.archive)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=False,
        )
        cpio = subprocess.run(
            ["cpio", "-idm", "--quiet"],
            cwd=root,
            stdin=rpm2cpio.stdout,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if rpm2cpio.stdout is not None:
            rpm2cpio.stdout.close()
        rpm_error = rpm2cpio.stderr.read() if rpm2cpio.stderr is not None else b""
        rpm2cpio.wait()
        if rpm2cpio.returncode != 0:
            raise SystemExit(rpm_error.decode("utf-8", errors="replace").strip() or "rpm2cpio failed")
        if cpio.returncode != 0:
            raise SystemExit(cpio.stderr.decode("utf-8", errors="replace").strip() or "cpio failed to extract rpm")
        validate_root_tree(root, args, distribution="rpm", label="rpm")


def select_flatpak_ref(output: str) -> str:
    refs = [line.strip() for line in output.splitlines() if line.strip()]
    app_refs = [ref for ref in refs if ref.startswith("app/")]
    if not app_refs:
        raise SystemExit("Flatpak bundle did not import an app ref")
    preferred_refs = [ref for ref in app_refs if ref.startswith(FLATPAK_DEFAULT_APP_REF_PREFIX)]
    return (preferred_refs or app_refs)[0]


def validate_flatpak(args: argparse.Namespace) -> None:
    require_tool("flatpak")
    require_tool("ostree")
    with tempfile.TemporaryDirectory(prefix="cmux-flatpak-validate-") as temp:
        repo = Path(temp) / "repo"
        import_bundle = subprocess.run(
            ["flatpak", "build-import-bundle", str(repo), str(args.archive)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            text=True,
        )
        if import_bundle.returncode != 0:
            raise SystemExit(import_bundle.stderr.strip() or "flatpak failed to import bundle")
        refs = subprocess.run(
            ["ostree", f"--repo={repo}", "refs"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            text=True,
        )
        if refs.returncode != 0:
            raise SystemExit(refs.stderr.strip() or "ostree failed to list imported Flatpak refs")
        app_ref = select_flatpak_ref(refs.stdout)
        checkout_root = Path(temp) / "checkout"
        checkout = subprocess.run(
            ["ostree", f"--repo={repo}", "checkout", app_ref, str(checkout_root)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            text=True,
        )
        if checkout.returncode != 0:
            raise SystemExit(checkout.stderr.strip() or "ostree failed to checkout Flatpak app ref")
        metadata = checkout_root / "metadata"
        files_root = checkout_root / "files"
        if not metadata.is_file():
            raise SystemExit("Flatpak metadata is missing")
        if not files_root.is_dir():
            raise SystemExit("Flatpak files tree is missing")
        validate_root_tree(
            files_root,
            args,
            distribution="flatpak",
            label="Flatpak",
            install_prefix=Path(""),
        )


def validate_desktop_and_manifest(
    desktop_bytes: bytes,
    manifest_bytes: bytes,
    *,
    args: argparse.Namespace,
    distribution: str,
) -> None:
    if not desktop_bytes:
        raise SystemExit("desktop entry is missing")
    if not manifest_bytes:
        raise SystemExit("package manifest is missing")
    try:
        desktop_fields = parse_desktop_entry(desktop_bytes.decode("utf-8"))
    except UnicodeDecodeError as error:
        raise SystemExit(f"desktop entry is not UTF-8: {error}") from error
    except ValueError as error:
        raise SystemExit(str(error)) from error
    desktop_errors = validate_desktop_entry(desktop_fields)
    if desktop_errors:
        raise SystemExit("; ".join(desktop_errors))
    try:
        manifest = json.loads(manifest_bytes.decode("utf-8"))
    except UnicodeDecodeError as error:
        raise SystemExit(f"package manifest is not UTF-8: {error}") from error
    except json.JSONDecodeError as error:
        raise SystemExit(f"package manifest is not valid JSON: {error}") from error
    manifest_errors = validate_manifest(
        manifest,
        require_remote_daemon=args.require_remote_daemon,
        require_swift_cli=args.require_swift_cli,
        distribution=distribution,
    )
    if manifest_errors:
        raise SystemExit("; ".join(manifest_errors))


def main() -> int:
    args = parse_args()
    if args.probe_remote_daemon:
        args.require_remote_daemon = True
    if not args.archive.is_file():
        raise SystemExit(f"archive not found: {args.archive}")

    suffix = args.archive.suffix.lower()
    if suffix == ".deb":
        validate_deb(args)
    elif suffix == ".appimage":
        validate_appimage(args)
    elif suffix == ".rpm":
        validate_rpm(args)
    elif suffix == ".flatpak":
        validate_flatpak(args)
    else:
        validate_tarball(args)

    print(f"Linux package valid: {args.archive}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
