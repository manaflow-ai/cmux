#!/usr/bin/env python3
"""Exercise the R2 transport and fallback with real ZIP files, without network."""
import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("r2_artifact", ROOT / "scripts/ci/restore-r2-artifact.py")
transport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.destination = Path(self.temp.name) / "products"
        self.zip = self.pack("app-host-products.aar", b"opaque archive with sealed warning log")
        self.calls = []
        self.wrong_run = False
        self.corrupt = False
        self.down = False

    def pack(self, name, body):
        out = io.BytesIO()
        with zipfile.ZipFile(out, "w") as archive:
            archive.writestr(name, body)
        return out.getvalue()

    def metadata(self, artifact_id):
        self.calls.append(("metadata", artifact_id))
        return {"id": 123, "expired": False, "size_in_bytes": len(self.zip),
                "digest": "sha256:" + hashlib.sha256(self.zip).hexdigest(),
                "workflow_run": {"id": 999 if self.wrong_run else 456}}

    def download(self, url, target, size):
        self.calls.append(("download", url))
        if self.down:
            raise TimeoutError("broker unavailable")
        target.write_bytes(b"0" * size if self.corrupt else self.zip)

    def restore(self, broker="https://broker.example", repository="manaflow-ai/cmux"):
        return transport.restore(broker, "123", "456", repository, self.destination, self.metadata, self.download)

    def test_disabled_does_no_network_work(self):
        self.assertFalse(self.restore(""))
        self.assertEqual(self.calls, [])

    def test_opaque_gzip_and_apple_archives_keep_all_bytes_for_existing_validator(self):
        for name in transport.ARCHIVES:
            with self.subTest(name=name):
                self.zip = self.pack(name, b"opaque archive with sealed warning log")
                self.assertTrue(self.restore())
                archive = self.destination / name
                self.assertEqual(archive.read_bytes(), b"opaque archive with sealed warning log")
                archive.unlink()
                self.destination.rmdir()

    def test_corrupt_or_unavailable_broker_falls_back_without_partial_products(self):
        for reason in ["corrupt", "down"]:
            with self.subTest(reason=reason):
                setattr(self, reason, True)
                self.assertFalse(self.restore())
                self.assertFalse(self.destination.exists())
                setattr(self, reason, False)

    def test_provider_digest_valid_but_bad_zip_falls_back(self):
        self.zip = b"not a ZIP even though its provider digest matches"
        self.assertFalse(self.restore())
        self.assertFalse(self.destination.exists())

    def test_other_run_or_repository_is_not_reused(self):
        self.wrong_run = True
        self.assertFalse(self.restore())
        self.assertEqual(len(self.calls), 1)
        self.calls.clear()
        self.assertFalse(self.restore(repository="someone/cmux"))
        self.assertEqual(self.calls, [])

    def test_no_tokens_or_insecure_origins_in_broker_configuration(self):
        for url in ["https://secret@broker.example", "http://broker.example", "https://broker.example?token=secret"]:
            self.assertFalse(self.restore(url))
        self.assertEqual(self.calls, [])

    def test_path_escape_and_symlink_members_are_rejected(self):
        self.zip = self.pack("../app-host-products.aar", b"bad")
        self.assertFalse(self.restore())
        self.assertFalse(self.destination.exists())
        member = zipfile.ZipInfo("app-host-products.aar")
        member.create_system = 3
        member.external_attr = 0o120777 << 16
        self.zip = self.pack(member, b"/outside")
        self.assertFalse(self.restore())
        self.assertFalse(self.destination.exists())

    def test_stale_products_are_not_overwritten_by_a_partial_hit(self):
        self.destination.mkdir()
        existing = self.destination / "owner"
        existing.write_text("untouched")
        self.assertFalse(self.restore())
        self.assertEqual(existing.read_text(), "untouched")
        self.assertEqual(list(self.destination.iterdir()), [existing])


if __name__ == "__main__":
    unittest.main()
