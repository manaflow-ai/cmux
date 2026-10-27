#!/usr/bin/env python3
"""scripts/ci/nightly_next_r2_prune.py: never deletes what a feed names, a newest build or a new object."""
from __future__ import annotations

import datetime as dt
import importlib.util
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
spec = importlib.util.spec_from_file_location("nightly_next_r2_prune", ROOT / "scripts" / "ci" / "nightly_next_r2_prune.py")
prune = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prune)

PREFIX = "nightly-next/next/"
FEED = PREFIX + "appcast-arm64.xml"
NOW = dt.datetime(2026, 11, 30, tzinfo=dt.timezone.utc)
BASE = "https://files-next.cmux.com/nightly-next/next/"
GH = "https://github.com/manaflow-ai/cmux/releases/download/nightly-next/"


def dmg(build: int) -> str:
    return f"cmux-nightly-next-macos-arm64-{build}.dmg"


def delta(build: int, base: int) -> str:
    return f"cmux-nightly-next-macos-arm64-{build}-{base}.delta"


def feed(*names: str) -> bytes:
    items = "".join(f'<item><sparkle:version>1</sparkle:version><enclosure url="{BASE}{n}" length="1"/></item>'
                    for n in names)
    return (f'<rss xmlns:sparkle="{prune.SPARKLE_NS}"><channel>{items}</channel></rss>').encode()


class FakeBucket:
    def __init__(self, objects: dict[str, int], feeds: dict[str, bytes], complete: bool = True,
                 feeds_after: dict[str, bytes] | None = None):
        self.prefix = PREFIX
        self.objects, self.feeds, self.complete = objects, feeds, complete
        self.feeds_after = feeds_after
        self.reads = 0
        self.deleted: list[str] = []

    def list(self):
        return [{"key": k, "size": 100, "last_modified": (NOW - dt.timedelta(days=age)).isoformat()}
                for k, age in self.objects.items()], self.complete

    def read(self, key):
        self.reads += 1
        source = self.feeds_after if (self.feeds_after is not None and self.reads > len(self.feeds)) else self.feeds
        if key not in source:
            raise prune.urllib.error.HTTPError(key, 404, "Not Found", {}, None)
        return source[key]

    def delete(self, key):
        self.deleted.append(key)


def objects(builds: range, age: int = 30) -> dict[str, int]:
    out = {}
    for b in builds:
        out[PREFIX + dmg(b)] = age
        out[PREFIX + delta(b, b - 1)] = age
    return out


class PruneTests(unittest.TestCase):
    def run_prune(self, bucket, keep_builds=3, min_age=7, delete=True):
        return prune.prune(bucket, [FEED], keep_builds, min_age, NOW, delete)

    def test_keeps_the_feed_the_newest_builds_and_new_objects(self) -> None:
        objs = objects(range(100, 120))
        objs[PREFIX + dmg(101)] = 1  # new: kept by age
        others = {PREFIX + "appcast-arm64.xml": 90, PREFIX + "notes/index.json": 90,
                  PREFIX + "dsyms/x.zip": 90, PREFIX + "sub/" + dmg(100): 90, "elsewhere/" + dmg(100): 90}
        objs.update(others)
        # The feed names an old full DMG and an old delta.
        bucket = FakeBucket(objs, {FEED: feed(dmg(119), delta(119, 118), dmg(105), delta(106, 105))})
        summary = self.run_prune(bucket)
        deleted = {k[len(PREFIX):] for k in bucket.deleted}
        for kept in (dmg(105), delta(106, 105), dmg(101), dmg(117), dmg(118), dmg(119), delta(117, 116)):
            self.assertNotIn(kept, deleted)
        self.assertIn(dmg(100), deleted)
        self.assertIn(delta(116, 115), deleted)
        self.assertTrue(all(k.startswith(PREFIX) and "/" not in k[len(PREFIX):] for k in bucket.deleted))
        self.assertFalse(set(others) & set(bucket.deleted))
        self.assertEqual(summary["kept_by_feed"], 4)

    def test_a_dry_run_deletes_nothing(self) -> None:
        bucket = FakeBucket(objects(range(100, 120)), {FEED: feed(dmg(119))})
        summary = self.run_prune(bucket, delete=False)
        self.assertEqual(bucket.deleted, [])
        self.assertIn(dmg(100), summary["candidates"])
        self.assertIn("would delete", prune.render(summary))

    def test_fails_closed(self) -> None:
        for feeds, complete in (({}, True),                                   # feed missing
                                ({FEED: b"not xml"}, True),                   # unreadable
                                ({FEED: b"<rss><channel/></rss>"}, True),     # no items
                                ({FEED: feed(dmg(119))}, False)):             # listing incomplete
            bucket = FakeBucket(objects(range(100, 120)), feeds, complete)
            with self.assertRaises(prune.Refused):
                self.run_prune(bucket)
            self.assertEqual(bucket.deleted, [])

    def test_a_feed_that_changes_before_the_deletes_is_read_again(self) -> None:
        bucket = FakeBucket(objects(range(100, 120)), {FEED: feed(dmg(119))},
                            feeds_after={FEED: feed(dmg(119), dmg(100))})
        self.run_prune(bucket)
        self.assertNotIn(PREFIX + dmg(100), bucket.deleted)
        self.assertIn(PREFIX + dmg(102), bucket.deleted)

    def test_a_github_enclosure_name_is_kept_too(self) -> None:
        bucket = FakeBucket(objects(range(100, 120)), {FEED: feed(dmg(119)).replace(
            b"</channel>", f'<item><enclosure url="{GH}{dmg(100)}"/></item></channel>'.encode())})
        self.run_prune(bucket)
        self.assertNotIn(PREFIX + dmg(100), bucket.deleted)

    def test_the_cli_refuses_unsafe_settings(self) -> None:
        for argv in (["--prefix", "nightly-next/next"], ["--keep-builds", "1"], ["--min-age-days", "0"]):
            with self.assertRaises(SystemExit):
                prune.main(["--endpoint-url", "https://x", "--bucket", "b", "--prefix", PREFIX, "--feed", FEED, *argv])


if __name__ == "__main__":
    unittest.main(verbosity=2)
