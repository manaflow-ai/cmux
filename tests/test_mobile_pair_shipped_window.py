#!/usr/bin/env python3
"""Behavioral checks for scripts/ci/mobile_pair_shipped_window.py."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/mobile_pair_shipped_window.py"
SPEC = importlib.util.spec_from_file_location("window", SCRIPT)
window = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(window)


class ShippedWindowTests(unittest.TestCase):
    def setUp(self):
        self.registry = json.loads(SCRIPT.with_suffix(".json").read_text())

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


    def test_live_refresh_reuses_verified_ios_logs_and_mac_history(self):
        class Reader:
            def read(inner, url):
                self.assertEqual(url, window.APPCAST)
                return self.feed()
            def api(inner, path, **query):
                self.assertEqual(path, "actions/workflows/ios-internal-nightly.yml/runs")
                return {"workflow_runs": self.ios_runs()}
            def log(inner, job_id):
                self.fail("cached publication must not refetch logs")
        result = window.refresh(self.registry, Reader())
        self.assertEqual(window.resolve(result)["include"],
                         window.resolve(self.registry)["include"])

    def test_live_refresh_never_fills_missing_ios_with_stale_seed(self):
        class Reader:
            def read(inner, url):
                return self.feed()
            def api(inner, path, **query):
                return {"workflow_runs": []}
        with self.assertRaisesRegex(ValueError, "ios: need 3"):
            window.refresh(self.registry, Reader())

    def test_green_run_without_upload_step_is_not_shipped(self):
        class Reader:
            def read(inner, url):
                return self.feed()
            def api(inner, path, **query):
                if path.endswith("/runs"):
                    return {"workflow_runs": [{
                        "id": 99, "conclusion": "success",
                        "display_title": "cmux-next-ios INTERNAL " + "f"*40,
                    }]}
                return {"jobs": [{"name": "Archive (unsigned, no secrets)",
                                  "conclusion": "success", "steps": []}]}
        with self.assertRaisesRegex(ValueError, "ios: need 3"):
            window.refresh(self.registry, Reader())

    def test_upload_without_processing_receipt_is_not_shipped(self):
        run = {"id": 1, "display_title": "cmux-next-ios INTERNAL " + "f"*40}
        with self.assertRaisesRegex(ValueError, "no processed"):
            window.ios_receipt(run, {"id": 2}, "Uploaded successfully")

    def test_processed_receipt_binds_build_to_dispatched_source(self):
        run = {"id": 1, "display_title": "cmux-next-ios INTERNAL " + "f"*40}
        result = window.ios_receipt(run, {"id": 2},
            "2026-11-27T14:16:00Z ==> wait for App Store Connect to process 20261127140252\n"
            "2026-11-27T14:20:45Z - Uploaded to cmux INTERNAL at 2026-11-27T14:20:44Z; processed.\n")
        self.assertEqual(result["sha"], "f"*40)
        self.assertEqual(result["release_id"], "20261127140252")

    def test_historical_mac_requires_source_and_live_readback(self):
        log = ("2026-11-27T05:17:35Z source_sha=" + "c"*40 + "\n"
               "2026-11-27T05:17:36Z the live feed's newest build is 12301, the build this run published\n")
        result = window.mac_receipt({"id": 1}, {"id": 2}, log, "c"*40)
        self.assertEqual(result["release_id"], "12301")
        with self.assertRaisesRegex(ValueError, "no matching"):
            window.mac_receipt({"id": 1}, {"id": 2}, log, "f"*40)

    def test_live_failure_propagates_instead_of_falling_back_to_seed(self):
        class Reader:
            def read(inner, url):
                raise OSError("rate limit")
        with self.assertRaisesRegex(OSError, "rate limit"):
            window.refresh(self.registry, Reader())

    def ios_runs(self):
        return [{"id": run, "display_title": "cmux-next-ios INTERNAL " + entry["sha"]}
                for run, entry in zip((46011215834, 46002620214, 45931253674),
                                      self.registry["releases"][:3])]

    def feed(self):
        mac = self.registry["releases"][3:]
        items = []
        for index, release in enumerate(mac[:2]):
            items.append(
                "<item><pubDate>" + (
                    "Fri, 27 Nov 2026 11:49:55 +0000" if index == 0
                    else "Fri, 27 Nov 2026 11:35:31 +0000") +
                "</pubDate><sparkle:version>" + release["release_id"] +
                "</sparkle:version><cmux:sourceCommit>" + release["sha"] +
                "</cmux:sourceCommit><cmux:sinceCommit>" + mac[index+1]["sha"] +
                "</cmux:sinceCommit><enclosure url='" + release["evidence"]["url"] + "'/></item>")
        return ("<rss xmlns:cmux='https://cmux.com/xml-namespaces/cmux' "
                "xmlns:sparkle='http://www.andymatuschak.org/xml-namespaces/sparkle'>"
                "<channel>" + "".join(items) + "</channel></rss>")


    def test_live_new_ios_build_replaces_oldest_and_needs_processing(self):
        runs = self.ios_runs()
        new_run = {"id": 99, "display_title": "cmux-next-ios INTERNAL " + "f"*40}
        class Reader:
            def read(inner, url):
                return self.feed()
            def api(inner, path, **query):
                if path.endswith("/runs"):
                    return {"workflow_runs": [new_run] + runs}
                self.assertEqual(path, "actions/runs/99/jobs")
                return {"jobs": [{
                    "id": 100, "name": "Sign, validate, upload to cmux INTERNAL",
                    "conclusion": "success",
                    "steps": [{"name": "Sign, validate, upload", "conclusion": "success"}],
                }]}
            def log(inner, job_id):
                self.assertEqual(job_id, 100)
                return ("==> wait for App Store Connect to process 20261128000000\n"
                        "- Uploaded to cmux INTERNAL at 2026-11-28T00:01:00Z; processed.\n")
        result = window.resolve(window.refresh(self.registry, Reader()))
        self.assertEqual(result["include"][0]["sha"], "f"*40)
        self.assertNotIn("20261127025823",
                         [i for r in result["include"] for i in r["release_ids"]])

    def test_live_mac_predecessor_requires_historical_publication(self):
        registry = copy.deepcopy(self.registry)
        third = registry["releases"].pop()
        class Reader:
            def read(inner, url):
                return self.feed()
            def api(inner, path, **query):
                if path == "actions/workflows/nightly.yml/runs":
                    self.assertEqual(query["head_sha"], third["sha"])
                    return {"workflow_runs": [{"id": 99}]}
                if path == "actions/runs/99/jobs":
                    return {"jobs": [{
                        "id": 100, "name": "published-build", "conclusion": "success",
                        "steps": [{"name": "Read the published build back from the live feed",
                                   "conclusion": "success"}],
                    }]}
                return {"workflow_runs": self.ios_runs()}
            def log(inner, job_id):
                return ("2026-11-27T05:17:35Z source_sha=" + third["sha"] + "\n"
                        "2026-11-27T05:17:35Z the live feed's newest build is "
                        + third["release_id"] + ", the build this run published\n")
        result = window.resolve(window.refresh(registry, Reader()))
        self.assertEqual(result["include"][-1]["sha"], third["sha"])

    def test_reader_rejects_token_on_other_origins_before_network(self):
        with self.assertRaisesRegex(ValueError, "token may only"):
            window.PublicationReader("not-a-real-token").read(
                "https://example.test/logs", authenticated=True)


if __name__ == "__main__":
    unittest.main()
