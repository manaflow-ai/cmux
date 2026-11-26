#!/usr/bin/env python3
"""scripts/ci/app_build_manifest.py: manifest fields, write-once, and every error exits 0."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "scripts" / "ci" / "app_build_manifest.py"
DIGEST = "ab" * 32
# A fake store: a directory; the fake uploader writes the key only if absent, exit 3 if present.
FAKE = """import sys, os
src, key = sys.argv[1], sys.argv[2]
dest = os.path.join(os.environ["STORE"], key.replace("/", "__"))
if os.path.exists(dest): sys.exit(3)
open(dest, "wb").write(open(src, "rb").read())
"""


class ManifestTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.store = root / "store"
        self.store.mkdir()
        (root / "fake.py").write_text(FAKE)
        self.dmg = root / "cmux-arm64-7.dmg"
        self.dmg.write_bytes(b"dmg bytes")
        self.env = {**os.environ, "STORE": str(self.store), "APP_INPUT_DIGEST": DIGEST, "HEAD_SHA": "c" * 40,
                    "BUILD_SHA": "c" * 40, "DMG": str(self.dmg), "RUN_ID": "99",
                    "NIGHTLY_NEXT_R2_PREFIX": "nightly-next/",
                    "MANIFEST_UPLOADER": f"{sys.executable} {root / 'fake.py'}"}

    def run_script(self, **override):
        env = {**self.env, **override}
        return subprocess.run([sys.executable, str(SCRIPT)], env=env, capture_output=True, text=True, timeout=60)

    def stored(self):
        return self.store / f"nightly-next__builds__app__{DIGEST}__manifest.json"

    def test_fields(self):
        result = self.run_script(NOTARY_SUBMISSION_ID="sub-1")
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(self.stored().read_text())
        import hashlib
        self.assertEqual(manifest["schema"], 1)
        self.assertEqual(manifest["app_input_digest"], DIGEST)
        self.assertEqual(manifest["commit"], "c" * 40)
        self.assertEqual(manifest["bundle_sha256"], hashlib.sha256(b"dmg bytes").hexdigest())
        self.assertEqual(manifest["notarization_submission_id"], "sub-1")
        self.assertEqual(manifest["run_id"], "99")
        self.assertRegex(manifest["built_at"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")

    def test_write_once(self):
        self.run_script(RUN_ID="1")
        first = self.stored().read_text()
        result = self.run_script(RUN_ID="2")
        self.assertEqual(result.returncode, 0)
        self.assertIn("exists", result.stdout)
        self.assertEqual(self.stored().read_text(), first)

    def test_errors_exit_zero(self):
        for override in ({"MANIFEST_UPLOADER": f"{sys.executable} -c raise SystemExit(7)"},
                         {"MANIFEST_UPLOADER": "/nonexistent/uploader"},
                         {"DMG": "/nonexistent.dmg"}, {"APP_INPUT_DIGEST": "unknown"},
                         {"BUILD_SHA": "d" * 40}):
            result = self.run_script(**override)
            self.assertEqual(result.returncode, 0, (override, result.stderr))
            self.assertIn("skipped", result.stdout)
        self.assertFalse(self.stored().exists())


if __name__ == "__main__":
    unittest.main()
