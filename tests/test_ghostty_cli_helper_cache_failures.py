"""Exercise the real cache functions in Bash conditional context, where -e is disabled."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = (Path(__file__).parents[1] / "scripts/build-ghostty-cli-helper.sh").read_text()
FUNCTIONS = SOURCE[SOURCE.index("ghostty_cache_install_if_valid() {"):SOURCE.index("# Real host arch")]


class CacheFailures(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cache = self.root / "cache"
        self.cache.mkdir()
        self.binary = self.cache / "ghostty"
        self.binary.write_text("#!/bin/sh\necho verified\n")
        self.binary.chmod(0o755)
        self.manifest = self.cache / "manifest"
        digest = hashlib.sha256(self.binary.read_bytes()).hexdigest()
        self.manifest.write_text("metadata\nbinary_sha256=" + digest)
        self.shims = self.root / "shims"
        self.shims.mkdir()
        self.env = dict(os.environ, PATH=str(self.shims) + ":" + os.environ["PATH"])
        self.prelude = ""

    def shim(self, name, body):
        path = self.shims / name
        path.write_text("#!/bin/bash\n" + body + "\n")
        path.chmod(0o755)

    def call(self, operation):
        command = {
            "install": 'ghostty_cache_install_if_valid "$1/ghostty" "$1/manifest" metadata "$2"',
            "publish": 'ghostty_cache_publish "$1/published" metadata "$1/ghostty"',
        }[operation]
        return subprocess.run(
            ["/bin/bash", "-c", "set -euo pipefail\n" + FUNCTIONS +
             "\n" + self.prelude + "\nif " + command + "; then exit 0; else exit 73; fi",
             "cache-test", str(self.cache), str(self.root / "prefix")],
            env=self.env, capture_output=True, text=True,
        )

    def test_install_rejects_failed_operations(self):
        for operation in ("mkdir", "install", "shasum", "mv"):
            with self.subTest(operation=operation):
                self.shim(operation, "exit 1")
                result = self.call("install")
                self.assertEqual(result.returncode, 73, result.stdout + result.stderr)
                self.assertNotIn("Reusing cached", result.stdout)
                (self.shims / operation).unlink()

    def test_install_validates_the_copied_bytes(self):
        self.shim("install", '/usr/bin/install "$@" || exit $?\n'
                  'for destination; do :; done\nprintf corrupted > "$destination"')
        result = self.call("install")
        self.assertEqual(result.returncode, 73, result.stdout + result.stderr)
        self.assertFalse((self.root / "prefix/bin/ghostty").exists())

    def test_publish_rejects_failed_operations(self):
        for operation in ("mkdir", "install", "shasum", "mv"):
            with self.subTest(operation=operation):
                self.shim(operation, "exit 1")
                result = self.call("publish")
                self.assertEqual(result.returncode, 73, result.stdout + result.stderr)
                (self.shims / operation).unlink()

    def test_valid_cache_roundtrip(self):
        result = self.call("publish")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.cache = self.cache / "published"
        self.binary = self.cache / "ghostty"
        self.assertTrue(self.binary.exists())
        result = self.call("install")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "prefix/bin/ghostty").read_bytes(), self.binary.read_bytes())

    def test_publish_rejects_failed_manifest_write(self):
        self.prelude = "printf() { return 1; }"
        result = self.call("publish")
        self.assertEqual(result.returncode, 73, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
