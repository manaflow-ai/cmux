#!/usr/bin/env python3
"""Behavioral checks for the release packaging gate using generated artifacts."""

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("verify_release", ROOT / "scripts/verify_remote_daemon_release.py")
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class ReleaseVerificationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.manifest_path = self.root / "cmuxd-remote-manifest.json"
        self.app = self.root / "cmux.app"
        (self.app / "Contents").mkdir(parents=True)
        self.plist = self.app / "Contents/Info.plist"
        self.plist.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.64.25"}))
        release_url = "https://github.com/manaflow-ai/cmux/releases/download/v0.64.25"
        entries, checksums = [], []
        for go_os, go_arch in sorted(verify.TARGETS):
            name = f"cmuxd-remote-{go_os}-{go_arch}"
            payload = f"test fixture for {go_os}/{go_arch}".encode()
            (self.root / name).write_bytes(payload)
            digest = hashlib.sha256(payload).hexdigest()
            entries.append(dict(goOS=go_os, goArch=go_arch, assetName=name,
                                downloadURL=f"{release_url}/{name}", sha256=digest))
            checksums.append(f"{digest}  {name}\n")
        self.checksums_path = self.root / "cmuxd-remote-checksums.txt"
        self.checksums_path.write_text("".join(checksums))
        self.manifest = dict(schemaVersion=1, appVersion="0.64.25", releaseTag="v0.64.25",
                             releaseURL=release_url, checksumsAssetName=self.checksums_path.name,
                             checksumsURL=f"{release_url}/{self.checksums_path.name}", entries=entries)
        self.write_manifest()

    def write_manifest(self):
        self.manifest_path.write_text(json.dumps(self.manifest))

    def test_complete_assets_embed_and_verify(self):
        manifest = verify.verify_assets(self.manifest_path, self.root)
        verify.verify_bundle(self.app, manifest, embed=True)
        verify.verify_bundle(self.app, manifest)
        self.assertEqual(json.loads(plistlib.loads(self.plist.read_bytes())[verify.MANIFEST_KEY]), manifest)

    def test_missing_embedded_manifest_rejects_the_reported_release(self):
        with self.assertRaisesRegex(ValueError, "missing the SSH daemon manifest"):
            verify.verify_bundle(self.app, self.manifest)

    def test_app_version_mismatch_never_embeds(self):
        self.manifest["appVersion"] = "0.64.22"
        before = self.plist.read_bytes()
        with self.assertRaisesRegex(ValueError, "versions differ"):
            verify.verify_bundle(self.app, self.manifest, embed=True)
        self.assertEqual(self.plist.read_bytes(), before)

    def test_stale_embedded_manifest_rejected(self):
        stale = copy.deepcopy(self.manifest)
        stale["entries"][0]["sha256"] = "0" * 64
        verify.verify_bundle(self.app, stale, embed=True)
        with self.assertRaisesRegex(ValueError, "manifests differ"):
            verify.verify_bundle(self.app, self.manifest)

    def test_missing_asset_and_corrupted_asset_rejected(self):
        path = self.root / self.manifest["entries"][0]["assetName"]
        path.unlink()
        with self.assertRaisesRegex(ValueError, "missing or empty asset"):
            verify.verify_assets(self.manifest_path, self.root)
        path.write_bytes(b"incorrect daemon")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            verify.verify_assets(self.manifest_path, self.root)

    def test_partial_or_duplicate_platforms_rejected(self):
        original = copy.deepcopy(self.manifest["entries"])
        for entries in (original[:-1], original[:-1] + [original[0]]):
            self.manifest["entries"] = entries
            self.write_manifest()
            with self.assertRaisesRegex(ValueError, "exactly once"):
                verify.verify_assets(self.manifest_path, self.root)

    def test_checksums_cannot_omit_a_platform(self):
        lines = self.checksums_path.read_text().splitlines()
        self.checksums_path.write_text("\n".join(lines[:-1] + [lines[0]]))
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            verify.verify_assets(self.manifest_path, self.root)

    def test_wrong_download_url_rejected(self):
        self.manifest["entries"][0]["downloadURL"] = "https://example.com/old-daemon"
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "download URL"):
            verify.verify_assets(self.manifest_path, self.root)


if __name__ == "__main__":
    unittest.main()
