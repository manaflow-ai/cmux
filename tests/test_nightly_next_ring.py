#!/usr/bin/env python3
"""Release-ring tags on the cmux NEXT feed (scripts/ci/nightly_next_ring.py)."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/nightly_next_ring.py"
spec = importlib.util.spec_from_file_location("nightly_next_ring", SCRIPT)
ring = importlib.util.module_from_spec(spec)
sys.modules["nightly_next_ring"] = ring
spec.loader.exec_module(ring)

GUARD = ROOT / "scripts/ci/nightly-next-guard.py"
NIGHTLY_YML = ROOT / ".github/workflows/nightly.yml"
VERDICT_YML = ROOT / ".github/workflows/nightly-next-verdict.yml"
BASE = "https://github.com/manaflow-ai/cmux/releases/download/nightly-next/"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def item(build: str, channel: str | None = "cmux-next") -> str:
    tag = f"            <sparkle:channel>{channel}</sparkle:channel>\n" if channel else ""
    return f"""        <item>
{tag}            <title>1.0.0-nightly.{build}</title>
            <description><![CDATA[New

- line]]></description>
            <sparkle:version>{build}</sparkle:version>
            <enclosure url="{BASE}cmux-nightly-next-macos-arm64-{build}.dmg" length="1" type="application/octet-stream" sparkle:edSignature="s=="/>
        </item>
"""


def feed(*entries: str) -> str:
    return ("""<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>cmux NEXT</title>
