#!/usr/bin/env python3
"""scripts/ci/stable_next.py: candidate pick, night window, feed merge and rollback."""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("stable_next", ROOT / "scripts/ci/stable_next.py")
stable_next = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stable_next)


def item(build: int, channel: str | None = "cmux-next", date: str = "Fri, 30 Oct 2026 00:34:42 +0000") -> str:
    tag = f"<sparkle:channel>{channel}</sparkle:channel>\n            " if channel else ""
    return (f"        <item>\n            {tag}<title>1.0.0-nightly.{build}</title>\n"
            f"            <pubDate>{date}</pubDate>\n"
            f"            <sparkle:version>{build}</sparkle:version>\n"
            f"            <sparkle:shortVersionString>1.0.0-nightly.{build}</sparkle:shortVersionString>\n"
            f"            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>\n"
            f'            <enclosure url="https://files-next.cmux.com/x/cmux-{build}.dmg" length="42" '
            f'type="application/octet-stream" sparkle:edSignature="sig"/>\n        </item>\n')


def feed(*bodies: str) -> str:
    return ('<?xml version="1.0" encoding="utf-8"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" '
            'version="2.0">\n    <channel>\n        <title>cmux NEXT</title>\n' + "".join(bodies) + "    </channel>\n</rss>\n")


class Window(unittest.TestCase):
    def at(self, iso: str) -> dict:
        return stable_next.window(dt.datetime.fromisoformat(iso))

    def test_opens_at_nine_pm_pacific_in_daylight_time(self):
        self.assertEqual(self.at("2026-10-30T03:59:00+00:00")["open"], "false")  # 20:59 PDT
        self.assertEqual(self.at("2026-10-30T04:00:00+00:00")["open"], "true")   # 21:00 PDT
        self.assertEqual(self.at("2026-10-30T04:00:00+00:00")["night_start"], "2026-10-30T04:00:00Z")

    def test_follows_standard_time_after_the_change(self):
        self.assertEqual(self.at("2026-11-03T04:30:00+00:00")["open"], "false")  # 20:30 PST
        self.assertEqual(self.at("2026-11-03T05:00:00+00:00")["open"], "true")   # 21:00 PST

    def test_after_midnight_counts_from_the_previous_evening(self):
        result = self.at("2026-10-30T12:30:00+00:00")  # 05:30 PDT
        self.assertEqual(result["open"], "true")
        self.assertEqual(result["night_start"], "2026-10-30T04:00:00Z")
        self.assertEqual(self.at("2026-10-30T14:00:00+00:00")["open"], "false")  # 07:00 PDT


class Pick(unittest.TestCase):
    def test_takes_the_newest_nightly_build_and_skips_dev_items(self):
        result = stable_next.pick(feed(item(300, "cmux-next-dev"), item(200), item(100)), None, set(), lambda b: None, None)
        self.assertEqual(result["build"], "200")
        self.assertEqual(result["run_id"], "2")
        self.assertEqual(result["skip"], "false")
        self.assertEqual(result["verdict"], "none")

    def test_untagged_items_count_as_nightly(self):
        self.assertEqual(stable_next.pick(feed(item(500, None)), None, set(), lambda b: None, None)["build"], "500")

    def test_refuses_a_failed_verdict_and_a_pulled_build(self):
        with self.assertRaises(stable_next.Refused):
            stable_next.pick(feed(item(200)), None, set(), lambda b: "fail", None)
        with self.assertRaises(stable_next.Refused):
            stable_next.pick(feed(item(200)), None, {200}, lambda b: "pass", None)

    def test_skips_when_stable_already_serves_it(self):
        result = stable_next.pick(feed(item(200)), feed(item(200, "cmux-next-stable")), set(), lambda b: "pass", None)
        self.assertEqual(result["skip"], "true")

    def test_a_build_pulled_from_stable_is_never_picked_again(self):
        result = stable_next.pick(feed(item(300), item(200)), None, set(), lambda b: None, None, {300})
        self.assertEqual(result["build"], "200")
        with self.assertRaises(stable_next.Refused):
            stable_next.pick(feed(item(300)), None, set(), lambda b: None, 300, {300})
        with self.assertRaises(stable_next.Refused):
            stable_next.pick(feed(item(300)), None, set(), lambda b: None, None, {300})

    def test_an_explicit_build_must_be_on_the_feed(self):
        self.assertEqual(stable_next.pick(feed(item(200), item(100)), None, set(), lambda b: None, 100)["build"], "100")
        with self.assertRaises(stable_next.Refused):
            stable_next.pick(feed(item(200)), None, set(), lambda b: None, 150)


