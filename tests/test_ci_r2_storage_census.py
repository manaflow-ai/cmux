#!/usr/bin/env python3
"""The R2 storage census groups keys into one row per build family and never writes."""
import datetime as dt
from pathlib import Path
import sys
import unittest
import urllib.error

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import r2_storage_census as census  # noqa: E402

NOW = dt.datetime(2026, 10, 11, tzinfo=dt.timezone.utc)
SHA_A = "0123456789abcdef0123456789abcdef01234567"
SHA_B = "fedcba9876543210fedcba9876543210fedcba98"


def stamp(days):
    return (NOW - dt.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def page(objects, token=None):
    contents = "".join(
        f"<Contents><Key>{key}</Key><Size>{size}</Size><LastModified>{stamp(age)}</LastModified></Contents>"
        for key, size, age in objects
    )
    truncated = "true" if token else "false"
    next_token = f"<NextContinuationToken>{token}</NextContinuationToken>" if token else ""
    return (f'<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">{contents}'
            f"<IsTruncated>{truncated}</IsTruncated>{next_token}</ListBucketResult>")


class Families(unittest.TestCase):
    def test_a_build_segment_ends_the_family(self):
        self.assertEqual(census.family_of(f"cmux-tui/{SHA_A}/linux-x64/cmux-tui"),
                         ("cmux-tui/<sha>", f"cmux-tui/{SHA_A}"))
        self.assertEqual(census.family_of("cmux-tui/tree/k1-9f8e7d6c5b4a39281706f5e4d3c2b1a0/source.json"),
                         ("cmux-tui/tree/<key>", "cmux-tui/tree/k1-9f8e7d6c5b4a39281706f5e4d3c2b1a0"))
        self.assertEqual(census.family_of("cef/146.0.6+g1a2b3c4/cef_binary.tar.bz2"),
                         ("cef/<version>", "cef/146.0.6+g1a2b3c4"))
        self.assertEqual(census.family_of("v1/macOS-ARM64/objects/spm-abc.tar.zst"),
                         ("v1/macOS-ARM64/objects", "v1/macOS-ARM64/objects"))

    def test_root_files_and_plain_words_are_not_builds(self):
        self.assertEqual(census.family_of("appcast.xml"), ("(root)", "(root)"))
        self.assertEqual(census.family_of("nightly/appcast-arm64.xml"), ("nightly", "nightly"))
        self.assertIsNone(census.placeholder("deadbeef"))  # a hex word with no digit is a name

    def test_rows_count_builds_and_split_bytes_by_age(self):
        summary = census.summarize([
            {"key": f"cmux-tui/{SHA_A}/a", "size": 100, "last_modified": stamp(2)},
            {"key": f"cmux-tui/{SHA_A}/b", "size": 50, "last_modified": stamp(2)},
            {"key": f"cmux-tui/{SHA_B}/a", "size": 300, "last_modified": stamp(120)},
            {"key": "latest.json", "size": 1, "last_modified": stamp(0)},
        ], NOW)
        top = summary["families"][0]
        self.assertEqual((top["family"], top["units"], top["objects"], top["bytes"]),
                         ("cmux-tui/<sha>", 2, 3, 450))
        self.assertEqual(top["bands"], {"<7d": 150, "7-30d": 0, "30-90d": 0, ">90d": 300})
        self.assertEqual((summary["objects"], summary["bytes"]), (4, 451))
        self.assertIn("| `cmux-tui/<sha>` | 2 | 3 |", census.render("b", summary, True))


class Listing(unittest.TestCase):
    def test_every_page_is_walked(self):
        pages = {None: page([("a/x", 1, 1)], token="t1"), "t1": page([("b/y", 2, 1)])}
        calls = []

        def getter(endpoint, path, query):
            calls.append((path, dict(query)))
            return pages[query.get("continuation-token")]

        lister = lambda endpoint, bucket, token: census.list_page(endpoint, bucket, token, getter=getter)
        objects, complete = census.census.collect("https://r2.example", "bin", lister=lister)
        self.assertTrue(complete)
        self.assertEqual([o["key"] for o in objects], ["a/x", "b/y"])
        # No prefix: the census sees the whole bucket, unlike the cache census's v1/.
        self.assertTrue(all("prefix" not in query for _, query in calls))
        self.assertTrue(all(path == "/bin" for path, _ in calls))

    def test_a_key_that_cannot_list_buckets_falls_back(self):
        def refused(endpoint, path, query):
            raise urllib.error.HTTPError("https://r2.example/", 403, "denied", {}, None)

        self.assertIsNone(census.list_buckets("https://r2.example", getter=refused))

    def test_listed_buckets_are_returned_sorted(self):
        xml = ('<ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Buckets>'
               "<Bucket><Name>cmux-cef</Name></Bucket><Bucket><Name>cmux-binaries</Name></Bucket>"
               "</Buckets></ListAllMyBucketsResult>")
        self.assertEqual(census.list_buckets("https://r2.example", getter=lambda *a: xml),
                         ["cmux-binaries", "cmux-cef"])


if __name__ == "__main__":
    unittest.main()