""" + "".join(entries) + """    </channel>
</rss>
""")


def offered(text: str, allowed: set[str]) -> list[str]:
    """The builds Sparkle offers an updater that allows `allowed`: an item with a
    channel only when it is allowed (AppcastItem.isOffered, SUAppcastDriver)."""
    builds = []
    for chunk in re.findall(r"<item>.*?</item>", text, re.S):
        channel = re.search(r"<sparkle:channel>([^<]*)</sparkle:channel>", chunk)
        if channel is None or channel.group(1) in allowed:
            builds.append(re.search(r"<sparkle:version>(\d+)</sparkle:version>", chunk).group(1))
    return builds


# UpdateRing.acceptedSparkleChannels, and what a build from before rings allows.
DEV_RING = {"cmux-next-stable", "cmux-next", "cmux-next-canary", "cmux-next-dev"}
NIGHTLY_RING = {"cmux-next-stable", "cmux-next"}
PRE_RING_BUILD = {"cmux-next"}
MAIN_BUILD: set[str] = set()


class ChannelTests(unittest.TestCase):
    def test_a_new_build_is_dev_when_on_and_nightly_when_off(self):
        self.assertEqual(ring.new_build_channel("on"), "cmux-next-dev")
        self.assertEqual(ring.new_build_channel("off"), "cmux-next")
        with self.assertRaises(ring.Refused):
            ring.new_build_channel("")


class RetagTests(unittest.TestCase):
    FEED = feed(item("300", "cmux-next-dev"), item("200", "cmux-next-dev"), item("100"))

    def test_on_a_build_moves_to_nightly_only_with_a_pass_verdict(self):
        verdicts = {"300": None, "200": "pass", "100": "fail"}
        text, summary = ring.retag(self.FEED, "on", verdicts.get)
        self.assertEqual(summary["channels"], {"300": "cmux-next-dev", "200": "cmux-next", "100": "cmux-next-dev"})
        self.assertTrue(summary["changed"])
        self.assertEqual(text, feed(item("300", "cmux-next-dev"), item("200"), item("100", "cmux-next-dev")))

    def test_nightly_and_older_builds_never_see_an_unpromoted_build(self):
        text, _ = ring.retag(self.FEED, "on", {"200": "pass"}.get)
        self.assertEqual(offered(text, DEV_RING), ["300", "200", "100"])
        self.assertEqual(offered(text, NIGHTLY_RING), ["200"])
        self.assertEqual(offered(text, PRE_RING_BUILD), ["200"])
        self.assertEqual(offered(text, MAIN_BUILD), [])

    def test_off_puts_every_item_back_on_nightly(self):
        text, summary = ring.retag(self.FEED, "off", lambda build: self.fail("off reads no verdict"))
        self.assertEqual(text, feed(item("300"), item("200"), item("100")))
        self.assertEqual(offered(text, PRE_RING_BUILD), ["300", "200", "100"])

    def test_a_feed_already_right_is_unchanged(self):
        current = feed(item("300", "cmux-next-dev"), item("200"))
        text, summary = ring.retag(current, "on", {"200": "pass"}.get)
        self.assertFalse(summary["changed"])
        self.assertEqual(text, current)

    def test_an_untagged_item_gets_one_tag_and_a_doubled_tag_becomes_one(self):
        doubled = item("200").replace("<sparkle:channel>cmux-next</sparkle:channel>",
                                      "<sparkle:channel>cmux-next</sparkle:channel>\n"
                                      "            <sparkle:channel>cmux-next-dev</sparkle:channel>")
        text, _ = ring.retag(feed(item("300", None), doubled), "on", {}.get)
        self.assertEqual(text, feed(item("300", "cmux-next-dev"), item("200", "cmux-next-dev")))
        compact = '<rss xmlns:sparkle="x"><channel><item><sparkle:version>5</sparkle:version></item></channel></rss>'
        text, _ = ring.retag(compact, "on", {}.get)
        self.assertIn("<item><sparkle:channel>cmux-next-dev</sparkle:channel><sparkle:version>5", text)

    def test_refuses_a_feed_with_no_items_or_a_bad_version(self):
        with self.assertRaises(ring.Refused):
            ring.retag(feed(), "on", {}.get)
        with self.assertRaises(ring.Refused):
            ring.retag(feed(item("x1")), "on", {}.get)

    def test_the_retagged_feed_passes_the_guard(self):
        text, _ = ring.retag(self.FEED, "on", {"200": "pass"}.get)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "appcast-arm64.xml"
            path.write_text(text)
            result = subprocess.run([sys.executable, str(GUARD), "appcast", str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)


class SelectTests(unittest.TestCase):
    def test_select_keeps_only_the_ring_and_the_rest_byte_for_byte(self):
        text, summary = ring.select(feed(item("300", "cmux-next-dev"), item("200"), item("100")), "cmux-next")
        self.assertEqual(summary, {"kept": ["200", "100"], "dropped": ["300"]})
        self.assertEqual(text, feed(item("200"), item("100")))

    def test_select_with_nothing_promoted_leaves_no_items(self):
        _, summary = ring.select(feed(item("300", "cmux-next-dev")), "cmux-next")
        self.assertEqual(summary, {"kept": [], "dropped": ["300"]})


class CliTests(unittest.TestCase):
    def run_cli(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True)

    def test_retag_reads_verdict_documents_and_counts_a_bad_one_as_none(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "verdicts").mkdir()
            (root / "verdicts" / "200.json").write_text(json.dumps({"build": "200", "verdict": "pass"}))
            (root / "verdicts" / "300.json").write_text("not json")
            # A document that names another build does not promote this one.
            (root / "verdicts" / "100.json").write_text(json.dumps({"build": "999", "verdict": "pass"}))
            (root / "live.xml").write_text(feed(item("300"), item("200"), item("100")))
            result = self.run_cli("retag", "--feed", str(root / "live.xml"), "--out", str(root / "out.xml"),
                                  "--mode", "on", "--verdicts-base", str(root))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["channels"],
                             {"300": "cmux-next-dev", "200": "cmux-next", "100": "cmux-next-dev"})
            self.assertEqual(offered((root / "out.xml").read_text(), NIGHTLY_RING), ["200"])

    def test_retag_writes_nothing_when_nothing_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "live.xml").write_text(feed(item("200")))
            result = self.run_cli("retag", "--feed", str(root / "live.xml"), "--out", str(root / "out.xml"),
                                  "--mode", "off", "--verdicts-base", str(root))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(json.loads(result.stdout)["changed"])
            self.assertFalse((root / "out.xml").exists())

    def test_channel_refuses_an_unknown_mode(self):
        self.assertEqual(self.run_cli("channel", "--mode", "on").stdout.strip(), "cmux-next-dev")
        self.assertEqual(self.run_cli("channel", "--mode", "maybe").returncode, 1)


class WorkflowTests(unittest.TestCase):
    """The writers of the cmux NEXT feed tag new builds and promote them as described."""

    def test_new_builds_are_tagged_from_the_dev_ring_switch(self):
        text = NIGHTLY_YML.read_text()
        ring_expr = "vars.NIGHTLY_NEXT_DEV_RING == 'on' && 'cmux-next-dev' || 'cmux-next'"
        tags = re.findall(r"^\s+SPARKLE_CHANNEL: (.*)$", text, re.MULTILINE)
        # First publication, its deltas and a recovered build follow the switch;
        # the old cmux NIGHTLY-identity feed stays on cmux-next (pre-ring builds).
        self.assertEqual(sum(ring_expr in tag for tag in tags), 3, tags)
        self.assertEqual(tags.count("cmux-next"), 1, tags)

    def test_the_delta_feed_is_retagged_from_verdicts_before_it_is_published(self):
        text = NIGHTLY_YML.read_text()
        job = text[text.index("\n  republish-nightly-deltas:"):text.index("\n  published-in:")]
        retag = job.index("nightly_next_ring.py retag")
        self.assertLess(retag, job.index("publish-release-assets.py"))

    def test_the_old_feed_follows_nightly_only(self):
        text = NIGHTLY_YML.read_text()
        job = text[text.index("\n  legacy-identity-target:"):text.index("\n  sign-nightly-identity-legacy:")]
        self.assertLess(job.index("nightly_next_ring.py select"), job.index("nightly-next-legacy-target.py"))

    def test_a_verdict_promotes_on_the_live_feed_with_if_match(self):
        text = VERDICT_YML.read_text()
        self.assertIn("nightly_next_ring.py retag", text)
        self.assertIn("--replace-sha256", text)
        self.assertIn("scripts/ci/nightly_next_ring.py", text)


if __name__ == "__main__":
    unittest.main()