class PublishedTonight(unittest.TestCase):
    def test_compares_the_newest_items_pub_date(self):
        start = dt.datetime(2026, 10, 30, 4, tzinfo=dt.timezone.utc)
        self.assertTrue(stable_next.published_tonight(feed(item(2, date="Fri, 30 Oct 2026 05:00:00 +0000")), start))
        self.assertFalse(stable_next.published_tonight(feed(item(2, date="Thu, 29 Oct 2026 05:00:00 +0000")), start))
        self.assertFalse(stable_next.published_tonight(None, start))


class Shards(unittest.TestCase):
    def test_deals_every_test_target_once(self):
        package = '.testTarget(\n name: "BTests", deps: []),\n.testTarget(name: "ATests"),\n.target(name: "Lib"),\n.testTarget(name: "CTests")'
        matrix = stable_next.test_shards(package, 2)
        filters = ",".join(entry["filters"] for entry in matrix["include"]).split(",")
        self.assertEqual(sorted(filters), ["ATests", "BTests", "CTests"])
        self.assertEqual(len(matrix["include"]), 2)

    def test_the_real_package_has_its_test_targets(self):
        package = (ROOT / "Packages/macOS/CmuxNext/Package.swift").read_text()
        matrix = stable_next.test_shards(package, 4)
        filters = ",".join(entry["filters"] for entry in matrix["include"]).split(",")
        self.assertIn("CmuxNextAppTests", filters)
        self.assertNotIn("CmuxNextTestSupport", filters)
        self.assertEqual(len(filters), len(set(filters)))

    def test_every_filter_passes_the_suite_lanes_own_check(self):
        """package-test-lane.sh suite refuses a filter outside its regex or ending in '.' or '/' (exit 2)."""
        lane = (ROOT / "scripts/ci/package-test-lane.sh").read_text()
        pattern = re.search(r'\[\[ "\$suite_filter" =~ (\S+) \]\]', lane).group(1)
        package = (ROOT / "Packages/macOS/CmuxNext/Package.swift").read_text()
        for entry in stable_next.test_shards(package, 4)["include"]:
            for f in entry["filters"].split(","):
                self.assertRegex(f, pattern)
                self.assertFalse(f.endswith((".", "/")), f)


class MergeAndRollback(unittest.TestCase):
    def test_merge_tags_the_new_item_and_keeps_two_earlier(self):
        live = feed(item(30, "cmux-next-stable"), item(20, "cmux-next-stable"), item(10, "cmux-next-stable"))
        merged = stable_next.merge_feed(feed(item(40)), live)
        builds = [b for _, b in stable_next.items(merged)]
        self.assertEqual(builds, [40, 30, 20])
        for match, _ in stable_next.items(merged):
            self.assertEqual(stable_next.channel_of(match.group(0)), "cmux-next-stable")
        self.assertEqual(merged.count("<sparkle:channel>"), 3)

    def test_merge_adds_a_channel_to_an_untagged_item_and_starts_a_feed(self):
        merged = stable_next.merge_feed(feed(item(40, None)), None)
        self.assertEqual(stable_next.channel_of(stable_next.items(merged)[0][0].group(0)), "cmux-next-stable")

    def test_merge_refuses_a_build_the_feed_already_has(self):
        with self.assertRaises(stable_next.Refused):
            stable_next.merge_feed(feed(item(30)), feed(item(30, "cmux-next-stable")))

    def test_rollback_drops_the_bad_build_and_newer_but_never_empties(self):
        live = feed(item(30), item(20), item(10))
        text, dropped = stable_next.rollback(live, 20, None)
        self.assertEqual(dropped, [20, 30])
        self.assertEqual([b for _, b in stable_next.items(text)], [10])
        text, dropped = stable_next.rollback(live, None, 20)
        self.assertEqual(dropped, [30])
        with self.assertRaises(stable_next.Refused):
            stable_next.rollback(live, 10, None)

    def test_rollback_may_pull_the_only_build_when_asked(self):
        text, dropped = stable_next.rollback(feed(item(10)), 10, None, allow_empty=True)
        self.assertEqual(dropped, [10])
        self.assertEqual(stable_next.items(text), [])

    def test_record_pulled_adds_each_build_once(self):
        first = stable_next.record_pulled(None, [30, 20], "crash", "2026-10-30T05:00:00Z")
        again = stable_next.record_pulled(first, [30, 40], "crash", "2026-10-30T06:00:00Z")
        self.assertEqual([e["build"] for e in json.loads(again)], ["30", "20", "40"])
        self.assertEqual(stable_next.pulled_builds_text(again), {20, 30, 40})


if __name__ == "__main__":
    unittest.main()
