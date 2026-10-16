#!/usr/bin/env python3
"""The cache census must measure honestly and never mutate the bucket."""
from __future__ import annotations

import datetime as dt
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "r2_cache_census.py"

spec = importlib.util.spec_from_file_location("r2_cache_census", SCRIPT)
census = importlib.util.module_from_spec(spec)
spec.loader.exec_module(census)

NOW = dt.datetime(2026, 9, 22, tzinfo=dt.timezone.utc)


def page(objects, token=None):
    body = "".join(
        f"<Contents><Key>{key}</Key><Size>{size}</Size>"
        f"<LastModified>{modified}</LastModified></Contents>"
        for key, size, modified in objects
    )
    truncated = "true" if token else "false"
    next_token = f"<NextContinuationToken>{token}</NextContinuationToken>" if token else ""
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
        f"<IsTruncated>{truncated}</IsTruncated>{body}{next_token}</ListBucketResult>"
    )


def days_ago(days):
    return (NOW - dt.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%S.000Z")


class ParsingTests(unittest.TestCase):
    def test_pagination_follows_continuation_tokens(self):
        pages = {
            None: page([("v1/macos-arm64/objects/a.tar.zst", 10, days_ago(1))], token="t1"),
            "t1": page([("v1/macos-arm64/objects/b.tar.zst", 20, days_ago(2))]),
        }
        calls = []

        def lister(endpoint, bucket, token):
            calls.append(token)
            return pages[token]

        objects, complete = census.collect("https://r2.example", "cache", lister=lister)
        self.assertEqual(calls, [None, "t1"])
        self.assertEqual([item["size"] for item in objects], [10, 20])
        self.assertTrue(complete)

    def test_repeated_continuation_token_stops_instead_of_spinning(self):
        def lister(endpoint, bucket, token):
            return page([("v1/macos-arm64/objects/a.tar.zst", 1, days_ago(1))], token="same")

        objects, complete = census.collect("https://r2.example", "cache", lister=lister)
        # Two passes: the first token is new, the repeat ends the walk.
        self.assertEqual(len(objects), 2)
        # An early stop must not read as a full census.
        self.assertFalse(complete)

    def test_truncated_page_without_a_token_terminates(self):
        body = page([("v1/macos-arm64/objects/a.tar.zst", 1, days_ago(1))], token="x")
        body = body.replace("<NextContinuationToken>x</NextContinuationToken>", "")
        _, token, truncated = census.parse_page(body)
        self.assertIsNone(token)
        # Truncated with no token: more objects exist that we cannot reach.
        self.assertTrue(truncated)


class SummaryTests(unittest.TestCase):
    def test_archives_and_pointers_are_counted_separately(self):
        objects = [
            {"key": "v1/macos-arm64/objects/a.tar.zst", "size": 100, "last_modified": days_ago(1)},
            {"key": "v1/macos-arm64/latest/deps-", "size": 5, "last_modified": days_ago(1)},
        ]
        summary = census.summarize(objects, NOW, None)
        self.assertEqual(summary["total"]["archives"], 1)
        self.assertEqual(summary["total"]["pointers"], 1)
        self.assertEqual(summary["total"]["bytes"], 105)

    def test_age_rule_models_archives_only_and_spares_pointers(self):
        objects = [
            {"key": "v1/macos-arm64/objects/old.tar.zst", "size": 900, "last_modified": days_ago(90)},
            {"key": "v1/macos-arm64/objects/new.tar.zst", "size": 100, "last_modified": days_ago(3)},
            # An ancient pointer must never be counted as reclaimable: it is the
            # index into objects/ and costs almost nothing to keep.
            {"key": "v1/macos-arm64/latest/deps-", "size": 5, "last_modified": days_ago(365)},
        ]
        summary = census.summarize(objects, NOW, 30)
        self.assertEqual(summary["reclaim"]["objects"], 1)
        self.assertEqual(summary["reclaim"]["bytes"], 900)

    def test_no_max_age_reports_no_reclaim_estimate(self):
        objects = [{"key": "v1/a-b/objects/x.tar.zst", "size": 1, "last_modified": days_ago(400)}]
        self.assertIsNone(census.summarize(objects, NOW, None)["reclaim"])

    def test_namespaces_are_grouped_by_os_arch(self):
        objects = [
            {"key": "v1/macos-arm64/objects/a.tar.zst", "size": 10, "last_modified": days_ago(1)},
            {"key": "v1/linux-x64/objects/b.tar.zst", "size": 20, "last_modified": days_ago(1)},
        ]
        summary = census.summarize(objects, NOW, None)
        self.assertEqual(sorted(summary["namespaces"]), ["v1/linux-x64", "v1/macos-arm64"])

    def test_unreadable_timestamp_is_reported_not_silently_reclaimed(self):
        objects = [{"key": "v1/a-b/objects/x.tar.zst", "size": 500, "last_modified": "not-a-date"}]
        summary = census.summarize(objects, NOW, 30)
        self.assertEqual(summary["objects_without_timestamp"], 1)
        self.assertEqual(summary["reclaim"]["bytes"], 0)


    def test_namespace_with_no_readable_timestamp_is_not_reported_as_new(self):
        # "oldest 0d" would read as brand-new data and understate retention.
        objects = [{"key": "v1/a-b/objects/x.tar.zst", "size": 500, "last_modified": "not-a-date"}]
        summary = census.summarize(objects, NOW, None)
        self.assertIsNone(summary["namespaces"]["v1/a-b"]["oldest_days"])
        self.assertIn("oldest unknown", census.render(summary))

    def test_an_incomplete_walk_is_labelled_and_not_presented_as_a_census(self):
        objects = [{"key": "v1/a-b/objects/x.tar.zst", "size": 500, "last_modified": days_ago(1)}]
        rendered = census.render(census.summarize(objects, NOW, None, False))
        self.assertIn("INCOMPLETE", rendered)
        self.assertIn("lower bounds", rendered)
        self.assertNotIn("INCOMPLETE", census.render(census.summarize(objects, NOW, None, True)))


class SafetyTests(unittest.TestCase):
    def test_script_issues_no_mutating_verbs(self):
        source = SCRIPT.read_text(encoding="utf-8")
        for verb in ('"DELETE"', '"PUT"', '"POST"', "delete_objects", "DeleteObject"):
            self.assertNotIn(verb, source, f"census must stay read-only, found {verb}")
        self.assertIn('method="GET"', source)

    def test_only_report_mode_exists(self):
        with self.assertRaises(SystemExit):
            census.main(["apply", "--endpoint-url", "https://r2.example", "--bucket", "cache"])

    def test_nonpositive_max_age_is_rejected(self):
        with self.assertRaises(SystemExit):
            census.main([
                "report", "--endpoint-url", "https://r2.example",
                "--bucket", "cache", "--max-age-days", "0",
            ])


if __name__ == "__main__":
    unittest.main(verbosity=2)
