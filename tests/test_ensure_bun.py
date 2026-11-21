"""scripts/ci/ensure-bun.sh: bun VERSION ends up in BIN_DIR, from the PATH, the tool cache or a checked download."""

from __future__ import annotations

import hashlib
import os
import platform
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/ensure-bun.sh"
VERSION = "1.4.4"
OS = {"Darwin": "darwin", "Linux": "linux"}.get(platform.system(), "")
ARCH = {"arm64": "aarch64", "aarch64": "aarch64", "x86_64": "x64"}.get(platform.machine(), "")


def fake_bun(path: Path, version: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"#!/bin/sh\necho {version}\n")
    path.chmod(0o755)


@unittest.skipUnless(OS and ARCH, "needs macOS or Linux on arm64 or x64")
class EnsureBun(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.tmp)])
        self.cache = self.tmp / "toolcache"
        self.bin = self.tmp / "ci-bin"
        self.path_bin = self.tmp / "path-bin"
        self.path_bin.mkdir()
        self.dist = self.tmp / "dist" / f"bun-v{VERSION}"
        self.dist.mkdir(parents=True)

    def publish(self, *, corrupt: bool = False, reports: str = VERSION) -> None:
        name = f"bun-{OS}-{ARCH}"
        staged = self.tmp / "staged"
        fake_bun(staged / name / "bun", reports)
        archive = self.dist / f"{name}.zip"
        with zipfile.ZipFile(archive, "w") as z:
            z.write(staged / name / "bun", f"{name}/bun")
        digest = "0" * 64 if corrupt else hashlib.sha256(archive.read_bytes()).hexdigest()
        (self.dist / "SHASUMS256.txt").write_text(f"{'f' * 64}  other.zip\n{digest}  {name}.zip\n")

    def run_script(self) -> subprocess.CompletedProcess[str]:
        env = {"PATH": f"{self.path_bin}:/usr/bin:/bin", "HOME": str(self.tmp), "RUNNER_TOOL_CACHE": str(self.cache),
               "ENSURE_BUN_DIST": (self.tmp / "dist").as_uri()}
        return subprocess.run(["bash", str(SCRIPT), VERSION, str(self.bin)], env=env, text=True,
                              capture_output=True, timeout=60)

    def test_bun_of_the_major_on_path_is_linked_and_nothing_is_downloaded(self) -> None:
        for have in ("1.4.4", "1.4.5", "1.10.0"):
            with self.subTest(have=have):
                fake_bun(self.path_bin / "bun", have)
                done = self.run_script()  # no dist published: a download would fail
                self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
                self.assertEqual(subprocess.run([self.bin / "bun", "--version"], text=True,
                                                capture_output=True).stdout.strip(), have)

    def test_an_older_or_other_bun_is_not_taken(self) -> None:
        self.publish()
        for have in ("1.4.3", "1.3.14", "2.0.0", "1.4.4-rc.1", "garbage"):
            with self.subTest(have=have):
                fake_bun(self.path_bin / "bun", have)
                done = self.run_script()
                self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
                self.assertIn(f"bun {VERSION} from", done.stdout)
                self.assertEqual(subprocess.run([self.bin / "bun", "--version"], text=True,
                                                capture_output=True).stdout.strip(), VERSION)

    def test_a_download_is_checked_unpacked_and_kept_in_the_tool_cache(self) -> None:
        self.publish()
        done = self.run_script()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertTrue((self.cache / "bun" / VERSION / ARCH / "bun").is_file())
        (self.dist / "SHASUMS256.txt").unlink()  # the second run finds it cached: no network
        done = self.run_script()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("from " + str(self.cache), done.stdout)

    def test_a_download_that_does_not_match_its_checksum_fails(self) -> None:
        self.publish(corrupt=True)
        done = self.run_script()
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("does not match SHASUMS256.txt", done.stdout + done.stderr)
        self.assertFalse((self.bin / "bun").exists())

    def test_a_download_that_reports_another_version_fails(self) -> None:
        self.publish(reports="1.4.3")
        done = self.run_script()
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("not " + VERSION, done.stdout + done.stderr)


if __name__ == "__main__":
    unittest.main()
