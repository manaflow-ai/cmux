from __future__ import annotations

import shutil
import stat
import subprocess
import sys
import tempfile
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "cmux-tui/dist/scripts/package_npm_artifact.py"
EXECUTABLES = (
    "cmux-tui-darwin-arm64/bin/cmux-tui",
    "cmux-tui-darwin-arm64/bin/cmux-tui-hook",
    "cmux-tui-darwin-x64/bin/cmux-tui",
    "cmux-tui-darwin-x64/bin/cmux-tui-hook",
    "cmux-tui-linux-x64/bin/cmux-tui",
    "cmux-tui-linux-x64/bin/cmux-tui-hook",
    "cmux-tui-linux-arm64/bin/cmux-tui",
    "cmux-tui-linux-arm64/bin/cmux-tui-hook",
    "cmux/bin/cmux.js",
    "cmux-relay-darwin-arm64/bin/cmux-relay",
    "cmux-relay-darwin-x64/bin/cmux-relay",
    "cmux-relay-linux-x64/bin/cmux-relay",
    "cmux-relay-linux-arm64/bin/cmux-relay",
    "cmux-relay/bin/cmux-relay.js",
)

VERSION = "1.2.3"
TARGETS = {
    "cmux-tui-darwin-arm64": ("darwin", "arm64"),
    "cmux-tui-darwin-x64": ("darwin", "x64"),
    "cmux-tui-linux-x64": ("linux", "x64"),
    "cmux-tui-linux-arm64": ("linux", "arm64"),
}
RELAY_TARGETS = {
    name.replace("cmux-tui", "cmux-relay"): value
    for name, value in TARGETS.items()
}


def run_helper(*args: object) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *(str(arg) for arg in args)],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )


def write_relay_launcher_fixture(path: Path) -> None:
    """Write a launcher fixture with the npx autostart safety rule."""

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        r'''#!/usr/bin/env node
"use strict";

function isEphemeralNpxPath(value) {
  return value
    .split(/[\\/]+/)
    .some((component) => component.toLowerCase() === "_npx");
}

const executable = process.env.CMUX_RELAY_FIXTURE_EXECUTABLE || __filename;
if (process.argv.slice(2).includes("--autostart") && isEphemeralNpxPath(executable)) {
  console.error(
    "Install cmux-relay globally (npm install --global cmux-relay) before --autostart.",
  );
  process.exit(2);
}
process.stdout.write("cmux relay launcher 1.2.3\n");
''',
        encoding="utf-8",
    )
    path.chmod(0o755)


def test_archive_round_trip_preserves_package_executables(tmp_path: Path) -> None:
    packages = tmp_path / "npm-packages"
    for name, (os_name, cpu) in TARGETS.items():
        package = packages / name
        package.mkdir(parents=True, exist_ok=True)
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
        for binary in ("cmux-tui", "cmux-tui-hook"):
            executable = package / "bin" / binary
            executable.parent.mkdir(parents=True, exist_ok=True)
            executable.write_text("#!/bin/sh\nexit 0\n")
            executable.chmod(0o755)

    launcher = packages / "cmux"
    launcher.mkdir(parents=True, exist_ok=True)
    (launcher / "package.json").write_text(
        json.dumps(
            {
                "name": "cmux",
                "version": VERSION,
                "bin": {"cmux": "bin/cmux.js"},
                "files": ["bin/cmux.js"],
                "optionalDependencies": {
                    name: VERSION for name in TARGETS
                },
            }
        )
        + "\n"
    )
    launcher_bin = launcher / "bin" / "cmux.js"
    launcher_bin.parent.mkdir(parents=True, exist_ok=True)
    launcher_bin.write_text("#!/bin/sh\nexit 0\n")
    launcher_bin.chmod(0o755)

    for name, (os_name, cpu) in RELAY_TARGETS.items():
        package = packages / name
        package.mkdir(parents=True, exist_ok=True)
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
        executable = package / "bin" / "cmux-relay"
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text("#!/bin/sh\nexit 0\n")
        executable.chmod(0o755)

    relay_launcher = packages / "cmux-relay"
    relay_launcher.mkdir(parents=True, exist_ok=True)
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
    relay_launcher_bin = relay_launcher / "bin" / "cmux-relay.js"
    relay_launcher_bin.parent.mkdir(parents=True, exist_ok=True)
    write_relay_launcher_fixture(relay_launcher_bin)

    archive = tmp_path / "npm-packages.tar.gz"
    created = run_helper(
        "create", "--packages-dir", packages, "--archive", archive
    )
    assert created.returncode == 0, created.stderr

    # GitHub artifact transfer may normalize the outer file mode. The archive
    # must still restore executable package entries after download.
    archive.chmod(0o644)
    shutil.rmtree(packages)

    extracted = run_helper("extract", "--archive", archive, "--out", tmp_path)
    assert extracted.returncode == 0, extracted.stderr
    for relative_path in EXECUTABLES:
        mode = (packages / relative_path).stat().st_mode
        assert mode & stat.S_IXUSR, relative_path


