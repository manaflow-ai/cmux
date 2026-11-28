#!/usr/bin/env python3
"""Authoritative available TestFlight window, not creation-ordered Actions runs."""
from __future__ import annotations

from datetime import datetime, timezone
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ios_publication_snapshot", ROOT / "scripts/ci/ios_publication_snapshot.py")
publication = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publication)
PRODUCER = {"run_id": "123", "run_attempt": "2", "workflow_sha": "f" * 40,
            "workflow_ref": "manaflow-ai/cmux/.github/workflows/ios-asc-ops.yml@refs/heads/main"}
NOW = datetime(2026, 11, 27, 20, tzinfo=timezone.utc)


def document(count=3):
    builds, included = [], []
    for index in range(count):
        build_id = str(100 - index)
        source = ("a", "b", "c", "d")[index % 4] * 12
        builds.append({"id": build_id, "type": "builds", "attributes": {
            "version": "20261127" + build_id, "uploadedDate": f"2026-11-27T{19-index:02}:00:00Z",
            "processingState": "VALID", "expired": False}, "relationships": {
                "buildBetaDetail": {"data": {"type": "buildBetaDetails", "id": build_id}},
                "betaBuildLocalizations": {"data": [{"type": "betaBuildLocalizations", "id": build_id}]}}})
        included.extend([
            {"id": build_id, "type": "buildBetaDetails", "attributes": {"internalBuildState": "IN_BETA_TESTING"}},
            {"id": build_id, "type": "betaBuildLocalizations", "attributes": {
                "locale": "en-US", "whatsNew": f"cmux-next iPhone, feat-cmux-next {source}."}},
        ])
    return {"data": builds, "included": included}


def snapshot(doc=None, **kwargs):
    return publication.snapshot(doc or document(), lambda prefix: prefix[0] * 40,
                                head_sha="e" * 40, request_id="456:1", producer=PRODUCER,
                                now=NOW, **kwargs)


