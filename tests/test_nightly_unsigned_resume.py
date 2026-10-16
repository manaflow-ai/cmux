#!/usr/bin/env python3
"""Resuming publication requires an authenticated digest, never size alone."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("artifact_download", ROOT / "scripts/ci/download-run-artifact.py")
download = importlib.util.module_from_spec(spec)
spec.loader.exec_module(download)


class ArtifactDigestTests(unittest.TestCase):
    def test_an_unsigned_input_without_a_digest_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "artifact.zip"
            path.write_bytes(b"same size is not identity")
            with self.assertRaises(SystemExit):
                download.verify(str(path), {"size_in_bytes": path.stat().st_size})


if __name__ == "__main__":
    unittest.main()
