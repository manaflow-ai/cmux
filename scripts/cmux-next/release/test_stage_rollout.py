#!/usr/bin/env python3
"""Tests of stage-rollout.py (operator-run, not a CI lane):

    python3 -I scripts/cmux-next/release/test_stage_rollout.py
"""
from __future__ import annotations

import datetime
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("stage_rollout", HERE / "stage-rollout.py")
assert spec and spec.loader
tool = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = tool  # dataclasses look the module up by name
spec.loader.exec_module(tool)

NOW = datetime.datetime(2026, 11, 2, 12, 0, tzinfo=datetime.timezone.utc)

FEED = """<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>cmux</title>
        <item>
            <title>1.2.0</title>
            <pubDate>Mon, 02 Nov 2026 10:00:00 +0000</pubDate>
            <sparkle:version>300</sparkle:version>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url="https://example.com/cmux-macos.dmg" length="1" type="application/octet-stream" sparkle:edSignature="x"/>
        </item>
        <item>
            <title>1.1.0</title>
            <enclosure url="https://example.com/old.dmg" sparkle:version="200" length="1" type="application/octet-stream"/>
        </item>
    </channel>
</rss>
"""


def sessions(count: int, rate: float | None) -> dict:
    return {"groups": [{"totals": {"sum(session)": count, "count_unique(user)": count // 2,
                                   "crash_free_rate(session)": rate, "crash_free_rate(user)": rate}}]}


class FakeSentry:
    def __init__(self, by_release: dict[str, dict]):
        self.by_release = by_release
        self.calls: list[list[tuple[str, str]]] = []

    def __call__(self, path: str, params: list[tuple[str, str]]):
        self.calls.append(params)
        query = dict(params)["query"]
        return self.by_release[query.split('"')[1]], {}


class StageFeedTests(unittest.TestCase):
    def test_sets_the_percentage_on_the_build_only_and_declares_the_namespace(self):
        out = tool.stage_feed(FEED, "300", 5, NOW)
        self.assertIn(f'xmlns:cmux="{tool.NAMESPACE}"', out)
        self.assertEqual(tool.current_stage(out, "300").percent, 5)
        self.assertEqual(tool.current_stage(out, "300").staged_at, NOW)
        self.assertIsNone(tool.current_stage(out, "200").percent)
        # Nothing else moves: removing the two new elements and the declaration gives the input back.
        stripped = out.replace(f' xmlns:cmux="{tool.NAMESPACE}"', "")
        stripped = "\n".join(line for line in stripped.split("\n") if "<cmux:" not in line)
        self.assertEqual(stripped, FEED.rstrip("\n") + ("\n" if FEED.endswith("\n") else ""))

    def test_raising_the_stage_replaces_the_value(self):
        once = tool.stage_feed(FEED, "300", 1, NOW)
        twice = tool.stage_feed(once, "300", 20, NOW + datetime.timedelta(days=1))
        self.assertEqual(twice.count("<cmux:rolloutPercent>"), 1)
        self.assertEqual(tool.current_stage(twice, "300").percent, 20)

    def test_writing_the_same_stage_again_keeps_its_start(self):
        once = tool.stage_feed(FEED, "300", 5, NOW)
        again = tool.stage_feed(once, "300", 5, NOW + datetime.timedelta(hours=20))
        self.assertEqual(tool.current_stage(again, "300").staged_at, NOW)
        raised = tool.stage_feed(once, "300", 20, NOW + datetime.timedelta(hours=30))
        self.assertEqual(tool.current_stage(raised, "300").staged_at, NOW + datetime.timedelta(hours=30))

    def test_a_bad_staged_time_is_a_feed_error(self):
        bad = tool.stage_feed(FEED, "300", 5, NOW).replace("2026-11-02T12:00:00Z", "yesterday")
        with self.assertRaises(tool.RolloutError):
            tool.current_stage(bad, "300")

    def test_set_repairs_a_broken_percent_or_time_at_the_same_stage(self):
        later = NOW + datetime.timedelta(hours=3)
        staged = tool.stage_feed(FEED, "300", 5, NOW)
        broken = [staged.replace(">5<", ">abc<"), staged.replace("2026-11-02T12:00:00Z", "yesterday"),
                  staged.replace("<cmux:rolloutPercent>5</cmux:rolloutPercent>", "<cmux:rolloutPercent/>"),
                  staged.replace("<cmux:rolloutStagedAt>2026-11-02T12:00:00Z</cmux:rolloutStagedAt>", "<cmux:rolloutStagedAt />"),
                  staged.replace("<cmux:rolloutPercent>5</cmux:rolloutPercent>", "<cmux:rolloutPercent >abc</cmux:rolloutPercent>")]
        for feed in broken:
            repaired = tool.stage_feed(feed, "300", 5, later)
            self.assertEqual(tool.current_stage(repaired, "300"), tool.Stage(5, later), feed)
            self.assertEqual(repaired.count("rolloutPercent"), 2, "one element, opened and closed")

    def test_the_enclosure_attribute_names_the_build_too(self):
        out = tool.stage_feed(FEED, "200", 0, NOW)
        self.assertEqual(tool.current_stage(out, "200").percent, 0)

    def test_refuses_a_missing_build_a_bad_percent_and_a_foreign_prefix(self):
        with self.assertRaises(tool.RolloutError):
            tool.stage_feed(FEED, "999", 5, NOW)
        with self.assertRaises(tool.RolloutError):
            tool.parse_percent("120")
        with self.assertRaises(tool.RolloutError):
            tool.stage_feed(FEED.replace("<rss ", '<rss xmlns:cmux="urn:other" '), "300", 5, NOW)

    def test_next_stage_follows_the_ladder(self):
        self.assertEqual(tool.next_stage(1), 5)
        self.assertEqual(tool.next_stage(50), 100)
        with self.assertRaises(tool.RolloutError):
            tool.next_stage(100)
        with self.assertRaises(tool.RolloutError):
            tool.next_stage(0)  # a halt restarts with set, never with advance
        with self.assertRaises(tool.RolloutError):
            tool.next_stage(3)  # off the ladder

    def test_a_signed_feed_is_refused(self):
        with self.assertRaises(tool.RolloutError):
            tool.stage_feed(FEED + "<!-- sparkle-signatures:\nedSignature: x\n-->\n", "300", 5, NOW)

    def test_the_gate_window_is_sent_in_utc(self):
        offset = datetime.timezone(datetime.timedelta(hours=2))
        sentry = FakeSentry({"r": sessions(10, 1.0)})
        tool.release_sessions(tool.load_health(), sentry, "r", "release-next",
                              datetime.datetime(2026, 11, 2, 14, 0, tzinfo=offset), NOW)
        self.assertIn(("start", "2026-11-02T12:00:00"), sentry.calls[0])
        with self.assertRaises(tool.RolloutError):
            tool.utc(datetime.datetime(2026, 11, 2, 14, 0))