class SnapshotTests(unittest.TestCase):
    def test_actual_release_note_emitter_normal_and_yolo_headers(self):
        # Captured by executing ios_internal_notes.lead_line at feat source
        # 2bc87d7190ceee99c9e100b199c31883fc216c26 (lines242-249).
        headers = (
            ("cmux-next iPhone 1.4.0, feat-cmux-next aaaaaaaaaaaa. Internal testers only.", "a"),
            ("cmux-next iPhone 1.4.0 YOLO, feat-cmux-next aaaaaaaaaaaa + #61292 (dddddddddddd). Internal testers only.", "d"),
        )
        for note, expected in headers:
            with self.subTest(note=note):
                doc = document()
                doc["included"][1]["attributes"]["whatsNew"] = note
                self.assertEqual(snapshot(doc)["releases"][0]["sha"], expected * 40)

    def test_malformed_yolo_cannot_substitute_base_for_the_shipped_source(self):
        doc = document()
        doc["included"][1]["attributes"]["whatsNew"] = "cmux-next iPhone YOLO, feat-cmux-next aaaaaaaaaaaa + #61292"
        with self.assertRaisesRegex(ValueError, "built stack SHA"):
            snapshot(doc)

    def test_available_window_has_source_and_request_binding_without_fake_publication_time(self):
        result = snapshot()
        self.assertEqual([r["sha"] for r in result["releases"]], [c * 40 for c in "abc"])
        self.assertEqual(result["request"], {"repository": "manaflow-ai/cmux", "head_sha": "e" * 40, "request_id": "456:1"})
        self.assertEqual(result["producer"], PRODUCER)
        self.assertEqual(result["generated_at"], NOW.isoformat())
        self.assertNotIn("published_at", result["releases"][0])

    def test_ancient_workflow_rerun_is_selected_by_current_asc_upload(self):
        doc = document(4)
        doc["included"][1]["attributes"]["whatsNew"] = "feat-cmux-next " + "d" * 12
        result = snapshot(doc)
        self.assertEqual(result["releases"][0]["sha"], "d" * 40)

    def test_processed_but_not_available_and_expired_are_skipped(self):
        for change in ("waiting", "expired"):
            with self.subTest(change=change):
                doc = document(4)
                if change == "waiting":
                    doc["included"][0]["attributes"]["internalBuildState"] = "READY_FOR_BETA_TESTING"
                else:
                    doc["data"][0]["attributes"]["expired"] = True
                self.assertEqual([r["sha"] for r in snapshot(doc)["releases"]], [c * 40 for c in "bcd"])

    def test_no_short_window_when_three_available_builds_not_proven(self):
        doc = document()
        doc["included"][0]["attributes"]["internalBuildState"] = "READY_FOR_BETA_TESTING"
        with self.assertRaisesRegex(ValueError, "does not prove three"):
            snapshot(doc)

    def test_repeated_sources_remain_separate_releases(self):
        doc = document()
        doc["included"][3]["attributes"]["whatsNew"] = "feat-cmux-next " + "a" * 12
        self.assertEqual(len(snapshot(doc)["releases"]), 3)
        self.assertEqual(snapshot(doc)["releases"][0]["sha"], snapshot(doc)["releases"][1]["sha"])

    def test_missing_availability_evidence_is_not_silently_skipped(self):
        doc = document(4)
        doc["included"].pop(0)
        with self.assertRaisesRegex(ValueError, "omitted internal availability"):
            snapshot(doc)

    def test_missing_expiration_or_state_cannot_hide_the_newest_build(self):
        for field in ("expired", "internalBuildState"):
            doc = document(4)
            target = doc["data"][0] if field == "expired" else doc["included"][0]
            del target["attributes"][field]
            with self.subTest(field=field), self.assertRaises(ValueError):
                snapshot(doc)

    def test_missing_or_conflicting_source_notes_fail(self):
        for note in ("no source", "feat-cmux-next " + "a" * 12 + " feat-cmux-next " + "b" * 12):
            doc = document()
            doc["included"][1]["attributes"]["whatsNew"] = note
            with self.assertRaisesRegex(ValueError, "missing or conflicting"):
                snapshot(doc)

    def test_source_resolver_must_match_prefix(self):
        with self.assertRaisesRegex(ValueError, "full matching commit"):
            publication.snapshot(document(), lambda _: "f" * 40, head_sha="e" * 40,
                                 request_id="456:1", producer=PRODUCER, now=NOW)

    def test_invalid_order_duplicate_ids_and_missing_timezone_fail(self):
        for change in ("order", "duplicate", "timezone"):
            doc = document()
            if change == "order":
                doc["data"].reverse()
            elif change == "duplicate":
                doc["data"][1]["attributes"]["version"] = doc["data"][0]["attributes"]["version"]
            else:
                doc["data"][0]["attributes"]["uploadedDate"] = "2026-11-27T19:00:00"
            with self.subTest(change=change), self.assertRaises(ValueError):
                snapshot(doc)

    def test_untrusted_producer_or_unbound_request_fail(self):
        for producer, request in (({**PRODUCER, "workflow_ref": "attacker"}, "456:1"),
                                  (PRODUCER, "bad")):
            with self.assertRaises(ValueError):
                publication.snapshot(document(), lambda p: p[0] * 40, head_sha="e" * 40,
                                     request_id=request, producer=producer, now=NOW)

    def test_scan_bound_is_not_expanded(self):
        doc = document()
        doc["data"] *= 8
        with self.assertRaisesRegex(ValueError, "bounded ASC"):
            snapshot(doc)


class OperationTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("ios_asc_ops", ROOT / "scripts/ci/ios_asc_ops.py")
        self.ops = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.ops)
        self.env = {"GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "2",
                    "GITHUB_WORKFLOW_SHA": "f" * 40, "GITHUB_WORKFLOW_REF": PRODUCER["workflow_ref"]}

    def test_operation_writes_request_bound_artifact_and_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            artifact, output = Path(tmp) / "ios-publication.json", Path(tmp) / "output"
            with patch.dict(os.environ, {**self.env, "GITHUB_OUTPUT": str(output)}, clear=True), \
                 patch.object(self.ops.publication.Reader, "builds", return_value=document()), \
                 patch.object(self.ops.publication.Reader, "source", side_effect=lambda p: p[0] * 40), \
                 contextlib.redirect_stdout(io.StringIO()):
                code = self.ops.main(["publication-snapshot", "--head-sha", "e" * 40,
                                      "--request-id", "456:1", "--snapshot-output", str(artifact)],
                                     client=SimpleNamespace(token="asc-secret"))
            self.assertEqual(code, 0)
            result = json.loads(artifact.read_text())
            self.assertEqual(result["producer"], PRODUCER)
            self.assertEqual(result["request"]["request_id"], "456:1")
            self.assertEqual([r["sha"] for r in result["releases"]], [c * 40 for c in "abc"])
            self.assertEqual(output.read_text(), "artifact_name=ios-publication-snapshot-456-1\n")
            self.assertNotIn("asc-secret", artifact.read_text())

    def test_failed_query_publishes_neither_artifact_nor_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            artifact, output = Path(tmp) / "ios-publication.json", Path(tmp) / "output"
            with patch.dict(os.environ, {**self.env, "GITHUB_OUTPUT": str(output)}, clear=True), \
                 patch.object(self.ops.publication.Reader, "builds", return_value=document(2)), \
                 patch.object(self.ops.publication.Reader, "source", side_effect=lambda p: p[0] * 40):
                with self.assertRaisesRegex(ValueError, "does not prove three"):
                    self.ops.main(["publication-snapshot", "--head-sha", "e" * 40,
                                   "--request-id", "456:1", "--snapshot-output", str(artifact)],
                                  client=SimpleNamespace(token="asc-secret"))
            self.assertFalse(artifact.exists())
            self.assertFalse(output.exists())

    def test_operation_rejects_noninternal_app_before_network(self):
        with patch.object(self.ops.publication.Reader, "builds") as builds:
            with self.assertRaisesRegex(SystemExit, "only reads cmux INTERNAL"):
                self.ops.main(["publication-snapshot", "--app", "6783338052", "--snapshot-output", "/unused"],
                              client=SimpleNamespace(token="asc-secret"))
        builds.assert_not_called()


class ReaderTests(unittest.TestCase):
    def test_one_bounded_availability_query(self):
        reader = publication.Reader("asc-secret", "github-secret")
        with patch.object(reader, "read", return_value={}) as read:
            reader.builds()
        query = urllib.parse.parse_qs(urllib.parse.urlparse(read.call_args.args[0]).query)
        self.assertEqual(query["limit"], ["20"])
        self.assertEqual(query["sort"], ["-uploadedDate"])
        self.assertIn("buildBetaDetail", query["include"][0])
        self.assertEqual(query["filter[processingState]"], ["VALID"])

    def test_no_credential_redirect_or_wrong_host(self):
        self.assertIsNone(publication.NoRedirect().redirect_request(None, None, 302, "", {}, "https://evil.test"))
        reader = publication.Reader("asc-secret", "github-secret")
        for url in ("https://api.github.com.evil.test/", "https://evil.test/", "http://api.appstoreconnect.apple.com/v1/builds"):
            with self.assertRaises(ValueError):
                reader.read(url)

    def test_source_lookup_requires_full_matching_sha(self):
        reader = publication.Reader("asc", "github")
        with patch.object(reader, "read", return_value={"sha": "b" * 40}):
            with self.assertRaises(ValueError):
                reader.source("a" * 12)


if __name__ == "__main__":
    unittest.main()
