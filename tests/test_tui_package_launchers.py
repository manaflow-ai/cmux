from __future__ import annotations

import os
import platform
import runpy
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VERIFY_SCRIPT = ROOT / "cmux-tui/dist/scripts/verify_artifact_identity.py"
NPM_LAUNCHER = ROOT / "cmux-tui/dist/npm/cmux/bin/cmux.js"
PYPI_PACKAGER = ROOT / "cmux-tui/dist/scripts/package_pypi.py"
EXPECTED_IDENTITY = "cmux-tui 1.2.3 (build123; ghostty ghost456)"

NPM_PACKAGE_BY_PLATFORM = {
    ("darwin", "arm64"): "cmux-tui-darwin-arm64",
    ("darwin", "x86_64"): "cmux-tui-darwin-x64",
    ("linux", "x86_64"): "cmux-tui-linux-x64",
    ("linux", "aarch64"): "cmux-tui-linux-arm64",
}

WHEEL_TAG_BY_PLATFORM = {
    ("darwin", "arm64"): "macosx_11_0_arm64",
    ("darwin", "x86_64"): "macosx_10_12_x86_64",
    ("linux", "x86_64"): "manylinux_2_17_x86_64.manylinux2014_x86_64",
    ("linux", "aarch64"): "manylinux_2_17_aarch64.manylinux2014_aarch64",
}

RUST_TARGETS = (
    "aarch64-apple-darwin",
    "x86_64-apple-darwin",
    "x86_64-unknown-linux-gnu",
    "aarch64-unknown-linux-gnu",
)


def test_pypi_fixture_targets_match_packager() -> None:
    packager = runpy.run_path(str(PYPI_PACKAGER))
    declared = tuple(target.rust_target for target in packager["TARGETS"])
    assert RUST_TARGETS == declared


def normalized_platform() -> tuple[str, str]:
    machine = platform.machine().lower()
    if machine in {"amd64", "x64"}:
        machine = "x86_64"
    elif machine == "arm64":
        machine = "arm64"
    return sys.platform, machine


def write_executable(path: Path, body: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"#!/bin/sh\n{body}\n")
    path.chmod(0o755)


def run(
    command: list[str | Path],
    *,
    cwd: Path = ROOT,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(part) for part in command],
        cwd=cwd,
        env=env,
        check=False,
        capture_output=True,
        text=True,
    )


def test_identity_verifier_executes_artifact_and_rejects_mismatch(
    tmp_path: Path,
) -> None:
    binary = tmp_path / "cmux-tui"
    write_executable(binary, f"printf '%s\\n' '{EXPECTED_IDENTITY}'")
    arguments = [
        sys.executable,
        VERIFY_SCRIPT,
        "--binary",
        binary,
        "--version",
        "1.2.3",
        "--build-commit",
        "build123",
        "--ghostty-commit",
        "ghost456",
    ]

    accepted = run(arguments)
    assert accepted.returncode == 0, accepted.stderr

    rejected = run([*arguments[:-1], "wrong-ghostty"])
    assert rejected.returncode != 0
    assert "identity mismatch" in rejected.stderr


def test_npm_launcher_preserves_replayable_invocation(tmp_path: Path) -> None:
    key = normalized_platform()
    package = NPM_PACKAGE_BY_PLATFORM.get(key)
    assert package is not None, f"unsupported test platform: {key}"
    node = shutil.which("node")
    assert node is not None, "node is required to exercise the npm launcher"

    launcher = tmp_path / "node_modules/cmux/bin/cmux.js"
    launcher.parent.mkdir(parents=True)
    shutil.copyfile(NPM_LAUNCHER, launcher)
    launcher.chmod(0o755)
    (launcher.parent.parent / "package.json").write_text(
        '{"name":"cmux","version":"1.2.3"}\n'
    )
    package_root = tmp_path / "node_modules" / package
    package_root.mkdir(parents=True)
    (package_root / "package.json").write_text(
        f'{{"name":"{package}","version":"1.2.3"}}\n'
    )
    write_executable(
        package_root / "bin/cmux-tui",
        "printf '%s\\n' \"$CMUX_TUI_LAUNCHER_COMMAND\"",
    )

    one_shot_env = os.environ.copy()
    one_shot_env["npm_command"] = "exec"
    one_shot = run([node, launcher], cwd=tmp_path, env=one_shot_env)
    assert one_shot.returncode == 0, one_shot.stderr
    assert one_shot.stdout.strip() == "npx cmux@1.2.3"

    installed_env = os.environ.copy()
    installed_env.pop("npm_command", None)
    installed = run([node, launcher], cwd=tmp_path, env=installed_env)
    assert installed.returncode == 0, installed.stderr
    assert installed.stdout.strip() == "cmux"


def test_pypi_launcher_preserves_uvx_invocation(tmp_path: Path) -> None:
    key = normalized_platform()
    wheel_tag = WHEEL_TAG_BY_PLATFORM.get(key)
    assert wheel_tag is not None, f"unsupported test platform: {key}"

    binaries = tmp_path / "binaries"
    for target in RUST_TARGETS:
        write_executable(
            binaries / f"cmux-tui-{target}",
            "printf '%s\\n' \"$CMUX_TUI_LAUNCHER_COMMAND\"",
        )

    wheels = tmp_path / "wheels"
    packaged = run(
        [
            sys.executable,
            PYPI_PACKAGER,
            "--binaries-dir",
            binaries,
            "--version",
            "1.2.3",
            "--out",
            wheels,
        ]
    )
    assert packaged.returncode == 0, packaged.stderr

    wheel = wheels / f"cmux-1.2.3-py3-none-{wheel_tag}.whl"
    installed = tmp_path / "installed"
    with zipfile.ZipFile(wheel) as archive:
        archive.extractall(installed)
    (installed / "cmux_tui/bin/cmux-tui").chmod(0o755)

    environment = os.environ.copy()
    environment["PYTHONPATH"] = str(installed)
    environment["CMUX_TUI_LAUNCHER_COMMAND"] = "uvx cmux==0.9.0"
    launched = run(
        [
            sys.executable,
            "-c",
            (
                "import sys; "
                "sys.argv = ['/tmp/uv/archive-v0/hash/bin/cmux']; "
                "from cmux_tui._main import main; "
                "main()"
            ),
        ],
        env=environment,
    )
    assert launched.returncode == 0, launched.stderr
    assert launched.stdout.strip() == "uvx cmux==1.2.3"


def main() -> None:
    import tempfile

    test_pypi_fixture_targets_match_packager()
    with tempfile.TemporaryDirectory() as directory:
        test_identity_verifier_executes_artifact_and_rejects_mismatch(
            Path(directory)
        )
    with tempfile.TemporaryDirectory() as directory:
        test_npm_launcher_preserves_replayable_invocation(Path(directory))
    with tempfile.TemporaryDirectory() as directory:
        test_pypi_launcher_preserves_uvx_invocation(Path(directory))


if __name__ == "__main__":
    main()
