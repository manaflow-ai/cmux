#!/usr/bin/env python3
"""Run exact CMUX fleet role acceptance and emit Glaeda enrollment evidence."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

SCHEMA = "glaeda-cmux-fleet-acceptance-evidence/v1"
MAX_LOG_BYTES = 64 * 1024
MAX_RECEIPT_BYTES = 16 * 1024
MAX_COMMAND_OUTPUT_BYTES = 16 * 1024
SHA256_RE = re.compile(r"sha256:[0-9a-f]{64}\Z")
COMMIT_RE = re.compile(r"[0-9a-f]{40}\Z")
NODE_RE = re.compile(r"cmux-[a-z0-9][a-z0-9-]{2,59}\Z")


class AcceptanceError(RuntimeError):
    pass


def canonical(value: object) -> bytes:
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)
        + "\n"
    ).encode()


def sha256(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def command(name: str) -> str:
    value = shutil.which(name)
    if value is None:
        raise AcceptanceError(f"required command is missing: {name}")
    return os.path.abspath(value)


def child_environment() -> dict[str, str]:
    environment = {
        "LC_ALL": "C",
        "PATH": os.environ.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin"),
    }
    for name in ("HOME", "CARGO_HOME", "RUSTUP_HOME", "DEVELOPER_DIR"):
        value = os.environ.get(name)
        if value:
            environment[name] = value
    return environment


def run_text(argv: list[str], cwd: Path, timeout: int = 30) -> str:
    result = subprocess.run(
        argv,
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout,
        check=False,
        env=child_environment(),
    )
    if len(result.stdout.encode("utf-8", errors="replace")) > MAX_COMMAND_OUTPUT_BYTES:
        raise AcceptanceError(
            f"command output is too large: {Path(argv[0]).name}"
        )
    if result.returncode != 0:
        raise AcceptanceError(f"command failed: {Path(argv[0]).name}")
    return result.stdout.strip()


def run_group(
    argv: list[str],
    cwd: Path,
    timeout: int,
    extra_env: dict[str, str] | None = None,
) -> tuple[bool, bool, bytes]:
    environment = child_environment()
    if extra_env:
        environment.update(extra_env)
    with tempfile.TemporaryFile() as output:
        child = subprocess.Popen(
            argv,
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=output,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            env=environment,
        )
        timed_out = False
        try:
            code = child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.wait()
            code = 124
        try:
            os.killpg(child.pid, 0)
        except ProcessLookupError:
            settled = True
        except PermissionError:
            settled = False
        else:
            settled = False
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        output.seek(0, os.SEEK_END)
        size = output.tell()
        output.seek(max(0, size - MAX_LOG_BYTES))
        tail = output.read(MAX_LOG_BYTES)
    return code == 0 and not timed_out, settled, tail


def git_identity(root: Path, commit: str) -> None:
    if COMMIT_RE.fullmatch(commit) is None:
        raise AcceptanceError("commit must be an exact 40-hex object id")
    actual = run_text([command("git"), "rev-parse", "HEAD"], root)
    if actual != commit:
        raise AcceptanceError("checkout HEAD differs from requested commit")
    dirty = run_text(
        [
            command("git"),
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
        ],
        root,
    )
    if dirty:
        raise AcceptanceError("canonical checkout is dirty")


def cmux_required_zig_version(root: Path) -> str:
    match = re.search(
        r'^\s*\.minimum_zig_version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"',
        (root / "ghostty/build.zig.zon").read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    if match is None:
        raise AcceptanceError("Ghostty minimum Zig version is unavailable")
    return match.group(1)


def zig_version_compatible(actual: str, required: str) -> bool:
    def parse(value: str) -> tuple[int, int, int] | None:
        core = re.split(r"[-+]", value, maxsplit=1)[0]
        match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", core)
        if match is None:
            return None
        return tuple(int(part) for part in match.groups())

    actual_parts = parse(actual)
    required_parts = parse(required)
    return bool(
        actual_parts
        and required_parts
        and actual_parts[:2] == required_parts[:2]
        and actual_parts[2] >= required_parts[2]
    )


def cmux_diff_rust_toolchain(root: Path) -> str:
    match = re.search(
        r'^\s*channel\s*=\s*"([^"]+)"',
        (root / "Native/DiffSidecar/rust-toolchain.toml").read_text(
            encoding="utf-8"
        ),
        re.MULTILINE,
    )
    if match is None:
        raise AcceptanceError("CMUX DiffSidecar Rust toolchain is unavailable")
    return match.group(1)


def mac_toolchain(root: Path) -> str:
    pin = (root / ".xcode-version").read_text(encoding="utf-8").strip()
    xcode = run_text([command("xcodebuild"), "-version"], root)
    xcrun = command("xcrun")
    sdk = run_text(
        [xcrun, "--sdk", "macosx", "--show-sdk-version"],
        root,
    )
    metal = run_text([xcrun, "metal", "--version"], root)
    git = run_text([command("git"), "--version"], root)
    zig = run_text([command("zig"), "version"], root)
    zig_required = cmux_required_zig_version(root)
    rustup = command("rustup")
    rustup_version = run_text([rustup, "--version"], root)
    cargo = run_text([command("cargo"), "--version"], root)
    rustc = run_text([command("rustc"), "--version"], root)
    diff_rust = cmux_diff_rust_toolchain(root)
    diff_cargo = run_text(
        [rustup, "run", diff_rust, "cargo", "--version"],
        root,
    )
    diff_rustc = run_text(
        [rustup, "run", diff_rust, "rustc", "--version"],
        root,
    )
    match = re.search(r"^Xcode\s+(\d+(?:\.\d+)*)$", xcode, re.MULTILINE)
    if (
        pin != "26.0"
        or match is None
        or not match.group(1).startswith("26")
        or not sdk.startswith("26")
        or not zig_version_compatible(zig, zig_required)
        or not rustup_version.startswith("rustup ")
        or not cargo.startswith("cargo ")
        or not rustc.startswith("rustc ")
        or not diff_cargo.startswith("cargo ")
        or not diff_rustc.startswith("rustc ")
        or not metal
    ):
        raise AcceptanceError("CMUX pinned native toolchain generation is unavailable")
    return sha256(
        canonical(
            {
                "cmuxXcodePin": pin,
                "xcodeVersion": match.group(1),
                "macosSdkVersion": sdk,
                "gitVersion": git,
                "metalVersion": metal,
                "zigVersion": zig,
                "zigRequired": zig_required,
                "rustupVersion": rustup_version,
                "cargoVersion": cargo,
                "rustcVersion": rustc,
                "diffRustToolchain": diff_rust,
                "diffCargoVersion": diff_cargo,
                "diffRustcVersion": diff_rustc,
            }
        )
    )


def linux_toolchain(root: Path) -> str:
    values: dict[str, str] = {}
    for line in Path("/etc/os-release").read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value.strip().strip('"')
    git = run_text([command("git"), "--version"], root)
    python = run_text([command("python3"), "--version"], root)
    major = int(platform.release().split(".", 1)[0])
    return sha256(
        canonical(
            {
                "distribution": f"{values.get('ID', '')}-{values.get('VERSION_ID', '')}",
                "kernelMajor": major,
                "gitVersion": git,
                "pythonVersion": python,
            }
        )
    )


def workload_generation() -> str:
    return sha256(Path(__file__).read_bytes())


def print_failure_tail(tail: bytes) -> None:
    if tail:
        sys.stderr.buffer.write(tail[-8192:])
        if not tail.endswith(b"\n"):
            sys.stderr.buffer.write(b"\n")


def mac_accept(root: Path, commit: str) -> dict[str, str]:
    if platform.system() != "Darwin":
        raise AcceptanceError("macOS native-build acceptance requires Darwin")
    git_identity(root, commit)
    with tempfile.TemporaryDirectory(prefix="cmux-fleet-macos-") as temp:
        derived = Path(temp) / "DerivedData"
        private_home = Path(temp) / "home"
        private_tmp = Path(temp) / "tmp"
        private_home.mkdir()
        private_tmp.mkdir()
        original_home = Path(os.environ["HOME"]).resolve()
        cargo_home = Path(
            os.environ.get("CARGO_HOME", str(original_home / ".cargo"))
        ).resolve()
        rustup_home = Path(
            os.environ.get("RUSTUP_HOME", str(original_home / ".rustup"))
        ).resolve()
        ok, settled, tail = run_group(
            [
                command("xcodebuild"),
                "-project",
                "cmux.xcodeproj",
                "-scheme",
                "cmux",
                "-configuration",
                "Debug",
                "-destination",
                "platform=macOS",
                "-derivedDataPath",
                str(derived),
                "CODE_SIGNING_ALLOWED=NO",
                "clean",
                "build",
            ],
            root,
            3600,
            {
                "HOME": str(private_home),
                "TMPDIR": str(private_tmp),
                "CARGO_HOME": str(cargo_home),
                "RUSTUP_HOME": str(rustup_home),
            },
        )
        artifact = (
            derived
            / "Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV"
        )
        artifact_ok = artifact.is_file() and os.access(artifact, os.X_OK)
        semantic = False
        if artifact_ok:
            try:
                semantic = "Mach-O" in run_text(
                    [command("file"), "-b", str(artifact)],
                    root,
                )
            except AcceptanceError:
                semantic = False
        if not ok:
            print_failure_tail(tail)
    try:
        git_identity(root, commit)
        source_ok = True
    except AcceptanceError:
        source_ok = False
    return {
        "workload": "pass" if ok and source_ok else "fail",
        "semanticVerifier": "pass" if semantic else "fail",
        "artifact": "pass" if artifact_ok else "fail",
        "processSettlement": "pass" if settled else "fail",
    }


def linux_accept(root: Path, commit: str) -> dict[str, str]:
    if platform.system() != "Linux":
        raise AcceptanceError("Linux CI acceptance requires Linux")
    git_identity(root, commit)
    with tempfile.TemporaryDirectory(prefix="cmux-fleet-linux-") as temp:
        base = Path(temp)
        archive = base / "source.tar"
        work = base / "work"
        work.mkdir()
        archive_ok, archive_settled, tail = run_group(
            [
                command("git"),
                "archive",
                "--format=tar",
                "-o",
                str(archive),
                commit,
            ],
            root,
            120,
        )
        settled = archive_settled
        extract_ok = False
        if archive_ok:
            extract_ok, extract_settled, extract_tail = run_group(
                [command("tar"), "-xf", str(archive), "-C", str(work)],
                root,
                120,
            )
            settled = settled and extract_settled
            tail += extract_tail

        workload_ok = False
        semantic = False
        guard_output = b""
        if archive_ok and extract_ok:
            private_home = base / "home"
            private_home.mkdir()
            commands = (
                [command("bash"), "tests/test_ci_self_hosted_guard.sh"],
                [
                    command("python3"),
                    "-m",
                    "unittest",
                    "discover",
                    "-s",
                    "tests",
                    "-p",
                    "test_ci_linux_guard_routing.py",
                ],
            )
            results: list[bool] = []
            for index, argv in enumerate(commands):
                child_ok, child_settled, child_tail = run_group(
                    argv,
                    work,
                    300,
                    {
                        "HOME": str(private_home),
                        "TMPDIR": str(base),
                    },
                )
                if index == 0:
                    guard_output = child_tail
                results.append(child_ok)
                settled = settled and child_settled
                tail += child_tail
                if not child_ok:
                    break
            workload_ok = all(results) and len(results) == len(commands)
            semantic = (
                bool(results)
                and results[0]
                and b"PASS:" in guard_output
                and b"FAIL:" not in guard_output
            )

        artifact_ok = (
            extract_ok
            and (work / ".github/workflows/ci.yml").is_file()
            and (work / "tests/test_ci_self_hosted_guard.sh").is_file()
        )
        if not workload_ok:
            print_failure_tail(tail)
    try:
        git_identity(root, commit)
        source_ok = True
    except AcceptanceError:
        source_ok = False
    return {
        "workload": "pass" if workload_ok and source_ok else "fail",
        "semanticVerifier": "pass" if semantic else "fail",
        "artifact": "pass" if artifact_ok else "fail",
        "processSettlement": "pass" if settled else "fail",
    }


def evidence(args: argparse.Namespace) -> dict[str, object]:
    root = args.repo_root.resolve(strict=True)
    if not root.is_dir():
        raise AcceptanceError("repository root is invalid")
    if NODE_RE.fullmatch(args.node_id) is None:
        raise AcceptanceError("node id is invalid")
    if args.enrollment_generation < 1:
        raise AcceptanceError("enrollment generation is invalid")
    for label, value in (
        ("Glaeda generation", args.glaeda_generation),
        ("expected toolchain generation", args.toolchain_generation),
    ):
        if SHA256_RE.fullmatch(value) is None:
            raise AcceptanceError(f"{label} is invalid")

    actual_toolchain = (
        mac_toolchain(root)
        if args.role == "cmux_macos_native_build"
        else linux_toolchain(root)
    )
    if actual_toolchain != args.toolchain_generation:
        raise AcceptanceError(
            "observed toolchain generation differs from enrollment input"
        )
    checks = (
        mac_accept(root, args.commit)
        if args.role == "cmux_macos_native_build"
        else linux_accept(root, args.commit)
    )
    document = {
        "schema": SCHEMA,
        "nodeId": args.node_id,
        "enrollmentGeneration": args.enrollment_generation,
        "role": args.role,
        "source": {
            "repository": "manaflow-ai/cmux",
            "commit": args.commit,
        },
        "toolchainGeneration": actual_toolchain,
        "glaedaGeneration": args.glaeda_generation,
        "workloadGeneration": workload_generation(),
        "checks": checks,
    }
    if len(canonical(document)) > MAX_RECEIPT_BYTES:
        raise AcceptanceError("acceptance evidence exceeds size ceiling")
    return document


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    p.add_argument(
        "--role",
        required=True,
        choices=("cmux_macos_native_build", "cmux_linux_ci"),
    )
    p.add_argument("--repo-root", type=Path, default=Path.cwd())
    p.add_argument("--commit", required=True)
    p.add_argument("--node-id", required=True)
    p.add_argument("--enrollment-generation", type=int, required=True)
    p.add_argument("--glaeda-generation", required=True)
    p.add_argument("--toolchain-generation", required=True)
    p.add_argument("--output", type=Path)
    return p


def main() -> int:
    try:
        args = parser().parse_args()
        document = evidence(args)
        raw = canonical(document)
        if args.output:
            args.output.write_bytes(raw)
        sys.stdout.buffer.write(raw)
        return (
            0
            if all(value == "pass" for value in document["checks"].values())
            else 1
        )
    except (
        OSError,
        ValueError,
        AcceptanceError,
        subprocess.TimeoutExpired,
    ) as error:
        print(
            json.dumps({"error": str(error)}, sort_keys=True, separators=(",", ":")),
            file=sys.stderr,
        )
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
