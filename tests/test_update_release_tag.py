#!/usr/bin/env python3
"""The nightly completion marker is updated through a verified API ref write."""

import importlib.util
import json
from pathlib import Path
import sys
import unittest
from unittest import mock
from urllib.error import HTTPError


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "update_release_tag", ROOT / "scripts/ci/update-release-tag.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class FakeResponse:
    def __init__(self, body):
        self.body = json.dumps(body).encode()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self):
        return self.body


class UpdateReleaseTagTests(unittest.TestCase):
    SHA = "a" * 40

    def call(self, existing, *, responses=None):
        calls = []
        queued = list(responses or [])
        updated = False

        def urlopen(request):
            nonlocal updated
            calls.append((request.method, request.full_url, request.data))
            if request.method in {"PATCH", "POST"}:
                updated = True
            if "/compare/" in request.full_url:
                return FakeResponse({"status": "ahead"})
            response = queued.pop(0) if queued else None
            if isinstance(response, Exception):
                raise response
            if response is not None:
                return FakeResponse(response)
            if request.method == "GET" and updated:
                return FakeResponse({"object": {"sha": self.SHA, "type": "commit"}})
            if request.method == "GET":
                return FakeResponse(existing)
            return FakeResponse({"ref": "refs/tags/nightly", "object": {"sha": self.SHA, "type": "commit"}})

        with mock.patch.object(MODULE.urllib.request, "urlopen", side_effect=urlopen), \
                mock.patch.object(MODULE.time, "sleep") as sleep, \
                mock.patch.dict(MODULE.os.environ, {"GH_TOKEN": "test-token"}, clear=False):
            MODULE.update_tag("owner/repo", "nightly", self.SHA)
        return calls, sleep

    def test_existing_tag_uses_patch_and_verifies_exact_commit(self):
        calls, _ = self.call({"object": {"sha": "b" * 40, "type": "commit"}})
        self.assertEqual([method for method, _, _ in calls], ["GET", "GET", "PATCH", "GET"])
        self.assertEqual(json.loads(calls[2][2]), {"sha": self.SHA, "force": True})

    def test_missing_tag_uses_create_and_verifies_exact_commit(self):
        calls, _ = self.call(None, responses=[HTTPError("https://api.github.com", 404, "missing", {}, None)])
        self.assertEqual([method for method, _, _ in calls], ["GET", "POST", "GET"])
        self.assertEqual(json.loads(calls[1][2]), {"ref": "refs/tags/nightly", "sha": self.SHA})

    def test_transient_api_failure_is_bounded_and_retried(self):
        transient = HTTPError("https://api.github.com", 503, "unavailable", {}, None)
        calls, sleep = self.call(
            {"object": {"sha": "b" * 40, "type": "commit"}},
            responses=[transient, {"object": {"sha": "b" * 40, "type": "commit"}}],
        )
        self.assertEqual([method for method, _, _ in calls], ["GET", "GET", "GET", "PATCH", "GET"])
        self.assertEqual(sleep.call_count, 1)

    def test_permission_failure_is_not_retried(self):
        error = HTTPError("https://api.github.com", 403, "forbidden", {}, None)
        with mock.patch.object(MODULE.urllib.request, "urlopen", side_effect=error) as urlopen, \
                mock.patch.object(MODULE.time, "sleep") as sleep, \
                mock.patch.dict(MODULE.os.environ, {"GH_TOKEN": "test-token"}, clear=False):
            with self.assertRaises(MODULE.TagUpdateError):
                MODULE.update_tag("owner/repo", "nightly", self.SHA)
        self.assertEqual(urlopen.call_count, 1)
        sleep.assert_not_called()

    def test_non_descendant_candidate_cannot_regress_tag(self):
        calls = []

        def urlopen(request):
            calls.append(request.method)
            if "/compare/" in request.full_url:
                return FakeResponse({"status": "behind"})
            return FakeResponse({"object": {"sha": "b" * 40, "type": "commit"}})

        with mock.patch.object(MODULE.urllib.request, "urlopen", side_effect=urlopen), \
                mock.patch.dict(MODULE.os.environ, {"GH_TOKEN": "test-token"}, clear=False):
            with self.assertRaisesRegex(MODULE.TagUpdateError, "non-descendant"):
                MODULE.update_tag("owner/repo", "nightly", self.SHA)
        self.assertEqual(calls, ["GET", "GET"])


if __name__ == "__main__":
    unittest.main()