class GateTests(unittest.TestCase):
    def test_a_stage_passes_with_enough_healthy_sessions(self):
        self.assertEqual(tool.judge(5, tool.load_health().session_row(sessions(2_000, 0.999)["groups"][0]["totals"]), None), [])

    def test_a_stage_fails_on_few_sessions_a_low_rate_or_a_drop_below_the_baseline(self):
        row = lambda n, r: tool.load_health().session_row(sessions(n, r)["groups"][0]["totals"])  # noqa: E731
        self.assertTrue(any("sessions" in m for m in tool.judge(5, row(100, 0.999), None)))
        self.assertTrue(any("<" in m for m in tool.judge(5, row(2_000, 0.99), None)))
        self.assertTrue(any("baseline" in m for m in tool.judge(5, row(2_000, 0.9975), row(9_000, 0.9995))))
        self.assertTrue(tool.judge(5, row(2_000, None), None))


class AdvanceTests(unittest.TestCase):
    def run_tool(self, feed_text: str, sentry: FakeSentry, now: datetime.datetime, *extra: str) -> tuple[int, str, str]:
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "appcast.xml"
            path.write_text(feed_text, encoding="utf-8")
            out = io.StringIO()
            code = tool.main(["advance", str(path), "--build", "300", "--release", "cmux-next@1.2.0+300", *extra],
                             now=lambda: now, fetch=sentry, out=out)
            return code, out.getvalue(), path.read_text(encoding="utf-8")

    def test_advances_a_baked_stage_whose_gate_passes(self):
        staged = tool.stage_feed(FEED, "300", 1, NOW)
        sentry = FakeSentry({"cmux-next@1.2.0+300": sessions(800, 0.999)})
        code, out, written = self.run_tool(staged, sentry, NOW + datetime.timedelta(hours=25), "--write")
        self.assertEqual(code, 0, out)
        self.assertEqual(tool.current_stage(written, "300").percent, 5)
        # The gate read the stage's own window, from the staged time.
        self.assertIn(("start", "2026-11-02T12:00:00"), sentry.calls[0])

    def test_holds_a_stage_that_has_not_baked(self):
        staged = tool.stage_feed(FEED, "300", 1, NOW)
        code, out, written = self.run_tool(staged, FakeSentry({}), NOW + datetime.timedelta(hours=3), "--write")
        self.assertEqual(code, 1)
        self.assertEqual(tool.current_stage(written, "300").percent, 1)

    def test_holds_a_stage_whose_gate_fails(self):
        staged = tool.stage_feed(FEED, "300", 1, NOW)
        sentry = FakeSentry({"cmux-next@1.2.0+300": sessions(800, 0.98)})
        code, out, written = self.run_tool(staged, sentry, NOW + datetime.timedelta(hours=30), "--write")
        self.assertEqual(code, 1)
        self.assertIn("crash-free", out)
        self.assertEqual(tool.current_stage(written, "300").percent, 1)

    def test_a_dry_run_writes_nothing(self):
        staged = tool.stage_feed(FEED, "300", 1, NOW)
        sentry = FakeSentry({"cmux-next@1.2.0+300": sessions(800, 0.999)})
        code, out, written = self.run_tool(staged, sentry, NOW + datetime.timedelta(hours=25))
        self.assertEqual(code, 0)
        self.assertEqual(written, staged)
        self.assertIn("dry run", out)


if __name__ == "__main__":
    unittest.main()