def test_extract_rejects_paths_outside_package_root(tmp_path: Path) -> None:
    archive = tmp_path / "npm-packages.tar.gz"
    # Build the hostile archive without relying on the helper under test.
    import io
    import tarfile

    with tarfile.open(archive, "w:gz") as tar:
        info = tarfile.TarInfo("../outside")
        contents = b"unexpected"
        info.size = len(contents)
        tar.addfile(info, io.BytesIO(contents))

    extracted = run_helper("extract", "--archive", archive, "--out", tmp_path)
    assert extracted.returncode != 0
    assert not (tmp_path.parent / "outside").exists()


def test_publish_workflows_restore_the_mode_preserving_archive() -> None:
    build = (ROOT / ".github/workflows/cmux-tui-build-package.yml").read_text()
    stable = (ROOT / ".github/workflows/tui-publish-npm.yml").read_text()
    nightly = (ROOT / ".github/workflows/cmux-tui-nightly.yml").read_text()

    assert "package_npm_artifact.py create" in build
    assert "path: dist/npm-packages.tar.gz" in build
    for workflow in (stable, nightly):
        assert "package_npm_artifact.py extract" in workflow
        assert "--archive dist/npm-packages.tar.gz" in workflow


def test_publish_workflows_smoke_install_machine_relay() -> None:
    workflows = (
        ROOT / ".github/workflows/cmux-tui-build-package.yml",
        ROOT / ".github/workflows/tui-publish-npm.yml",
        ROOT / ".github/workflows/cmux-tui-nightly.yml",
    )
    for workflow_path in workflows:
        workflow = workflow_path.read_text()
        assert "--install-npm-relay-package cmux-relay-linux-x64" in workflow or (
            "--install-npm-relay-package \"$relay_install_target\"" in workflow
        ), workflow_path


def test_pypi_build_runs_full_wheel_contract_before_smoke() -> None:
    build = (ROOT / ".github/workflows/cmux-tui-build-package.yml").read_text()
    validator = "python3 cmux-tui/dist/scripts/validate_package_contract.py"
    assert validator in build
    contract = build.index("--pypi-wheels dist/pypi-wheels")
    smoke = build.index("for wheel in dist/pypi-wheels/*.whl")
    assert contract < smoke
    assert '--version \"$PYPI_VERSION\"' in build


def main() -> None:
    with tempfile.TemporaryDirectory() as directory:
        test_archive_round_trip_preserves_package_executables(Path(directory))
    with tempfile.TemporaryDirectory() as directory:
        test_extract_rejects_paths_outside_package_root(Path(directory))
    test_publish_workflows_restore_the_mode_preserving_archive()
    test_publish_workflows_smoke_install_machine_relay()


if __name__ == "__main__":
    main()
