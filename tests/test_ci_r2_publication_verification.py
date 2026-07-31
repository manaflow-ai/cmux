#!/usr/bin/env python3
import importlib.util
import pathlib
import sys
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts/ci/upload-r2-object.py"
SPEC = importlib.util.spec_from_file_location("upload_r2_object", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class Response:
    def __init__(self, body: bytes):
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self) -> bytes:
        return self.body


class PublicationVerificationTests(unittest.TestCase):
    @mock.patch.object(MODULE.time, "sleep")
    @mock.patch.object(MODULE.urllib.request, "urlopen")
    def test_retries_stale_bytes_until_exact_match(self, urlopen, _sleep) -> None:
        urlopen.side_effect = [Response(b"old"), Response(b"new")]
        verified, _detail = MODULE.verify_publication(
            "https://files.cmux.com/stable/appcast.xml", b"new", attempts=2, delay=0
        )
        self.assertTrue(verified)
        self.assertEqual(urlopen.call_count, 2)

    @mock.patch.object(MODULE.time, "sleep")
    @mock.patch.object(MODULE.urllib.request, "urlopen")
    def test_fails_when_public_url_never_matches(self, urlopen, _sleep) -> None:
        urlopen.side_effect = [Response(b"old"), Response(b"still-old")]
        verified, detail = MODULE.verify_publication(
            "https://files.cmux.com/stable/appcast.xml", b"new", attempts=2, delay=0
        )
        self.assertFalse(verified)
        self.assertIn("expected", detail)


if __name__ == "__main__":
    unittest.main()
