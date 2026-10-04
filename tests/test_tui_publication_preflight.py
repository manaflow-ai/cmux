import importlib.util
import io
import json
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/ci/cmux_tui_publication.py"
KEY = "a" * 40
DIGEST = "b" * 64
NAME = "cmux-tui-aarch64-apple-darwin"


class PublicationPreflightTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("publication", SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    def response(self, request, timeout):
        self.assertEqual(timeout, 20)
        if request.full_url.endswith("source.json"):
            return io.BytesIO(json.dumps({
                "key": KEY, "commit": "c" * 40, "binaries": {NAME: DIGEST}
            }).encode())
        if request.full_url.endswith(".sha256"):
            return io.BytesIO(f"{DIGEST}  {NAME}\n".encode())
        self.assertEqual(request.get_method(), "HEAD")
        return io.BytesIO()

    def test_complete_publication_is_reused_across_commit_shas(self):
        with patch.object(self.module, "urlopen", side_effect=self.response):
            ready, reason = self.module.publication_ready(KEY)
        self.assertTrue(ready, reason)

    def test_missing_binary_does_not_skip_build(self):
        def respond(request, timeout):
            if request.get_method() == "HEAD":
                raise HTTPError(request.full_url, 404, "missing", {}, None)
            return self.response(request, timeout)
        with patch.object(self.module, "urlopen", side_effect=respond):
            self.assertFalse(self.module.publication_ready(KEY)[0])

    def test_missing_digest_does_not_skip_build(self):
        with patch.object(self.module, "urlopen", side_effect=HTTPError("url", 404, "missing", {}, None)):
            self.assertFalse(self.module.publication_ready(KEY)[0])

    def test_manifest_for_another_key_does_not_skip_build(self):
        def respond(request, timeout):
            if request.full_url.endswith("source.json"):
                return io.BytesIO(json.dumps({"key": "d" * 40, "commit": "c" * 40,
                    "binaries": {NAME: DIGEST}}).encode())
            return self.response(request, timeout)
        with patch.object(self.module, "urlopen", side_effect=respond):
            self.assertFalse(self.module.publication_ready(KEY)[0])

    def test_mismatched_digest_does_not_skip_build(self):
        def respond(request, timeout):
            if request.full_url.endswith(".sha256"):
                return io.BytesIO(f"{'e' * 64}  {NAME}\n".encode())
            return self.response(request, timeout)
        with patch.object(self.module, "urlopen", side_effect=respond):
            self.assertFalse(self.module.publication_ready(KEY)[0])

    def test_invalid_key_is_rejected_before_network_access(self):
        with patch.object(self.module, "urlopen") as fetch:
            with self.assertRaises(ValueError):
                self.module.publication_ready("../not-a-key")
            fetch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
