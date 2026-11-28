#!/usr/bin/env python3
"""Behavioral checks for scripts/ci/mobile_pair_shipped_window.py."""
import io
import copy
from email.utils import format_datetime
import importlib.util
import json
from pathlib import Path
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/mobile_pair_shipped_window.py"
SPEC = importlib.util.spec_from_file_location("window", SCRIPT)
window = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(window)


class ShippedWindowTests(unittest.TestCase):
    def setUp(self):
        self.registry = json.loads(SCRIPT.with_suffix(".json").read_text())
        for release in self.registry["releases"][:3]:
            release["evidence"]["run_attempt"] = 1

    def test_seed_is_three_published_builds_each_direction(self):
        result = window.resolve(self.registry)
        self.assertEqual(len(result["include"]), 6)
        self.assertEqual({r["role"] for r in result["include"]}, {"host", "dial"})
        self.assertEqual(len(result["fingerprint"]), 64)

    def test_source_deduplication_keeps_all_release_ids(self):
        releases = self.registry["releases"]
        releases[1]["sha"] = releases[0]["sha"]
        result = window.resolve(self.registry)
        self.assertEqual(len(result["include"]), 5)
        self.assertEqual(result["include"][0]["release_ids"],
                         ["20261127140252", "20261127130434"])

    def test_count_is_releases_not_distinct_sources(self):
        for release in self.registry["releases"][:3]:
            release["sha"] = "a" * 40
        self.assertEqual(len(window.resolve(self.registry)["include"]), 4)

    def test_missing_platform_fails_closed(self):
        self.registry["releases"] = self.registry["releases"][:3]
        with self.assertRaisesRegex(ValueError, "mac: need 3"):
            window.resolve(self.registry)

    def test_successful_compilation_is_not_a_release(self):
        self.registry["releases"][0]["evidence"]["kind"] = "build-success"
        with self.assertRaisesRegex(ValueError, "not publication"):
            window.resolve(self.registry)

    def test_duplicate_release_does_not_fill_window(self):
        self.registry["releases"][1] = copy.deepcopy(self.registry["releases"][0])
        with self.assertRaisesRegex(ValueError, "duplicate"):
            window.resolve(self.registry)

    def test_new_release_rolls_oldest_out_and_changes_fingerprint(self):
        before = window.resolve(self.registry)
        release = copy.deepcopy(self.registry["releases"][0])
        release.update(release_id="new-build", sha="f"*40,
                       published_at="2026-11-28T00:00:00Z")
        after = window.resolve(window.record(self.registry, release))
        self.assertNotEqual(before["fingerprint"], after["fingerprint"])
        self.assertEqual(after["include"][0]["sha"], "f"*40)
        self.assertNotIn("20261127025823",
                         [i for r in after["include"] for i in r["release_ids"]])

    def test_registry_order_does_not_change_fingerprint(self):
        before = window.resolve(self.registry)
        self.registry["releases"].reverse()
        self.assertEqual(before, window.resolve(self.registry))

    def test_rerun_is_idempotent_but_cannot_reassign_release(self):
        release = copy.deepcopy(self.registry["releases"][0])
        self.assertEqual(window.record(self.registry, release), self.registry)
        release["sha"] = "f"*40
        with self.assertRaisesRegex(ValueError, "cannot change"):
            window.record(self.registry, release)

    def test_malformed_receipts_fail_closed(self):
        for field, value in (("sha", "abc"), ("published_at", "2026-11-28"),
                             ("release_id", ""), ("evidence", None)):
            with self.subTest(field=field):
                registry = copy.deepcopy(self.registry)
                registry["releases"][0][field] = value
                with self.assertRaises(ValueError):
                    window.resolve(registry)


    def feed(self, history=True):
        mac = self.registry["releases"][3:]
        root = window.ET.Element("rss")
        channel = window.ET.SubElement(root, "channel")
        for release in mac[:2]:
            item = window.ET.SubElement(channel, "item")
            window.ET.SubElement(item, "pubDate").text = format_datetime(window.timestamp(release["published_at"]))
            window.ET.SubElement(item, window.SPARKLE_NS + "version").text = release["release_id"]
            window.ET.SubElement(item, window.CMUX_NS + "sourceCommit").text = release["sha"]
            window.ET.SubElement(item, "enclosure", url=release["evidence"]["url"])
        if history:
            entries = window.ET.SubElement(channel, window.CMUX_NS + "publicationHistory", schemaVersion="1")
            for release in mac:
                window.ET.SubElement(entries, window.CMUX_NS + "publication", {
                    "build": release["release_id"], "sourceCommit": release["sha"],
                    "pubDate": format_datetime(window.timestamp(release["published_at"])),
                    "enclosure": release["evidence"]["url"],
                })
        return window.ET.tostring(root, encoding="unicode")

    def snapshot(self):
        releases = copy.deepcopy(self.registry["releases"][:3])
        for index, release in enumerate(releases):
            release["uploaded_at"] = release.pop("published_at")
            release["evidence"] = {
                "kind": "testflight-available", "url": "https://api.appstoreconnect.apple.com/v1/builds/" + str(index),
                "asc_build_id": str(index), "internal_build_state": "IN_BETA_TESTING",
            }
        return {"schema_version": 1, "status": "complete", "generated_at": "2026-11-28T00:00:00Z", "releases": releases,
                "app_id": "6791408425", "order": "uploadedDate-desc",
                "request": {"repository": window.REPO, "head_sha": "b"*40, "request_id": "123:1"},
                "producer": {"run_id": "456", "run_attempt": "1", "workflow_sha": "c"*40,
                             "workflow_ref": window.IOS_SNAPSHOT_REF}}

    def archive(self, snapshot):
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w") as archive:
            archive.writestr("ios-publication.json", json.dumps(snapshot))
        return output.getvalue()

    def reader(self, snapshot=None, feed=None, run_mutation=None, artifacts_mutation=None):
        snapshot = self.snapshot() if snapshot is None else snapshot
        feed = self.feed() if feed is None else feed
        calls = []
        run = {"id": 456, "event": "workflow_dispatch", "path": window.IOS_SNAPSHOT_WORKFLOW,
               "head_branch": window.IOS_SNAPSHOT_BRANCH, "head_sha": "c"*40, "conclusion": "success",
               "status": "completed", "run_attempt": 1, "repository": {"full_name": window.REPO}}
        artifacts = {"total_count": 1, "artifacts": [{"id": 789, "name": "ios-publication-snapshot-123-1",
                     "expired": False, "size_in_bytes": 999}]}
        if run_mutation:
            run.update(run_mutation)
        if artifacts_mutation:
            artifacts.update(artifacts_mutation)
        class Reader:
            def read(inner, url):
                calls.append(url)
                self.assertEqual(url, window.APPCAST)
                return feed
            def api(inner, path, **query):
                calls.append(path)
                if path == "actions/runs/456":
                    self.assertEqual(query, {})
                    return run
                self.assertEqual(path, "actions/runs/456/artifacts")
                self.assertEqual(query, {"per_page": 100})
                return artifacts
            def artifact(inner, artifact_id):
                calls.append(artifact_id)
                self.assertEqual(artifact_id, 789)
                return self.archive(snapshot)
        return Reader(), calls

    def refresh(self, snapshot=None, feed=None, registry=None):
        reader, calls = self.reader(snapshot, feed)
        result = window.refresh(self.registry if registry is None else registry, reader,
                                producer_run="456", producer_sha="c"*40, request_id="123:1", head_sha="b"*40)
        self.assertEqual(len(calls), 4)
        return result

    def trusted(self, reader):
        return window.trusted_ios_snapshot(reader, producer_run="456", producer_sha="c"*40,
                                          request_id="123:1", head_sha="b"*40)

    def test_authority_reads_replace_cached_history_with_bounded_provenance(self):
        result = window.resolve(self.refresh())
        self.assertEqual(result["include"], window.resolve(self.registry)["include"])

    def test_old_run_outside_twenty_run_snapshot_is_selected_from_publisher(self):
        snapshot = self.snapshot()
        snapshot["releases"][0].update(sha="f"*40, release_id="20261128000000", uploaded_at="2026-11-28T00:00:00Z")
        result = window.resolve(self.refresh(snapshot))
        self.assertEqual(result["include"][0]["sha"], "f"*40)
        self.assertEqual(result["include"][0]["release_ids"], ["20261128000000"])
        # Reader has no run-list or log interface: creation order is irrelevant.

    def test_pending_or_failed_publication_never_reuses_complete_seed(self):
        for state in ("pending", "error", None):
            snapshot = self.snapshot()
            snapshot["status"] = state
            with self.subTest(state=state), self.assertRaisesRegex(ValueError, "not complete"):
                self.refresh(snapshot)

    def test_processed_but_unavailable_ios_build_is_not_shipped(self):
        snapshot = self.snapshot()
        snapshot["releases"][0]["evidence"]["internal_build_state"] = "PROCESSING"
        with self.assertRaisesRegex(ValueError, "available INTERNAL"):
            self.refresh(snapshot)

    def test_no_mac_history_fails_even_with_a_complete_cached_window(self):
        with self.assertRaisesRegex(ValueError, "publisher-owned"):
            self.refresh(feed=self.feed(history=False))

    def test_second_predecessor_cannot_be_inferred_from_matching_source(self):
        feed = window.ET.fromstring(self.feed())
        history = feed.find("./channel/" + window.CMUX_NS + "publicationHistory")
        history.remove(list(history)[-1])
        with self.assertRaisesRegex(ValueError, "needs 3"):
            self.refresh(feed=window.ET.tostring(feed, encoding="unicode"))

    def test_history_must_match_live_head_and_source(self):
        for field, value in (("build", "other"), ("sourceCommit", "f"*40)):
            feed = window.ET.fromstring(self.feed())
            history = feed.find("./channel/" + window.CMUX_NS + "publicationHistory")
            history[0].set(field, value)
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "live"):
                self.refresh(feed=window.ET.tostring(feed, encoding="unicode"))

    def test_mixed_ring_feed_uses_nightly_only_and_numeric_latest(self):
        root = window.ET.fromstring(self.feed())
        channel = root.find("channel")
        live = channel.findall("item")
        channel.remove(live[0])
        channel.append(live[0])
        dev = window.ET.Element("item")
        window.ET.SubElement(dev, window.SPARKLE_NS + "version").text = "9999999999999"
        window.ET.SubElement(dev, window.SPARKLE_NS + "channel").text = "cmux-next-dev"
        channel.insert(0, dev)
        result = window.resolve(self.refresh(feed=window.ET.tostring(root, encoding="unicode")))
        self.assertEqual(result["include"][3]["sha"], self.registry["releases"][3]["sha"])
        self.assertEqual(len(result["include"]), 6)

    def test_repeated_source_builds_keep_release_order_and_deduplicate_compilation(self):
        self.registry["releases"][4]["sha"] = self.registry["releases"][3]["sha"]
        result = window.resolve(self.refresh())
        self.assertEqual(len(result["include"]), 5)
        self.assertEqual(len(result["include"][3]["release_ids"]), 2)

    def test_publisher_order_survives_same_build_delta_date_rewrite(self):
        feed = window.ET.fromstring(self.feed())
        feed.find("./channel/item/pubDate").text = "Fri, 27 Nov 2026 01:00:00 +0000"
        result = window.resolve(self.refresh(feed=window.ET.tostring(feed, encoding="unicode")))
        self.assertEqual(result["include"][3]["sha"], self.registry["releases"][3]["sha"])

    def test_asc_upload_date_is_not_fabricated_publication_time(self):
        result = self.refresh()
        self.assertNotIn("published_at", result["releases"][0])
        self.assertIn("uploaded_at", result["releases"][0])

    def test_unordered_asc_snapshot_is_rejected(self):
        snapshot = self.snapshot()
        snapshot["releases"].reverse()
        with self.assertRaisesRegex(ValueError, "uploadedDate order"):
            self.refresh(snapshot)

    def test_authority_requires_complete_unique_available_window(self):
        for mutation in (lambda r: r.pop(), lambda r: r.__setitem__(1, r[0])):
            snapshot = self.snapshot()
            mutation(snapshot["releases"])
            with self.assertRaises(ValueError):
                self.refresh(snapshot)

    def test_no_stale_fallback_on_network_failure(self):
        class Reader:
            def read(inner, url):
                raise OSError("rate limit")
        with self.assertRaisesRegex(OSError, "rate limit"):
            window.refresh(self.registry, Reader(), producer_run="456", producer_sha="c"*40,
                           request_id="123:1", head_sha="b"*40)

    def test_repeated_refresh_uses_authority_even_after_persisting_previous_output(self):
        first = self.refresh()
        second = self.refresh(registry=json.loads(json.dumps(first)))
        self.assertEqual(window.resolve(first), window.resolve(second))

    def test_reader_rejects_token_on_other_origins_before_network(self):
        with self.assertRaisesRegex(ValueError, "token may only"):
            window.PublicationReader("not-a-real-token").read("https://example.test/logs", authenticated=True)

    def test_forged_producer_or_wrong_ref_is_rejected_before_artifact_download(self):
        for mutation in ({"head_sha": "d"*40}, {"path": ".github/workflows/untrusted.yml"},
                         {"head_branch": "lane/untrusted"}, {"event": "pull_request"},
                         {"conclusion": "failure"}, {"status": "in_progress"},
                         {"repository": {"full_name": "outsider/cmux"}}):
            reader, calls = self.reader(run_mutation=mutation)
            with self.subTest(mutation=mutation), self.assertRaisesRegex(ValueError, "exact protected"):
                self.trusted(reader)
            self.assertEqual(len(calls), 1)

    def test_old_head_request_and_rerun_artifacts_are_rejected(self):
        for group, key, value in (("request", "head_sha", "d"*40), ("request", "request_id", "123:2"),
                                  ("producer", "run_attempt", "2"), ("producer", "workflow_sha", "d"*40),
                                  ("producer", "workflow_ref", "other")):
            snapshot = self.snapshot()
            snapshot[group][key] = value
            reader, _ = self.reader(snapshot)
            with self.subTest(group=group, key=key), self.assertRaisesRegex(ValueError, "bound to this request"):
                self.trusted(reader)

    def test_truncated_artifact_list_cannot_choose_an_ambiguous_snapshot(self):
        reader, calls = self.reader(artifacts_mutation={"total_count": 101})
        with self.assertRaisesRegex(ValueError, "exceeds its bound"):
            self.trusted(reader)
        self.assertEqual(len(calls), 2)

    def test_wrong_product_snapshot_is_rejected(self):
        snapshot = self.snapshot()
        snapshot["app_id"] = "other-product"
        reader, _ = self.reader(snapshot)
        with self.assertRaisesRegex(ValueError, "INTERNAL available"):
            self.trusted(reader)

    def test_archive_is_bounded_and_never_extracted(self):
        reader, _ = self.reader()
        for oversized in (False, True):
            output = io.BytesIO()
            with zipfile.ZipFile(output, "w") as archive:
                archive.writestr("ios-publication.json" if oversized else "../outside.json",
                                 "x"*100001 if oversized else "{}")
            reader.artifact = lambda artifact_id: output.getvalue()
            with self.subTest(oversized=oversized), self.assertRaisesRegex(ValueError, "unexpected contents"):
                self.trusted(reader)


if __name__ == "__main__":
    unittest.main()
