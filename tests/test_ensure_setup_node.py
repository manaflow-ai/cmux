"""scripts/ci/ensure-setup-node.sh: node VERSION ends up on GITHUB_PATH even when setup-node left it off."""

from __future__ import annotations

import hashlib
import os
import platform
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/ensure-setup-node.sh"
VERSION = "24.22.1"
OS = {"Darwin": "darwin", "Linux": "linux"}.get(platform.system(), "")
ARCH = {"arm64": "arm64", "aarch64": "arm64", "x86_64": "x64"}.get(platform.machine(), "")


def fake_node(path: Path, version: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"#!/bin/sh\necho v{version}\n")
    path.chmod(0o755)


@unittest.skipUnless(OS and ARCH, "needs macOS or Linux on arm64 or x64")
class EnsureSetupNode(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.tmp)])
        self.cache = self.tmp / "toolcache"
        self.github_path = self.tmp / "github_path"
        self.github_path.write_text("")
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.dist = self.tmp / "dist" / f"v{VERSION}"
        self.dist.mkdir(parents=True)
        self.tool = self.cache / "node" / VERSION / ARCH

    def publish(self, *, corrupt: bool = False, reports: str = VERSION) -> None:
        name = f"node-v{VERSION}-{OS}-{ARCH}"
        staged = self.tmp / "staged"
        fake_node(staged / name / "bin" / "node", reports)
        tarball = self.dist / f"{name}.tar.gz"
        with tarfile.open(tarball, "w:gz") as archive:
            archive.add(staged / name, arcname=name)
        digest = hashlib.sha256(tarball.read_bytes()).hexdigest()
        if corrupt:
            digest = "0" * 64
        (self.dist / "SHASUMS256.txt").write_text(f"{'f' * 64}  other.tar.gz\n{digest}  {name}.tar.gz\n")

    def run_script(self) -> subprocess.CompletedProcess[str]:
        env = {"PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(self.tmp),
               "RUNNER_TOOL_CACHE": str(self.cache), "GITHUB_PATH": str(self.github_path),
               "ENSURE_NODE_DIST": (self.tmp / "dist").as_uri()}
        return subprocess.run(["bash", str(SCRIPT), VERSION], env=env, text=True, capture_output=True, timeout=60)

    def test_node_already_on_path_is_left_alone(self) -> None:
        fake_node(self.bin / "node", VERSION)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.github_path.read_text(), "")
        self.assertFalse(self.cache.exists())

    def test_a_complete_tool_cache_entry_goes_on_path_without_a_download(self) -> None:
        fake_node(self.bin / "node", "20.20.2")  # another node on PATH does not count
        fake_node(self.tool / "bin" / "node", VERSION)
        Path(f"{self.tool}.complete").touch()
        result = self.run_script()  # nothing published: a download would fail
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.github_path.read_text(), f"{self.tool}/bin\n")
        self.assertNotIn("installing it from nodejs.org", result.stdout)

    def test_a_missing_entry_is_downloaded_checked_and_cached(self) -> None:
        self.publish()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("installing it from nodejs.org", result.stdout)
        self.assertTrue(Path(f"{self.tool}.complete").exists())
        self.assertEqual(subprocess.run([str(self.tool / "bin" / "node")], text=True,
                                        capture_output=True).stdout.strip(), f"v{VERSION}")
        self.assertEqual(self.github_path.read_text(), f"{self.tool}/bin\n")

    def test_a_partial_entry_without_its_marker_is_replaced(self) -> None:
        (self.tool / "bin").mkdir(parents=True)
        (self.tool / "stale").write_text("left by a killed setup-node")
        self.publish()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.tool / "stale").exists())
        self.assertTrue((self.tool / "bin" / "node").exists())

    def test_a_complete_entry_that_cannot_run_is_replaced(self) -> None:
        self.tool.joinpath("bin").mkdir(parents=True)
        broken = self.tool / "bin" / "node"
        broken.write_text("#!/bin/sh\necho 'dyld: Library not loaded' >&2\nexit 7\n")
        broken.chmod(0o755)
        Path(f"{self.tool}.complete").touch()
        self.publish()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("installing it from nodejs.org", result.stdout)
        self.assertEqual(subprocess.run([str(broken)], text=True, capture_output=True).stdout.strip(), f"v{VERSION}")
        self.assertEqual(self.github_path.read_text(), f"{self.tool}/bin\n")

    def test_a_node_that_prints_the_version_but_fails_does_not_count(self) -> None:
        failing = "#!/bin/sh\necho v{v}\nexit 7\n".format(v=VERSION)
        (self.bin / "node").write_text(failing)
        (self.bin / "node").chmod(0o755)
        self.tool.joinpath("bin").mkdir(parents=True)
        (self.tool / "bin" / "node").write_text(failing)
        (self.tool / "bin" / "node").chmod(0o755)
        Path(f"{self.tool}.complete").touch()
        self.publish()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("installing it from nodejs.org", result.stdout)
        self.assertEqual(subprocess.run([str(self.tool / "bin" / "node")]).returncode, 0)
        self.assertEqual(self.github_path.read_text(), f"{self.tool}/bin\n")

    def test_a_download_that_fails_to_run_caches_nothing(self) -> None:
        name = f"node-v{VERSION}-{OS}-{ARCH}"
        staged = self.tmp / "staged" / name / "bin"
        staged.mkdir(parents=True)
        (staged / "node").write_text(f"#!/bin/sh\necho v{VERSION}\nexit 7\n")
        (staged / "node").chmod(0o755)
        tarball = self.dist / f"{name}.tar.gz"
        with tarfile.open(tarball, "w:gz") as archive:
            archive.add(staged.parent, arcname=name)
        digest = hashlib.sha256(tarball.read_bytes()).hexdigest()
        (self.dist / "SHASUMS256.txt").write_text(f"{digest}  {name}.tar.gz\n")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(Path(f"{self.tool}.complete").exists())
        self.assertEqual(self.github_path.read_text(), "")

    def test_a_complete_entry_of_another_version_is_replaced(self) -> None:
        fake_node(self.tool / "bin" / "node", "24.11.1")
        Path(f"{self.tool}.complete").touch()
        self.publish()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(subprocess.run([str(self.tool / "bin" / "node")], text=True,
                                        capture_output=True).stdout.strip(), f"v{VERSION}")

    def test_a_download_that_does_not_run_as_the_version_fails_and_caches_nothing(self) -> None:
        self.publish(reports="20.20.2")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not v24.22.1", result.stdout)
        self.assertFalse(Path(f"{self.tool}.complete").exists())
        self.assertEqual(self.github_path.read_text(), "")

    def test_a_checksum_mismatch_fails_and_caches_nothing(self) -> None:
        self.publish(corrupt=True)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match SHASUMS256.txt", result.stdout)
        self.assertFalse(Path(f"{self.tool}.complete").exists())
        self.assertEqual(self.github_path.read_text(), "")


if __name__ == "__main__":
    unittest.main()
