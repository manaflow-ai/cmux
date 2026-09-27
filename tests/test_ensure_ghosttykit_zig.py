#!/usr/bin/env python3
"""Exercise Zig checks through the actual GhosttyKit preparation script."""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import git_fixture_env  # noqa: F401  (disables git auto maintenance)


ROOT = Path(__file__).resolve().parents[1]


class EnsureGhosttyKitZigTests(unittest.TestCase):
    def fixture(self, directory, zig_version=None):
        root = Path(directory)
        scripts = root / "scripts"
        scripts.mkdir()
        for name in (
            "ensure-ghosttykit.sh",
            "ghostty-zig-version.sh",
            "validate-xcframework-archive.py",
        ):
            shutil.copyfile(ROOT / "scripts" / name, scripts / name)

        ghostty = root / "ghostty"
        (ghostty / "include").mkdir(parents=True)
        (ghostty / "include/ghostty.h").write_text("/* fixture */\n")
        (ghostty / "build.zig.zon").write_text('.minimum_zig_version = "0.15.2",\n')
        (ghostty / ".gitignore").write_text("/macos/\n")
        (root / "ghostty.h").write_text('#include "ghostty/include/ghostty.h"\n')

        # An isolated PATH proves that a missing Zig cannot be supplied by the host.
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for name in (
            "bash", "dirname", "python3", "awk", "grep", "git", "mkdir", "rmdir",
            "cat", "cp", "mv", "tar", "gzip", "rm", "mktemp", "tr", "ln", "sed", "head",
        ):
            executable = shutil.which(name)
            self.assertIsNotNone(executable, name)
            (bin_dir / name).symlink_to(executable)
        hash_command = "shasum" if shutil.which("shasum") else "sha256sum"
        (bin_dir / hash_command).symlink_to(shutil.which(hash_command))

        env = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("CMUX_GHOSTTYKIT_", "GIT_"))
        }
        env.update(
            PATH=str(bin_dir), HOME=str(root), LC_ALL="C",
            GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
            CMUX_GHOSTTYKIT_CACHE_DIR=str(root / "cache"),
            CMUX_GHOSTTYKIT_NO_PREBUILT="1",
            TEST_ROOT=str(root),
        )
        for args in (
            ["init", "-q"], ["add", "."],
            ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
             "-c", "commit.gpgsign=false", "commit", "-qm", "fixture"],
        ):
            subprocess.run(["git", "-C", str(ghostty), *args], env=env, check=True)
        sha = subprocess.check_output(
            ["git", "-C", str(ghostty), "rev-parse", "HEAD"], env=env, text=True,
        ).strip()
        key = f"{sha}-crashsubdir-cmux-crash-sentry-off-noi18n-v2"

        if zig_version is not None:
            zig = bin_dir / "zig"
            zig.write_text(
                '#!/usr/bin/env bash\nset -eu\n'
                'printf "%s\\n" "$1" >> "$TEST_ROOT/zig-calls"\n'
                'case "$1" in\n'
                f'  version) printf "%s\\n" "{zig_version}" ;;\n'
                '  build) mkdir -p macos/GhosttyKit.xcframework; '
                'printf "fixture\\n" > macos/GhosttyKit.xcframework/marker ;;\n'
                '  *) exit 1 ;;\nesac\n'
            )
            zig.chmod(0o755)
        return root, env, sha, key

    def run_ensure(self, root, env):
        return subprocess.run(
            ["bash", str(root / "scripts/ensure-ghosttykit.sh")],
            env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )

    def test_existing_artifacts_do_not_require_zig(self):
        for source in ("cache", "local", "prebuilt"):
            for version in (None, "0.16.0"):
                with self.subTest(source=source, zig=version), tempfile.TemporaryDirectory() as tmp:
                    root, env, sha, key = self.fixture(tmp, version)
                    if source == "cache":
                        artifact = root / "cache" / key / "GhosttyKit.xcframework"
                    elif source == "local":
                        artifact = root / "ghostty/macos/GhosttyKit.xcframework"
                    else:
                        artifact = root / "download/GhosttyKit.xcframework"
                    artifact.mkdir(parents=True)
                    (artifact / "marker").write_text("fixture\n")
                    if source == "local":
                        (artifact / ".ghostty_state_key").write_text(key + "\n")
                    elif source == "prebuilt":
                        archive = root / "fixture.tar.gz"
                        with tarfile.open(archive, "w:gz") as tar:
                            tar.add(artifact, arcname="GhosttyKit.xcframework")
                        checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
                        (root / "scripts/ghosttykit-checksums.txt").write_text(f"{sha} {checksum}\n")
                        curl = root / "bin/curl"
                        curl.write_text(
                            '#!/usr/bin/env bash\nset -eu\n'
                            'while [[ "$1" != "-o" ]]; do shift; done\n'
                            'cp "$TEST_ROOT/fixture.tar.gz" "$2"\n'
                            'printf "downloaded\\n" > "$TEST_ROOT/curl-called"\n'
                        )
                        curl.chmod(0o755)
                        env["CMUX_GHOSTTYKIT_NO_PREBUILT"] = "0"

                    result = self.run_ensure(root, env)
                    self.assertEqual(result.returncode, 0, result.stdout)
                    self.assertEqual((root / "GhosttyKit.xcframework/marker").read_text(), "fixture\n")
                    self.assertFalse((root / "zig-calls").exists(), result.stdout)
                    if source == "prebuilt":
                        self.assertTrue((root / "curl-called").exists(), result.stdout)

    def test_source_build_requires_compatible_zig(self):
        for version, error in (
            (None, "zig is not installed"),
            ("0.16.0", "Ghostty requires zig 0.15.2"),
            ("0.15.2", None),
        ):
            with self.subTest(zig=version), tempfile.TemporaryDirectory() as tmp:
                root, env, _, _ = self.fixture(tmp, version)
                result = self.run_ensure(root, env)
                calls = root / "zig-calls"
                if error:
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn(error, result.stdout)
                    self.assertFalse((root / "GhosttyKit.xcframework").exists())
                    self.assertEqual(calls.read_text() if calls.exists() else "", "version\n" if version else "")
                else:
                    self.assertEqual(result.returncode, 0, result.stdout)
                    self.assertEqual(calls.read_text(), "version\nbuild\n")
                    self.assertEqual((root / "GhosttyKit.xcframework/marker").read_text(), "fixture\n")


if __name__ == "__main__":
    unittest.main()
