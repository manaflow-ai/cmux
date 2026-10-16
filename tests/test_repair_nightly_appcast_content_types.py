#!/usr/bin/env python3
import argparse
import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import MagicMock, patch
import urllib.error


spec = importlib.util.spec_from_file_location(
    "repair_appcasts", Path(__file__).resolve().parents[1] / "scripts/ci/repair-nightly-appcast-content-types.py"
)
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)
BODY = b'<?xml version="1.0"?><rss><channel><title>Current nightly</title></channel></rss>\n'
ORIGINAL = {"content-type": "application/x-www-form-urlencoded", "etag": '"original"',
            "cache-control": "no-cache, no-store, must-revalidate", "content-language": "en",
            "content-disposition": "inline", "expires": "Thu, 10 Sep 2026 22:25:53 GMT",
            "x-amz-meta-publisher": "nightly", "x-amz-storage-class": "STANDARD"}


class RepairTests(unittest.TestCase):
    def test_repair_request_signs_content_type_condition_and_metadata(self):
        args = argparse.Namespace(endpoint_url="https://example.invalid", bucket="cmux-binaries",
                                  key="nightly/appcast.xml", content_type="application/xml",
                                  cache_control=ORIGINAL["cache-control"])
        response = MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = b""
        response.headers = {}
        with patch.dict(os.environ, {"AWS_ACCESS_KEY_ID": "example", "AWS_SECRET_ACCESS_KEY": "example"}, clear=True), \
             patch.object(repair.uploader, "_open_signed_request", return_value=response) as open_request:
            repair.request(args, "PUT", BODY, {"if-match": ORIGINAL["etag"], "x-amz-meta-publisher": "nightly"})
        request = open_request.call_args.args[0]
        headers = {k.lower(): v for k, v in request.header_items()}
        self.assertEqual(request.data, BODY)
        self.assertEqual(headers["content-type"], "application/xml")
        self.assertEqual(headers["if-match"], ORIGINAL["etag"])
        signed = headers["authorization"].split("SignedHeaders=", 1)[1].split(",", 1)[0].split(";")
        for name in ("content-type", "cache-control", "if-match", "x-amz-meta-publisher"):
            self.assertIn(name, signed)

    def run_repair(self, *, execute=True, original=None, conflict=False, corrupt=False):
        self.calls = []
        objects = {f"nightly/{name}": [BODY, dict(ORIGINAL if original is None else original)] for name in repair.APPCASTS}

        def endpoint(args, method, body=b"", headers=None):
            self.assertEqual(args.bucket, "cmux-binaries")
            self.assertEqual(args.endpoint_url, "https://example.invalid")
            self.calls.append((method, args.key, body, headers))
            current, metadata = objects[args.key]
            if method == "PUT":
                if conflict:
                    raise urllib.error.HTTPError("https://example.invalid", 412, "Precondition Failed", {}, None)
                self.assertEqual(body, current)
                self.assertEqual(headers["if-match"], metadata["etag"])
                preserved = {k: v for k, v in metadata.items() if k in repair.METADATA or k.startswith("x-amz-meta-")}
                self.assertEqual(headers, {**preserved, "if-match": metadata["etag"]})
                self.assertEqual(args.content_type, "application/xml")
                self.assertEqual(args.cache_control, metadata["cache-control"])
                metadata["content-type"] = args.content_type
                if corrupt:
                    objects[args.key][0] = b"changed"
                return b"", {}
            self.assertEqual(method, "GET")
            return current, dict(metadata)

        with patch.object(repair, "request", side_effect=endpoint):
            repair.repair("https://example.invalid", execute=execute)

    def test_repairs_only_four_current_feeds_and_preserves_bytes_and_metadata(self):
        self.run_repair()
        self.assertEqual([key for method, key, _, _ in self.calls if method == "PUT"],
                         [f"nightly/{name}" for name in repair.APPCASTS])
        self.assertEqual([method for method, _, _, _ in self.calls], ["GET", "PUT", "GET"] * 4)
        for method, _, _, headers in self.calls:
            if method == "GET" and headers:
                self.assertEqual(headers, {"if-match": ORIGINAL["etag"]})

    def test_read_only_mode_never_writes(self):
        self.run_repair(execute=False)
        self.assertEqual([c[0] for c in self.calls], ["GET"] * 4)

    def test_correct_metadata_is_not_rewritten(self):
        self.run_repair(original={**ORIGINAL, "content-type": "application/xml"})
        self.assertEqual([c[0] for c in self.calls], ["GET"] * 8)

    def test_concurrent_publication_stops_without_retry(self):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.run_repair(conflict=True)
        self.assertEqual(caught.exception.code, 412)
        self.assertEqual([c[0] for c in self.calls], ["GET", "PUT"])

    def test_missing_precondition_or_metadata_stops_without_writing(self):
        for key in ("etag", "cache-control"):
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                self.run_repair(original={k: v for k, v in ORIGINAL.items() if k != key})
            self.assertEqual([c[0] for c in self.calls], ["GET"])

    def test_verification_detects_changed_body(self):
        with self.assertRaisesRegex(RuntimeError, "verification failed"):
            self.run_repair(corrupt=True)
        self.assertEqual([c[0] for c in self.calls], ["GET", "PUT", "GET"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
