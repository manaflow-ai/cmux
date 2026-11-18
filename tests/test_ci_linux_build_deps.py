"""The Linux musl dependency bootstrap honors the pool image contract."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/install-linux-build-deps.sh"
MARKER = "cmux-linux-build-deps-v1\nbinutils\nclang\nlibclang-dev\nmusl-tools\npkg-config\n"


class LinuxBuildDependenciesTest(unittest.TestCase):
    def run_script(self, marker: Path, bin_dir: Path) -> subprocess.CompletedProcess[str]:
        env = dict(os.environ)
        env.update({
            "CMUX_CI_LINUX_BUILD_DEPS_MARKER": str(marker),
            "PATH": f"{bin_dir}:{env['PATH']}",
        })
        return subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True)

    def test_image_marker_skips_sudo_after_verifying_packages(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "linux-build-deps"
            marker.write_text(MARKER, encoding="utf-8")
            calls = root / "calls"
            fake_bin = root / "bin"
            fake_bin.mkdir()
            (fake_bin / "dpkg-query").write_text(
                f"#!/bin/sh\necho dpkg-query \"$*\" >> {calls!s}\nprintf '%s' 'install ok installed'\n",
                encoding="utf-8",
            )
            (fake_bin / "sudo").write_text(
                f"#!/bin/sh\necho sudo \"$*\" >> {calls!s}\nexit 99\n",
                encoding="utf-8",
            )
            for command in fake_bin.iterdir():
                command.chmod(0o755)
            done = self.run_script(marker, fake_bin)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertNotIn("sudo ", calls.read_text(encoding="utf-8"))
            self.assertEqual(calls.read_text(encoding="utf-8").count("dpkg-query"), 5)

    def test_hosted_fallback_keeps_sudo_install_when_no_pool_marker_exists(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            calls = root / "calls"
            fake_bin = root / "bin"
            fake_bin.mkdir()
            (fake_bin / "sudo").write_text(
                f"#!/bin/sh\necho sudo \"$*\" >> {calls!s}\nexit 0\n",
                encoding="utf-8",
            )
            fake_bin.joinpath("sudo").chmod(0o755)
            done = self.run_script(root / "missing-marker", fake_bin)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(calls.read_text(encoding="utf-8").splitlines(), [
                "sudo apt-get update",
                "sudo apt-get install -y binutils clang libclang-dev musl-tools pkg-config",
            ])

    def test_invalid_marker_fails_closed_without_sudo(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "linux-build-deps"
            marker.write_text("cmux-linux-build-deps-v0\n", encoding="utf-8")
            calls = root / "calls"
            fake_bin = root / "bin"
            fake_bin.mkdir()
            (fake_bin / "sudo").write_text(
                f"#!/bin/sh\necho sudo \"$*\" >> {calls!s}\nexit 99\n",
                encoding="utf-8",
            )
            fake_bin.joinpath("sudo").chmod(0o755)
            done = self.run_script(marker, fake_bin)
            self.assertNotEqual(done.returncode, 0)
            self.assertIn("marker is invalid", done.stderr)
            self.assertFalse(calls.exists())


if __name__ == "__main__":
    unittest.main()
