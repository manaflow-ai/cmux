from __future__ import annotations

import json
import stat
import subprocess
import sys
from pathlib import Path


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
        "cmux-tui-darwin-arm64",
    )

    assert result.returncode == 0, result.stderr


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
    assert "unexpected" in result.stderr


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
    assert "executable" in result.stderr.lower()

