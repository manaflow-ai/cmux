#!/usr/bin/env python3
"""Tests for scripts/ci/ios_asc_ops.py against a fake App Store Connect (no network, no key)."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ios_asc_ops", ROOT / "scripts/ci/ios_asc_ops.py")
ops = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ops)
WORKFLOW = ROOT / ".github/workflows/ios-asc-ops.yml"


class FakeClient:
    def __init__(self):
        self.calls = []
        self.decl = {"alcoholTobaccoOrDrugUseOrReferences": "NONE", "unrestrictedWebAccess": False}
        self.detail = None

    def get(self, path):
        return self.call("GET", path)

    def call(self, method, path, body=None):
        self.calls.append((method, path, body))
        if method == "PATCH" and path.startswith("/v1/ageRatingDeclarations/"):
            self.decl.update(body["data"]["attributes"])
            return {}
        if method == "POST" and path == "/v1/appStoreReviewDetails":
            self.detail = {"id": "rd1", "attributes": dict(body["data"]["attributes"])}
            return {}
        if method == "PATCH" and path.startswith("/v1/appStoreReviewDetails/"):
            self.detail["attributes"].update(body["data"]["attributes"])
            return {}
        if path.startswith("/v1/apps/6791408425/appStoreVersions"):
            return {"data": [{"id": "v1", "attributes": {"versionString": "1.2.0", "appStoreState": "READY_FOR_SALE"}},
                             {"id": "v2", "attributes": {"versionString": "1.3.0",
                                                         "appStoreState": "PREPARE_FOR_SUBMISSION"}}]}
        if path == "/v1/apps/6791408425/appInfos":
            return {"data": [{"id": "i1", "attributes": {"state": "READY_FOR_DISTRIBUTION"}},
                             {"id": "i2", "attributes": {"state": "PREPARE_FOR_SUBMISSION"}}]}
        if path.endswith("/ageRatingDeclaration"):
            return {"data": {"id": "d-" + path.split("/")[3], "attributes": dict(self.decl)}}
        if path == "/v1/appStoreVersions/v2/appStoreReviewDetail":
            if self.detail is None:
                raise SystemExit(f"GET {path}: HTTP 404: not found")
            return {"data": self.detail}
        if path.startswith("/v1/apps/6791408425?"):
            return {"data": {"attributes": {"name": "cmux INTERNAL", "bundleId": "dev.cmux.app.internal"}}}
        if path.startswith("/v1/reviewSubmissions?"):
            return {"data": [{"id": "s1", "attributes": {"state": "READY_FOR_REVIEW"}}]}
        raise AssertionError(f"unexpected {method} {path}")


def run(argv, client):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = ops.main(argv, client=client)
    return code, json.loads(out.getvalue())


class ReadTest(unittest.TestCase):
    def test_app_info_reads_only(self):
        client = FakeClient()
        code, out = run(["app-info"], client)
        self.assertEqual(code, 0)
        self.assertEqual(out["result"]["app"]["bundleId"], "dev.cmux.app.internal")
        self.assertEqual(len(out["result"]["ageRating"]), 2)
        self.assertEqual({m for m, _, _ in client.calls}, {"GET"})

    def test_submissions(self):
        _, out = run(["submissions"], FakeClient())
        self.assertEqual(out["result"]["submissions"][0]["state"], "READY_FOR_REVIEW")

    def test_get_refuses_non_api_path(self):
        for bad in ("https://evil/x", "/v1/apps/1; rm", "v1/apps"):
            with self.assertRaises(SystemExit):
                run(["get", "--path", bad], FakeClient())

    def test_unknown_app_refused(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            ops.main(["versions", "--app", "123"], client=FakeClient())


class WriteTest(unittest.TestCase):
    def test_age_rating_patch_targets_editable_info_and_reads_back(self):
        client = FakeClient()
        _, out = run(["age-rating-patch", "--attributes", '{"unrestrictedWebAccess": true}'], client)
        patch = [c for c in client.calls if c[0] == "PATCH"]
        self.assertEqual(patch[0][1], "/v1/ageRatingDeclarations/d-i2")
        self.assertFalse(out["result"]["before"]["unrestrictedWebAccess"])
        self.assertTrue(out["result"]["after"]["unrestrictedWebAccess"])

    def test_age_rating_patch_needs_object(self):
        for bad in ("", "[]", "{}", "nope"):
            with self.assertRaises(SystemExit):
                run(["age-rating-patch", "--attributes", bad], FakeClient())

    def test_review_detail_sync_creates_then_patches_and_redacts(self):
        client = FakeClient()
        _, out = run(["review-detail-sync", "--attributes",
                      '{"notes": "hi", "demoAccountPassword": "s3cret", "demoAccountRequired": true}'], client)
        self.assertIsNone(out["result"]["before"])
        self.assertEqual(out["result"]["after"]["notes"], "hi")
        self.assertEqual(out["result"]["after"]["demoAccountPassword"], "<redacted>")
        _, out = run(["review-detail-sync", "--attributes", '{"notes": "two"}'], client)
        self.assertEqual(out["result"]["after"]["notes"], "two")
        self.assertNotIn("s3cret", json.dumps(out))

    def test_review_detail_sync_refuses_unknown_keys(self):
        with self.assertRaises(SystemExit):
            run(["review-detail-sync", "--attributes", '{"bogus": 1}'], FakeClient())


class JwtTest(unittest.TestCase):
    def test_der_to_raw(self):
        der = bytes([0x30, 0x08, 0x02, 0x02, 0x00, 0x81, 0x02, 0x02, 0x01, 0x02])
        raw = ops._der_to_raw(der)
        self.assertEqual(len(raw), 64)
        self.assertEqual(raw[31], 0x81)
        self.assertEqual(raw[62:], b"\x01\x02")


class WorkflowTest(unittest.TestCase):
    def test_workflow_offers_every_op_and_runs_from_main_only(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        for op in ops.READS + ops.WRITES:
            self.assertIn(f"- {op}", text)
        self.assertIn("environment: release", text)
        self.assertIn("github.ref == 'refs/heads/main'", text)


if __name__ == "__main__":
    unittest.main()
