#!/usr/bin/env python3
"""Authoritative available TestFlight window, not creation-ordered Actions runs."""
from __future__ import annotations

from datetime import datetime, timezone
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ios_publication_snapshot", ROOT / "scripts/ci/ios_publication_snapshot.py")
publication = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publication)
PRODUCER = {"run_id": "123", "run_attempt": "2", "workflow_sha": "f" * 40,
            "workflow_ref": "manaflow-ai/cmux/.github/workflows/ios-publication-snapshot.yml@refs/heads/rc/cnx-ios-builder"}
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


class WorkflowTests(unittest.TestCase):
    def test_secret_job_executes_only_protected_code(self):
        workflow = (ROOT / ".github/workflows/ios-publication-snapshot.yml").read_text()
        self.assertIn("github.ref == 'refs/heads/rc/cnx-ios-builder'", workflow)
        self.assertIn("environment: release", workflow)
        self.assertIn("ref: ${{ github.sha }}", workflow)
        self.assertNotIn("ref: ${{ inputs.head_sha }}", workflow)
        self.assertIn("--head-sha \"$HEAD_SHA\" --request-id \"$REQUEST_ID\"", workflow)
        self.assertIn("scripts/ci/ios_publication_snapshot.py", workflow)
        self.assertIn("if-no-files-found: error", workflow)
        self.assertIn("${REQUEST_ID/:/-}", workflow)


if __name__ == "__main__":
    unittest.main()
