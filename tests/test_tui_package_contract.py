from __future__ import annotations

import json
import os
import platform
import shutil
import signal
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
RELAY_TARGETS = {
    name.replace("cmux-tui", "cmux-relay"): value
    for name, value in NPM_TARGETS.items()
}

RELAY_LAUNCHER = ROOT / "cmux-tui/dist/npm/cmux-relay/bin/cmux-relay.js"


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


def write_relay_launcher_fixture(path: Path) -> None:
    """Write a launcher fixture that resolves and forwards to its platform binary."""

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        r'''#!/usr/bin/env node
"use strict";

const { spawnSync } = require("child_process");

function isEphemeralNpxPath(value) {
  return value
    .split(/[\\/]+/)
    .some((component) => component.toLowerCase() === "_npx");
}

const packages = {
  "darwin-arm64": "cmux-relay-darwin-arm64",
  "darwin-x64": "cmux-relay-darwin-x64",
  "linux-x64": "cmux-relay-linux-x64",
  "linux-arm64": "cmux-relay-linux-arm64",
};
const pkg = packages[`${process.platform}-${process.arch}`];
const executable = process.env.CMUX_RELAY_FIXTURE_EXECUTABLE || __filename;
if (process.argv.slice(2).includes("--autostart") && isEphemeralNpxPath(executable)) {
  console.error(
    "Install cmux-relay globally (npm install --global cmux-relay) before --autostart.",
  );
  process.exit(2);
}
const binary = require.resolve(`${pkg}/bin/cmux-relay`);
const result = spawnSync(binary, process.argv.slice(2), { stdio: "inherit" });
if (result.signal) process.kill(process.pid, result.signal);
process.exit(result.status === null ? 1 : result.status);
''',
        encoding="utf-8",
    )
    path.chmod(0o755)


def write_relay_binary_fixture(path: Path) -> None:
    """Write a deterministic stand-in for the generated Rust relay binary."""

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        r'''#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const args = process.argv.slice(2);

if (args.includes("--version")) {
  process.stdout.write("0.1.0\n");
  process.exit(0);
}

if (args.includes("--status")) {
  const configFlag = args.indexOf("--config");
  const configPath = configFlag >= 0 ? args[configFlag + 1] : path.join(
    process.env.XDG_CONFIG_HOME || path.join(process.env.HOME || ".", ".config"),
    "chatmux-relay",
    "config.json",
  );
  try {
    const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
    if (!config.deviceId || !config.token) throw new Error("incomplete");
    process.stdout.write(`Paired as ${config.name || ""} (${config.deviceId})\n`);
    process.exit(0);
  } catch {
    process.stdout.write("Not paired\n");
    process.exit(1);
  }
}

process.exit(0);
''',
        encoding="utf-8",
    )
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

    for name, (os_name, cpu) in RELAY_TARGETS.items():
        package = root / name
        package.mkdir()
        (package / "package.json").write_text(
            json.dumps(
                {
                    "name": name,
                    "version": VERSION,
                    "os": [os_name],
                    "cpu": [cpu],
                    "files": ["bin/cmux-relay"],
                }
            )
            + "\n"
        )
        write_relay_binary_fixture(package / "bin/cmux-relay")

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

    relay_launcher = root / "cmux-relay"
    relay_launcher.mkdir()
    (relay_launcher / "package.json").write_text(
        json.dumps(
            {
                "name": "cmux-relay",
                "version": VERSION,
                "bin": {"cmux-relay": "bin/cmux-relay.js"},
                "files": ["bin/cmux-relay.js"],
                "optionalDependencies": {
                    name: VERSION for name in RELAY_TARGETS
                },
            }
        )
        + "\n"
    )
    write_relay_launcher_fixture(relay_launcher / "bin/cmux-relay.js")


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


def test_npm_relay_contract_installs_and_runs_isolated_smoke(tmp_path: Path) -> None:
    packages = tmp_path / "npm-packages"
    make_npm_packages(packages)

    result = run_validator(
        "--npm-packages",
        str(packages),
        "--version",
        VERSION,
        "--install-npm-relay-package",
        host_npm_target().replace("cmux-tui", "cmux-relay"),
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


def test_relay_launcher_preserves_native_signal_exit_status(tmp_path: Path) -> None:
    """The npm shim must die by the same signal as the native relay."""

    if os.name == "nt":
        return

    launcher_root = tmp_path / "launcher"
    launcher = launcher_root / "cmux-relay.js"
    launcher_root.mkdir()
    shutil.copy2(RELAY_LAUNCHER, launcher)
    launcher.chmod(0o755)

    relay_package = launcher_root / "node_modules" / host_npm_target().replace(
        "cmux-tui", "cmux-relay"
    )
    relay_binary = relay_package / "bin" / "cmux-relay"
    relay_binary.parent.mkdir(parents=True)
    relay_binary.write_text(
        "#!/usr/bin/env node\nprocess.kill(process.pid, 'SIGTERM');\n",
        encoding="utf-8",
    )
    relay_binary.chmod(0o755)

    result = subprocess.run(
        ["node", str(launcher)],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == -signal.SIGTERM, result.stderr


def test_pypi_contract_requires_all_six_wheels_and_metadata(tmp_path: Path) -> None:
    wheels = make_pypi_wheels(tmp_path)

    result = run_validator(
        "--pypi-wheels",
        str(wheels),
        "--version",
        VERSION,
    )

    assert result.returncode == 0, result.stderr

    import zipfile

    wheel = next(wheels.glob("*.whl"))
    dist_info = f"cmux-{VERSION}.dist-info"
    with zipfile.ZipFile(wheel) as archive:
        metadata = archive.read(f"{dist_info}/METADATA").decode("utf-8")
    assert "Description-Content-Type: text/markdown\n" in metadata
    description = metadata.split("\n\n", 1)[1].strip()
    assert description.startswith("# cmux\n")
    assert "python -m pip install cmux" in description

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
        test_npm_relay_contract_installs_and_runs_isolated_smoke,
        lambda _directory: test_host_npm_target_rejects_unknown_architecture(),
        test_npm_contract_rejects_missing_hook,
        test_npm_contract_rejects_extra_file,
        test_relay_launcher_preserves_native_signal_exit_status,
        test_pypi_contract_requires_all_six_wheels_and_metadata,
        test_pypi_contract_rejects_non_executable_hook,
    )
    for test in tests:
        with tempfile.TemporaryDirectory(prefix="cmux-tui-contract-test-") as directory:
            test(Path(directory))


if __name__ == "__main__":
    main()
