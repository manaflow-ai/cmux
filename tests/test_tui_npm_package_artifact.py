from __future__ import annotations

import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "cmux-tui/dist/scripts/package_npm_artifact.py"
EXECUTABLES = (
    "cmux-tui-darwin-arm64/bin/cmux-tui",
    "cmux-tui-darwin-x64/bin/cmux-tui",
    "cmux-tui-linux-x64/bin/cmux-tui",
    "cmux-tui-linux-arm64/bin/cmux-tui",
    "cmux/bin/cmux.js",
)


def run_helper(*args: object) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *(str(arg) for arg in args)],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )


def test_archive_round_trip_preserves_package_executables(tmp_path: Path) -> None:
    packages = tmp_path / "npm-packages"
    for relative_path in EXECUTABLES:
        executable = packages / relative_path
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text("#!/bin/sh\nexit 0\n")
        executable.chmod(0o755)

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


def main() -> None:
    with tempfile.TemporaryDirectory() as directory:
        test_archive_round_trip_preserves_package_executables(Path(directory))
    with tempfile.TemporaryDirectory() as directory:
        test_extract_rejects_paths_outside_package_root(Path(directory))
    test_publish_workflows_restore_the_mode_preserving_archive()


if __name__ == "__main__":
    main()
