#!/usr/bin/env python3
"""Pulling bad builds off the cmux NEXT feed (scripts/ci/nightly_next_feed_rollback.py)."""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/ci/nightly_next_feed_rollback.py"
spec = importlib.util.spec_from_file_location("feed_rollback", SCRIPT)
rollback = importlib.util.module_from_spec(spec)
sys.modules["feed_rollback"] = rollback
spec.loader.exec_module(rollback)

GUARD = Path(__file__).resolve().parents[1] / "scripts/ci/nightly-next-guard.py"
BASE = "https://github.com/manaflow-ai/cmux/releases/download/nightly-next/"


def item(build: str, delta_from: str | None = None) -> str:
    delta = ""
    if delta_from:
        delta = (f"""            <sparkle:deltas>
                <enclosure url="{BASE}cmux-nightly-next-macos-arm64-{build}-{delta_from}.delta" sparkle:deltaFrom="{delta_from}" length="7" type="application/octet-stream" sparkle:edSignature="d=="/>
            </sparkle:deltas>
""")
    return f"""        <item>
            <sparkle:channel>cmux-next</sparkle:channel>
            <title>1.0.0-nightly.{build}</title>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>1.0.0-nightly.{build}</sparkle:shortVersionString>
            <enclosure url="{BASE}cmux-nightly-next-macos-arm64-{build}.dmg" length="1" type="application/octet-stream" sparkle:edSignature="s=="/>
{delta}        </item>
"""


def feed(*entries: str) -> str:
    return ("""<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>cmux NEXT</title>
""" + "".join(entries) + """    </channel>
</rss>
""")


LIVE = feed(item("3917159104301", "3917061587901"), item("3917061587901"))


class PlanTests(unittest.TestCase):
    def test_default_pulls_the_newest_build_and_keeps_the_rest_byte_for_byte(self):
        text, summary = rollback.plan(LIVE)
        self.assertEqual(summary, {"pulled": ["3917159104301"], "serving": "3917061587901",
                                   "serving_url": f"{BASE}cmux-nightly-next-macos-arm64-3917061587901.dmg",
                                   "changed": True})
        self.assertEqual(text, feed(item("3917061587901")))

    def test_bad_pulls_that_build_and_every_newer_one(self):
        live = feed(item("30"), item("20"), item("10"))
        text, summary = rollback.plan(live, bad="20")
        self.assertEqual(summary["pulled"], ["30", "20"])
        self.assertEqual(summary["serving"], "10")
        self.assertEqual(text, feed(item("10")))

    def test_to_keeps_that_build_as_the_newest(self):
        live = feed(item("30"), item("20"), item("10"))
        text, summary = rollback.plan(live, to="20")
        self.assertEqual(summary["pulled"], ["30"])
        self.assertEqual(text, feed(item("20"), item("10")))

    def test_builds_compare_as_numbers(self):
        live = feed(item("9"), item("10"))
        _, summary = rollback.plan(live)
        self.assertEqual(summary["pulled"], ["10"])
        self.assertEqual(summary["serving"], "9")

    def test_a_build_already_off_the_feed_is_a_no_op(self):
        # The canary names the build it launched; when an earlier pull already
        # took it off, nothing on the feed is at or above it.
        text, summary = rollback.plan(LIVE, bad="3917159104302")
        self.assertEqual(summary["pulled"], [])
        self.assertEqual(summary["serving"], "3917159104301")
        self.assertFalse(summary["changed"])
        self.assertTrue(summary["serving_url"].endswith("-3917159104301.dmg"))
        self.assertEqual(text, LIVE)

    def test_refuses_to_empty_the_feed(self):
        with self.assertRaisesRegex(rollback.Refused, "empty"):
            rollback.plan(feed(item("10")))
        with self.assertRaisesRegex(rollback.Refused, "empty"):
            rollback.plan(LIVE, bad="1")

    def test_refuses_a_to_build_that_is_not_on_the_feed(self):
        with self.assertRaisesRegex(rollback.Refused, "not on the feed"):
            rollback.plan(LIVE, to="5")

    def test_refuses_non_numeric_input(self):
        with self.assertRaisesRegex(rollback.Refused, "not a number"):
            rollback.plan(LIVE, bad="latest")
        with self.assertRaisesRegex(rollback.Refused, "numeric"):
            rollback.plan(feed(item("10")).replace("<sparkle:version>10", "<sparkle:version>1.0"))
        with self.assertRaisesRegex(rollback.Refused, "no items"):
            rollback.plan("<rss/>")


