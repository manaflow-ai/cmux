from __future__ import annotations

import json
import platform
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest import mock



ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "cmux-tui/dist/scripts/validate_package_contract.py"
PYPI_BUILDER = ROOT / "cmux-tui/dist/scripts/package_pypi.py"

VERSION = "1.2.3"
NPM_TARGETS = {
    "cmux-tui-darwin-arm64": ("darwin", "arm64"),
    "cmux-tui-darwin-x64": ("darwin", "x64"),
    "cmux-tui-linux-x64": ("linux", "x64"),
    "cmux-tui-linux-arm64": ("linux", "arm64"),
}


def host_npm_target() -> str:
    system = platform.system().lower()
    machine = platform.machine().lower()
    if system == "linux":
        if machine in {"aarch64", "arm64"}:
            return "cmux-tui-linux-arm64"
        if machine in {"x86_64", "amd64"}:
            return "cmux-tui-linux-x64"
        raise RuntimeError(f"unsupported test host: {system}-{machine}")
    if system == "darwin":
        if machine in {"x86_64", "amd64"}:
            return "cmux-tui-darwin-x64"
        if machine in {"aarch64", "arm64"}:
            return "cmux-tui-darwin-arm64"
        raise RuntimeError(f"unsupported test host: {system}-{machine}")
    raise RuntimeError(f"unsupported test host: {system}-{machine}")


def write_executable(path: Path, output: str = "cmux-tui 1.2.3") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"#!/bin/sh\nprintf '%s\\n' '{output}'\n")
    path.chmod(0o755)


def make_npm_packages(root: Path) -> None:
    root.mkdir()
    for name, (os_name, cpu) in NPM_TARGETS.items():
        package = root / name
        package.mkdir()
        (package / "package.json").write_text(
            json.dumps(
                {
                    "name": name,
                    "version": VERSION,
                    "os": [os_name],
                    "cpu": [cpu],
                    "files": ["bin/cmux-tui", "bin/cmux-tui-hook"],
                }
            )
            + "\n"
        )
        write_executable(package / "bin/cmux-tui")
        write_executable(package / "bin/cmux-tui-hook", "cmux-tui-hook 1.2.3")

    launcher = root / "cmux"
    launcher.mkdir()
    (launcher / "package.json").write_text(
        json.dumps(
            {
                "name": "cmux",
                "version": VERSION,
                "bin": {"cmux": "bin/cmux.js"},
                "files": ["bin/cmux.js"],
                "optionalDependencies": {
                    name: VERSION for name in NPM_TARGETS
                },
            }
        )
        + "\n"
    )
    write_executable(
        launcher / "bin/cmux.js",
        "cmux launcher 1.2.3",
    )


def make_pypi_wheels(tmp_path: Path) -> Path:
    binaries = tmp_path / "binaries"
    binaries.mkdir()
    for target in (
        "aarch64-apple-darwin",
        "x86_64-apple-darwin",
        "x86_64-unknown-linux-musl",
        "aarch64-unknown-linux-musl",
    ):
        write_executable(binaries / f"cmux-tui-{target}")
        write_executable(binaries / f"cmux-tui-hook-{target}", "hook")

    wheels = tmp_path / "wheels"
    result = subprocess.run(
        [
            sys.executable,
            str(PYPI_BUILDER),
            "--binaries-dir",
            str(binaries),
            "--version",
            VERSION,
            "--out",
            str(wheels),
        ],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    return wheels


def run_validator(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(VALIDATOR), *args],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )


def test_npm_contract_packs_and_installs_matching_platform(tmp_path: Path) -> None:
    packages = tmp_path / "npm-packages"
    make_npm_packages(packages)

    result = run_validator(
        "--npm-packages",
        str(packages),
        "--version",
        VERSION,
        "--install-npm-package",
        host_npm_target(),
    )

    assert result.returncode == 0, result.stderr


def test_host_npm_target_rejects_unknown_architecture() -> None:
    for system in ("Linux", "Darwin"):
        with mock.patch.object(platform, "system", return_value=system), mock.patch.object(
            platform, "machine", return_value="riscv64"
        ):
            try:
                host_npm_target()
            except RuntimeError as error:
                assert str(error) == f"unsupported test host: {system.lower()}-riscv64"
            else:
                raise AssertionError("unknown host architecture must raise RuntimeError")


def test_npm_contract_rejects_missing_hook(tmp_path: Path) -> None:
    packages = tmp_path / "npm-packages"
    make_npm_packages(packages)
    (packages / "cmux-tui-linux-x64/bin/cmux-tui-hook").unlink()

    result = run_validator(
        "--npm-packages",
        str(packages),
        "--version",
        VERSION,
    )

    assert result.returncode != 0
    assert "cmux-tui-hook" in result.stderr


def test_npm_contract_rejects_extra_file(tmp_path: Path) -> None:
    packages = tmp_path / "npm-packages"
    make_npm_packages(packages)
    extra = packages / "cmux-tui-linux-x64/bin/extra"
    write_executable(extra)

    result = run_validator(
        "--npm-packages",
        str(packages),
        "--version",
        VERSION,
    )

    assert result.returncode != 0
    assert "mismatch" in result.stderr


def test_pypi_contract_requires_all_six_wheels_and_metadata(tmp_path: Path) -> None:
    wheels = make_pypi_wheels(tmp_path)

    result = run_validator(
        "--pypi-wheels",
        str(wheels),
        "--version",
        VERSION,
    )

    assert result.returncode == 0, result.stderr

    wheel = next(wheels.glob("*macosx_11_0_arm64.whl"))
    wheel.unlink()
    result = run_validator(
        "--pypi-wheels",
        str(wheels),
        "--version",
        VERSION,
    )
    assert result.returncode != 0
    assert "expected" in result.stderr.lower()


def test_pypi_contract_rejects_non_executable_hook(tmp_path: Path) -> None:
    wheels = make_pypi_wheels(tmp_path)
    wheel = next(wheels.glob("*.whl"))

    import zipfile

    rewritten = tmp_path / "rewritten.whl"
    with zipfile.ZipFile(wheel) as source, zipfile.ZipFile(rewritten, "w") as target:
        for info in source.infolist():
            data = source.read(info.filename)
            if info.filename == "cmux_tui/bin/cmux-tui-hook":
                info.external_attr = (stat.S_IFREG | 0o644) << 16
            target.writestr(info, data)
    wheel.unlink()
    rewritten.rename(wheel)

    result = run_validator(
        "--pypi-wheels",
        str(wheels),
        "--version",
        VERSION,
    )
    assert result.returncode != 0
    assert "mode" in result.stderr.lower()


def main() -> None:
    tests = (
        test_npm_contract_packs_and_installs_matching_platform,
        lambda _directory: test_host_npm_target_rejects_unknown_architecture(),
        test_npm_contract_rejects_missing_hook,
        test_npm_contract_rejects_extra_file,
        test_pypi_contract_requires_all_six_wheels_and_metadata,
        test_pypi_contract_rejects_non_executable_hook,
    )
    for test in tests:
        with tempfile.TemporaryDirectory(prefix="cmux-tui-contract-test-") as directory:
            test(Path(directory))


if __name__ == "__main__":
    main()
