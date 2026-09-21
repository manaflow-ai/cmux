#!/usr/bin/env python3
"""Exercise the R2 transport and fallback with real ZIP files, without network."""
import hashlib
import importlib.util
import io
import subprocess
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
        self.expired = False
        self.wrong_digest = False
        self.api_failure = False
        self.identity_failure = False
        self.cache = "fill"
        self.receipt = {}

    def pack(self, name, body):
        out = io.BytesIO()
        with zipfile.ZipFile(out, "w") as archive:
            archive.writestr(name, body)
        return out.getvalue()

    def metadata(self, artifact_id):
        self.calls.append(("metadata", artifact_id))
        if self.api_failure:
            raise subprocess.CalledProcessError(1, ["gh", "api"])
        digest = "f" * 64 if self.wrong_digest else hashlib.sha256(self.zip).hexdigest()
        return {"id": 123, "expired": self.expired, "size_in_bytes": len(self.zip),
                "digest": "sha256:" + digest,
                "workflow_run": {"id": 999 if self.wrong_run else 456}}

    def identity(self, work):
        self.calls.append(("identity", Path(work).name))
        if self.identity_failure:
            raise ValueError("OIDC unavailable")
        return "header.payload.signature"

    def download(self, url, target, size, identity, work):
        self.calls.append(("download", url))
        self.assertEqual(identity, "header.payload.signature")
        if self.down:
            raise TimeoutError("broker unavailable")
        target.write_bytes(b"0" * size if self.corrupt else self.zip)
        return {"cache": self.cache, "broker_wait_seconds": 0.125,
                "transfer_seconds": 0.5, "broker_total_seconds": 0.625,
                "downloaded_bytes": size}

    def restore(self, broker="https://broker.example", repository="manaflow-ai/cmux"):
        self.receipt = {}
        return transport.restore(broker, "123", "456", repository, self.destination,
                                 self.metadata, self.download, self.identity, self.receipt)

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


    def test_expiry_digest_auth_and_github_api_failures_fall_back(self):
        for flag in ["expired", "wrong_digest", "api_failure", "identity_failure"]:
            with self.subTest(flag=flag):
                setattr(self, flag, True)
                self.assertFalse(self.restore())
                self.assertEqual(self.receipt["transport"], "github")
                self.assertEqual(self.receipt["r2_result"], "miss")
                self.assertIn("fallback_reason", self.receipt)
                self.assertFalse(self.destination.exists())
                setattr(self, flag, False)

    def test_success_receipt_distinguishes_fill_and_hit_and_reports_transfer(self):
        for cache in ["fill", "hit"]:
            with self.subTest(cache=cache):
                self.cache = cache
                self.assertTrue(self.restore())
                self.assertEqual(self.receipt["transport"], "r2")
                self.assertEqual(self.receipt["r2_result"], cache)
                self.assertEqual(self.receipt["downloaded_bytes"], len(self.zip))
                self.assertEqual(self.receipt["broker_wait_seconds"], 0.125)
                self.assertEqual(self.receipt["transfer_seconds"], 0.5)
                self.assertIn("outer_restore_seconds", self.receipt)
                archive = next(self.destination.iterdir())
                archive.unlink()
                self.destination.rmdir()

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