class CommandTests(unittest.TestCase):
    def run_plan(self, *args: str) -> tuple[int, dict | None, str, Path]:
        work = Path(tempfile.mkdtemp())
        (work / "live.xml").write_text(LIVE, encoding="utf-8")
        out = work / "appcast-arm64.xml"
        result = subprocess.run([sys.executable, "-I", str(SCRIPT), "plan", "--feed", str(work / "live.xml"),
                                 "--out", str(out), *args], capture_output=True, text=True)
        summary = json.loads(result.stdout) if result.returncode == 0 else None
        return result.returncode, summary, result.stderr, out

    def test_the_pulled_feed_passes_the_nightly_next_guard(self):
        status, summary, _, out = self.run_plan()
        self.assertEqual(status, 0)
        self.assertTrue(summary["changed"])
        env = {**os.environ, "NIGHTLY_NEXT_FEED_BASE": "https://files-next.cmux.com/nightly-next/next",
               "NIGHTLY_NEXT_R2_BUCKET": "cmux-nightly-next", "NIGHTLY_NEXT_R2_PREFIX": "nightly-next/next/"}
        guard = subprocess.run([sys.executable, "-I", str(GUARD), "appcast", str(out)],
                               capture_output=True, text=True, env=env)
        self.assertEqual(guard.returncode, 0, guard.stdout + guard.stderr)

    def test_no_change_writes_no_file(self):
        status, summary, _, out = self.run_plan("--bad", "4000000000000")
        self.assertEqual(status, 0)
        self.assertFalse(summary["changed"])
        self.assertFalse(out.exists())

    def test_refusal_exits_one(self):
        status, _, stderr, out = self.run_plan("--to", "1")
        self.assertEqual(status, 1)
        self.assertIn("refused", stderr)
        self.assertFalse(out.exists())


class PulledListTests(unittest.TestCase):
    AT = "2026-10-20T21:00:00Z"

    def test_first_pull_lists_every_pulled_build_newest_first(self):
        entries = rollback.pulled_list(None, ["300", "400"], "200", "crashes at launch", self.AT)
        self.assertEqual([e["build"] for e in entries], ["400", "300"])
        self.assertEqual(entries[0], {"build": "400", "reason": "crashes at launch", "pulledAt": self.AT, "serve": "200"})

    def test_merges_into_the_existing_list_and_replaces_a_repeat(self):
        existing = json.dumps([{"build": "150", "reason": "old", "pulledAt": "x", "serve": "140"},
                               {"build": "300", "reason": "first", "pulledAt": "x", "serve": "200"}])
        entries = rollback.pulled_list(existing, ["300"], "250", "again", self.AT)
        self.assertEqual([e["build"] for e in entries], ["300", "150"])
        self.assertEqual(entries[0]["reason"], "again")

    def test_serving_a_pulled_build_again_clears_it(self):
        existing = json.dumps([{"build": "300", "reason": "r", "pulledAt": "x", "serve": "200"}])
        self.assertEqual(rollback.pulled_list(existing, ["400"], "300", "r", self.AT)[0]["build"], "400")
        self.assertNotIn("300", [e["build"] for e in rollback.pulled_list(existing, ["400"], "300", "r", self.AT)])

    def test_unreadable_existing_counts_as_empty_and_bad_builds_refuse(self):
        self.assertEqual(len(rollback.pulled_list("not json", ["5"], "4", "r", self.AT)), 1)
        with self.assertRaises(rollback.Refused):
            rollback.pulled_list(None, ["5x"], "4", "r", self.AT)

    def test_cli_writes_the_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "pulled.json"
            code = rollback.main(["pulled", "--existing", str(Path(tmp) / "missing.json"), "--pulled", "9 8",
                                  "--serve", "7", "--reason", "r", "--at", self.AT, "--out", str(out)])
            self.assertEqual(code, 0)
            self.assertEqual([e["build"] for e in json.loads(out.read_text())], ["9", "8"])


if __name__ == "__main__":
    unittest.main()
