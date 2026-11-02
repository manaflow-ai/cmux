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
import xml.etree.ElementTree as ET

import yaml
from nightly_workflow_text import nightly_text

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


def sourced(entry: str, sha: str) -> str:
    """ENTRY with a bare <cmux:sourceCommit>, as the live feed of 2026-11-01 carried
    it: bound by nothing, since that feed's <rss> root declared only sparkle:."""
    return entry.replace("        </item>", f"            <cmux:sourceCommit>{sha}</cmux:sourceCommit>\n        </item>")


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


class LegacyTests(unittest.TestCase):
    """The old cmux NIGHTLY-identity feed after a build is copied (nightly_next_ring.py legacy)."""

    def verdicts(self, **passed):
        return lambda build: "pass" if passed.get(f"b{build}") else None

    def test_a_dev_build_joins_beside_the_nightly_one(self):
        out, summary = ring.legacy(feed(item("300")), feed(item("200")), "on", self.verdicts(b200=True))
        self.assertEqual(summary["channels"], {"300": "cmux-next-dev", "200": "cmux-next"})
        self.assertEqual(offered(out, NIGHTLY_RING), ["200"])
        self.assertEqual(offered(out, DEV_RING), ["300", "200"])
        self.assertEqual(offered(out, PRE_RING_BUILD), ["200"])
        self.assertEqual(offered(out, MAIN_BUILD), [])

    def test_a_carried_item_with_an_unbound_cmux_prefix_is_bound_on_the_new_root(self):
        current = feed(sourced(item("200"), "b" * 40))
        out, _ = ring.legacy(feed(item("300")), current, "on", self.verdicts(b200=True))
        root = ET.fromstring(out)
        self.assertEqual(root.findtext(".//{https://cmux.com/xml-namespaces/cmux}sourceCommit"), "b" * 40)
        self.assertEqual(out.count("xmlns:cmux="), 1)

    def test_a_promoted_build_replaces_the_older_nightly_item(self):
        current = feed(item("300", "cmux-next-dev"), item("200"))
        out, summary = ring.legacy(feed(item("400")), current, "on", self.verdicts(b200=True, b300=True))
        self.assertEqual(summary["channels"], {"400": "cmux-next-dev", "300": "cmux-next"})
        self.assertEqual(summary["dropped"], ["200"])
        self.assertEqual(offered(out, NIGHTLY_RING), ["300"])

    def test_at_most_five_dev_items_above_the_nightly_one(self):
        current = feed(*(item(str(b), "cmux-next-dev") for b in range(301, 307)), item("200"))
        out, summary = ring.legacy(feed(item("400")), current, "on", self.verdicts(b200=True))
        self.assertEqual(list(summary["channels"]), ["400", "306", "305", "304", "303", "200"])

    def test_a_nightly_build_copied_below_a_dev_one_keeps_both(self):
        current = feed(item("300", "cmux-next-dev"), item("100"))
        out, summary = ring.legacy(feed(item("200")), current, "on", self.verdicts(b100=True, b200=True))
        self.assertEqual(summary["channels"], {"300": "cmux-next-dev", "200": "cmux-next"})
        self.assertEqual(offered(out, NIGHTLY_RING), ["200"])

    def test_off_keeps_only_the_newest_build_on_nightly(self):
        current = feed(item("300", "cmux-next-dev"), item("200"))
        out, summary = ring.legacy(feed(item("400")), current, "off", self.verdicts())
        self.assertEqual(summary["channels"], {"400": "cmux-next"})
        self.assertEqual(out.count("<item>"), 1)

    def test_no_current_feed_and_the_guard_passes(self):
        out, summary = ring.legacy(feed(item("300")), None, "on", self.verdicts())
        self.assertEqual(summary["channels"], {"300": "cmux-next-dev"})
        self.assertTrue(out.startswith('<?xml version="1.0"'))
        self.assertTrue(out.endswith("    </channel>\n</rss>\n"))
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "appcast-arm64.xml"
            path.write_text(out)
            result = subprocess.run([sys.executable, str(GUARD), "appcast", str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_refuses_a_new_appcast_with_no_items(self):
        with self.assertRaises(ring.Refused):
            ring.legacy(feed(), feed(item("200")), "on", self.verdicts())


class KeepNightlyScriptTests(unittest.TestCase):
    """scripts/ci/nightly-steps/publish-next-feed-keep-nightly.sh with a stand-in curl."""

    SCRIPT = ROOT / "scripts/ci/nightly-steps/publish-next-feed-keep-nightly.sh"

    def run_script(self, live_code: int, live_text: str = "", ring: str = "on", curl_exit: int | None = None):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "verdicts").mkdir()
            (root / "verdicts" / "200.json").write_text(json.dumps({"build": "200", "verdict": "pass"}))
            (root / "live.xml").write_text(live_text)
            curl = root / "curl"
            curl.write_text(f"""#!/usr/bin/env bash
out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && {{ out="$2"; shift; }}; shift; done
[ {live_code} = 200 ] && cp "{root}/live.xml" "$out"
printf {live_code}
{f"exit {curl_exit}" if curl_exit is not None else f"[ {live_code} -lt 400 ]"}
""")
            curl.chmod(0o755)
            new = root / "appcast-arm64.xml"
            new.write_text(feed(item("400", "cmux-next-dev")))
            env = {"PATH": f"{root}:/usr/bin:/bin", "DEV_RING": ring, "CHANNEL_FEED_BASE": "https://example.invalid/next",
                   "NIGHTLY_NEXT_FEED_BASE": str(root), "RUNNER_TEMP": str(root), "GITHUB_RUN_ID": "1"}
            result = subprocess.run(["bash", str(self.SCRIPT), str(new)], env=env, capture_output=True, text=True)
            return result, new.read_text()

    def test_the_live_nightly_item_is_kept(self):
        result, out = self.run_script(200, feed(item("300", "cmux-next-dev"), item("200")))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(offered(out, NIGHTLY_RING), ["200"])
        self.assertEqual(offered(out, DEV_RING), ["400", "300", "200"])

    def test_no_live_feed_yet_publishes_the_new_build_alone(self):
        result, out = self.run_script(404)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(offered(out, DEV_RING), ["400"])

    def test_an_unreadable_live_feed_stops_the_publication(self):
        result, _ = self.run_script(503)
        self.assertEqual(result.returncode, 1)
        self.assertIn("would drop its Nightly item", result.stdout)

    def test_a_truncated_transfer_stops_the_publication_even_with_a_200(self):
        # curl exits 18 (partial file) after a 200: the body may lack the Nightly item.
        result, _ = self.run_script(200, feed(item("300", "cmux-next-dev")), curl_exit=18)
        self.assertEqual(result.returncode, 1)
        self.assertIn("curl exit 18, HTTP 200", result.stdout)

    def test_a_200_that_is_not_an_appcast_stops_the_publication(self):
        for body in ("", "<html>error</html>", feed()):
            result, _ = self.run_script(200, body)
            self.assertEqual(result.returncode, 1, body)
            self.assertIn("answered 200 with no appcast items", result.stdout)

    def test_a_live_feed_with_an_unbound_cmux_prefix_is_still_kept(self):
        # 2026-11-01: the live feed used cmux: without declaring it on <rss>. The
        # readability check must not refuse it, and the merged feed must parse.
        live = feed(item("300", "cmux-next-dev"), sourced(item("200"), "b" * 40))
        with self.assertRaises(ET.ParseError):
            ET.fromstring(live)
        result, out = self.run_script(200, live)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(offered(out, NIGHTLY_RING), ["200"])
        ET.fromstring(out)  # nightly-next-guard.py appcast reads it next, with ElementTree

    def test_ring_off_leaves_the_feed_alone(self):
        result, out = self.run_script(503, ring="off")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(out, feed(item("400", "cmux-next-dev")))


# A fixed clock for the legacy sign skip (LEGACY_NOW_EPOCH): 2026-10-31 00:00:00 UTC.
NOW_EPOCH = 1793404800
FRESH = "Fri, 30 Oct 2026 23:40:00 +0000"  # 20 min before NOW_EPOCH
STALE = "Thu, 29 Oct 2026 19:55:25 +0000"  # the old feed's build on 2026-10-30


def dated(entry: str, pub_date: str) -> str:
    return entry.replace("            <sparkle:version>", f"            <pubDate>{pub_date}</pubDate>\n            <sparkle:version>", 1)


class LegacySignSkipScriptTests(unittest.TestCase):
    """scripts/ci/nightly-steps/legacy-identity-sign-skip-published.sh with a stand-in curl that
    serves the old feed and the cmux NEXT feed from files."""

    SCRIPT = ROOT / "scripts/ci/nightly-steps/legacy-identity-sign-skip-published.sh"

    def run_script(self, build: str, old: str, next_feed: str | None, action: str = "new"):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "old").mkdir()
            (root / "next").mkdir()
            (root / "old" / "appcast-arm64.xml").write_text(old)
            if next_feed is not None:
                (root / "next" / "appcast-arm64.xml").write_text(next_feed)
            curl = root / "bin" / "curl"
            curl.parent.mkdir()
            curl.write_text("""#!/usr/bin/env bash
out=""; url=""; while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; -A) shift ;; -*) ;; *) url="$1" ;; esac; shift; done
cp "${url#file://}" "$out"
""")
            curl.chmod(0o755)
            output, summary = root / "out", root / "summary"
            env = {"PATH": f"{root / 'bin'}:/usr/bin:/bin", "RUNNER_TEMP": str(root), "GITHUB_OUTPUT": str(output),
                   "LEGACY_NOW_EPOCH": str(NOW_EPOCH),
                   "GITHUB_STEP_SUMMARY": str(summary), "NIGHTLY_BUILD": build, "LEGACY_ACTION": action,
                   "LEGACY_APPCAST": "appcast-arm64.xml", "NIGHTLY_NEXT_LEGACY_FEED_BASE": f"file://{root}/old",
                   "NIGHTLY_NEXT_FEED_BASE": f"file://{root}/next"}
            result = subprocess.run(["bash", str(self.SCRIPT)], cwd=ROOT, env=env, capture_output=True, text=True)
            return result, output.read_text() if output.exists() else ""

    def test_a_build_newer_than_both_feeds_is_signed(self):
        result, out = self.run_script("300", feed(item("200")), feed(item("300"), item("200")))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(out, "skip=false\n")

    def test_a_build_the_old_feed_has_is_skipped(self):
        result, out = self.run_script("200", feed(item("200")), feed(item("300")))
        self.assertEqual((result.returncode, out), (0, "skip=true\n"), result.stderr)

    def test_a_new_submission_behind_the_next_feed_is_superseded(self):
        result, out = self.run_script("250", feed(dated(item("200"), FRESH)), feed(item("300"), item("250")))
        self.assertEqual((result.returncode, out), (0, "skip=true\n"), result.stderr)
        self.assertIn("cmux NEXT feed Nightly build: 300", result.stdout)

    def test_a_stale_old_feed_signs_a_build_behind_the_next_feed(self):
        # Runs 41129836857, 41130873851, 41131599639, 41138268545 (2026-10-30): cmux NEXT
        # publishes every ~10 min and a legacy sign starts 20-40 min after its target was
        # picked, so every sign was superseded and the old feed sat at 4093446036501 for
        # 28 hours. Once the old feed is stale, a build newer than it is signed.
        result, out = self.run_script("250", feed(dated(item("200"), STALE)), feed(item("300"), item("250")))
        self.assertEqual((result.returncode, out), (0, "skip=false\n"), result.stderr)
        self.assertIn("old feed is stale", result.stdout)

    def test_an_old_feed_with_no_date_signs_a_build_behind_the_next_feed(self):
        result, out = self.run_script("250", feed(item("200")), feed(item("300"), item("250")))
        self.assertEqual((result.returncode, out), (0, "skip=false\n"), result.stderr)

    def test_a_dev_item_on_the_next_feed_does_not_supersede_a_nightly_build(self):
        result, out = self.run_script("250", feed(dated(item("200"), FRESH)),
                                      feed(item("300", "cmux-next-dev"), item("250")))
        self.assertEqual((result.returncode, out), (0, "skip=false\n"), result.stderr)

    def test_a_continuation_is_kept_even_behind_the_next_feed(self):
        result, out = self.run_script("250", feed(dated(item("200"), FRESH)), feed(item("300")), action="continue")
        self.assertEqual((result.returncode, out), (0, "skip=false\n"), result.stderr)

    def test_an_unreadable_next_feed_supersedes_nothing(self):
        result, out = self.run_script("250", feed(dated(item("200"), FRESH)), None)
        self.assertEqual((result.returncode, out), (0, "skip=false\n"), result.stderr)


class LegacyTargetTests(unittest.TestCase):
    """scripts/ci/nightly-next-legacy-target.py reads the live cmux NEXT feed."""

    def test_a_next_feed_with_an_unbound_cmux_prefix_is_read(self):
        with tempfile.TemporaryDirectory() as tmp:
            next_feed, old_feed = Path(tmp) / "next.xml", Path(tmp) / "old.xml"
            next_feed.write_text(feed(sourced(item("300"), "c" * 40), sourced(item("200"), "b" * 40)))
            old_feed.write_text(feed(item("200")))
            result = subprocess.run(
                [sys.executable, str(ROOT / "scripts/ci/nightly-next-legacy-target.py"), str(next_feed), str(old_feed),
                 "cmux-nightly-next-macos-arm64-"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("action=new\nbuild=300\n", result.stdout)


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
        text = nightly_text()
        ring_expr = "vars.NIGHTLY_NEXT_DEV_RING == 'on' && 'cmux-next-dev' || 'cmux-next'"
        tags = re.findall(r"^\s+SPARKLE_CHANNEL: (.*)$", text, re.MULTILINE)
        # First publication, its deltas and a recovered build follow the switch;
        # the old cmux NIGHTLY-identity feed's item starts on cmux-next and is
        # retagged from its verdict (nightly_next_ring.py legacy). The release-pool
        # path's appcast (signer-dmg) follows the switch too.
        self.assertEqual(sum(ring_expr in tag for tag in tags), 4, tags)
        self.assertEqual(tags.count("cmux-next"), 1, tags)

    def test_the_delta_feed_is_retagged_from_verdicts_before_it_is_published(self):
        text = nightly_text()
        job = text[text.index("\n  republish-nightly-deltas:"):text.index("\n  published-in:")]
        retag = job.index("nightly_next_ring.py retag")
        self.assertLess(retag, job.index('python3 "$publisher"'))

    def test_the_old_feed_copies_nightly_first_then_dev(self):
        text = nightly_text()
        job = text[text.index("\n  legacy-identity-target:"):text.index("\n  sign-nightly-identity-legacy:")]
        target = job.index("nightly-next-legacy-target.py")
        self.assertLess(job.index("nightly_next_ring.py select --feed next-all.xml"), target)
        self.assertLess(job.index("nightly_next_ring.py select --feed old-all.xml"), target)
        # The full feeds (Dev too) only when the old feed's Nightly is current and the ring is on.
        self.assertLess(job.index('elif [ "$DEV_RING" = on ]; then\n            cp next-all.xml next.xml'), target)

    def test_the_next_feed_keeps_its_newest_nightly_item_before_it_goes_live(self):
        # 2026-10-27: the /next/ feed held only the newest build, on cmux-next-dev, so a
        # Nightly-ring app was offered nothing for hours while no verdict was written.
        text = nightly_text()
        job = text[text.index("\n  publish-nightly:"):text.index("\n  publish-nightly-next-github:")]
        keep = job.index("- name: Keep the live feed's newest Nightly item beside the new build")
        step = job[keep:job.index("\n      - ", keep + 1)]
        self.assertIn('read -r -a feeds <<<"$NIGHTLY_FEEDS"', step)
        self.assertIn('publish-next-feed-keep-nightly.sh "${feeds[@]/#/nightly-out/}"', step)
        self.assertIn("DEV_RING: ${{ steps.ring.outputs.mode || 'off' }}", step)
        # Before the live-ring retag, the hand-off, the guard and the live write.
        for later in ("- name: Tag the new build's items from the live Dev ring switch",
                      "- name: Hand the published feed to the GitHub release job",
                      "- name: Upload nightly-next appcasts to R2"):
            self.assertLess(keep, job.index(later), later)
        # The delta republish keeps it too, before its retag and its same-build write.
        deltas = text[text.index("\n  republish-nightly-deltas:"):text.index("\n  published-in:")]
        merge = deltas.index("publish-next-feed-keep-nightly.sh nightly-deltas/appcast*.xml")
        self.assertLess(merge, deltas.index("nightly_next_ring.py retag --feed \"$feed\""))
        self.assertIn("scripts/ci/nightly-steps/publish-next-feed-keep-nightly.sh\n", deltas)

    def test_a_new_dev_build_leaves_the_nightly_ring_its_newest_item(self):
        # What the step above publishes: the new Dev build beside the live feed's Nightly item,
        # and a verdict that later passes a build the feed moved past can still promote it.
        live = feed(item("300", "cmux-next-dev"), item("200"))
        out, summary = ring.legacy(feed(item("400", "cmux-next-dev")), live, "on", self.verdicts_of(b200=True))
        self.assertEqual(offered(out, NIGHTLY_RING), ["200"])
        self.assertEqual(offered(out, DEV_RING), ["400", "300", "200"])
        out, _ = ring.legacy(feed(item("500", "cmux-next-dev")), out, "on", self.verdicts_of(b200=True, b300=True))
        self.assertEqual(offered(out, NIGHTLY_RING), ["300"])
        # Ring off: the new build alone, on Nightly, as before.
        out, summary = ring.legacy(feed(item("400")), live, "off", self.verdicts_of())
        self.assertEqual(summary["channels"], {"400": "cmux-next"})

    @staticmethod
    def verdicts_of(**passed):
        return lambda build: "pass" if passed.get(f"b{build}") else None

    def test_the_old_feed_is_merged_from_verdicts_before_its_guard(self):
        text = nightly_text()
        job = text[text.index("\n  publish-nightly-identity-legacy:"):]
        merge = job.index("nightly_next_ring.py legacy --new")
        self.assertLess(merge, job.index('nightly-next-guard.py appcast "legacy-out/$LEGACY_APPCAST"'))
        self.assertIn('--verdicts-base "$NIGHTLY_NEXT_FEED_BASE"', job[merge:merge + 400])

    def test_signing_and_publishing_skip_the_same_builds(self):
        # A Dev item above the old feed's Nightly must not hold back an older
        # Nightly build in either job (else Nightly installs stay stuck).
        text = nightly_text()
        rule = [
            'nightly_next_ring.py select --feed "$RUNNER_TEMP/old-feed.xml" --out "$RUNNER_TEMP/old-nightly.xml" --channel cmux-next',
            'grep -q "<sparkle:version>${NIGHTLY_BUILD}</sparkle:version>" "$RUNNER_TEMP/old-feed.xml"',
            '{ [ -n "$current" ] && [ "$NIGHTLY_BUILD" -le "$current" ]; }',
        ]
        for start, end in (("\n  sign-nightly-identity-legacy:", "Initialize cmux-next notices submodule"),
                           ("\n  publish-nightly-identity-legacy:", "name: Download the stapled cmux NIGHTLY DMG")):
            begin = text.index(start)
            step = text[text.index("name: Skip a build the old feed already has", begin):text.index(end, begin)]
            for line in rule:
                self.assertIn(line, step, start)

    def test_a_pending_build_the_old_feed_lists_is_not_continued(self):
        text = nightly_text()
        job = text[text.index("\n  legacy-identity-target:"):text.index("\n  sign-nightly-identity-legacy:")]
        stale = job.index('grep -q "<sparkle:version>${pending_build}</sparkle:version>" old-all.xml')
        self.assertLess(stale, job.index("pending_args=(--pending-meta"))

    def test_a_verdict_promotes_on_the_old_feed_too(self):
        text = VERDICT_YML.read_text()
        main = text.index("name: Move builds whose canary passed to Nightly")
        legacy = text.index("name: Move the old feed's builds whose canary passed to Nightly")
        self.assertLess(main, legacy)
        step = text[legacy:]
        self.assertIn("${NIGHTLY_NEXT_LEGACY_FEED_BASE}/${NIGHTLY_APPCAST}", step)
        self.assertIn("--replace-sha256", step)
        self.assertIn('verdicts/${KEY##*/}', text)

    def test_a_failed_old_feed_promotion_fails_the_verdict_run(self):
        # The NEXT feed's promotion runs first and is kept when the old feed's
        # write fails; that failure turns the run red instead of passing
        # quietly with the two feeds on different rings.
        steps = yaml.safe_load(VERDICT_YML.read_text())["jobs"]["write"]["steps"]
        names = [s.get("name") for s in steps]
        main = names.index("Move builds whose canary passed to Nightly")
        legacy = names.index("Move the old feed's builds whose canary passed to Nightly")
        self.assertLess(main, legacy)
        self.assertNotIn("continue-on-error", steps[legacy])
        self.assertNotIn("never fails the verdict", VERDICT_YML.read_text())

    def test_a_verdict_promotes_on_the_live_feed_with_if_match(self):
        text = VERDICT_YML.read_text()
        self.assertIn("nightly_next_ring.py retag", text)
        self.assertIn("--replace-sha256", text)
        self.assertIn("scripts/ci/nightly_next_ring.py", text)


class LegacyPublishedTests(unittest.TestCase):
    """Run 40239403743 published cmux NEXT while every legacy job skipped: a rate-limited
    requirement read was taken for a refusal, and continue-on-error kept the run quiet."""

    WORKFLOW = nightly_text()

    def job(self, name: str) -> str:
        match = re.search(rf"\n  {name}:\n(.*?)(?=\n  [a-z0-9-]+:\n|\Z)", self.WORKFLOW, re.S)
        self.assertIsNotNone(match, name)
        return match.group(1)

    def gate(self, **env: str) -> subprocess.CompletedProcess:
        body = self.job("nightly-identity-legacy-published")
        script = body[body.index("        run: |\n") + len("        run: |\n"):]
        script = "\n".join(line[10:] for line in script.splitlines())
        base = {"DECIDED": "true", "ACTION": "new", "BUILD": "4023940374302", "NEXT_BUILD": "4023940374302",
                "SIGN_SKIP": "false", "SIGN_PENDING": "false", "SIGN_OK": "true", "TESTED": "abc123", "ALREADY": "false",
                "PUBLISHED": "true", "NEXT_OK": "true", "SOURCE_RUN": ""}
        return subprocess.run(["bash", "-c", script], env={"PATH": "/usr/bin:/bin", **base, **env},
                              capture_output=True, text=True)

    def test_the_gate_is_red_unless_the_old_feed_published_or_had_nothing_to(self):
        self.assertEqual(self.gate().returncode, 0)
        for env in ({"ACTION": "none", "BUILD": "", "PUBLISHED": ""}, {"SIGN_SKIP": "true", "PUBLISHED": ""},
                    {"ALREADY": "true", "PUBLISHED": "false"}, {"SIGN_PENDING": "true", "PUBLISHED": ""},
                    # A continued older build: the publisher runs only for this run's build.
                    {"ACTION": "continue", "BUILD": "4023540480101", "PUBLISHED": ""},
                    # This run's own build, which cmux NEXT did not publish: the old feed waits for it.
                    {"SOURCE_RUN": "41136161064", "NEXT_OK": "false", "PUBLISHED": ""},
                    {"SOURCE_RUN": "41136161064", "NEXT_BUILD": "4023940374303", "PUBLISHED": ""}):
            self.assertEqual(self.gate(**env).returncode, 0, env)
        # A failed target leaves no outputs (continue-on-error reports it as success).
        for env in ({"DECIDED": "", "ACTION": "", "BUILD": "", "PUBLISHED": ""},
                    {"PUBLISHED": ""}, {"PUBLISHED": "false"},
                    # A feed build a rescue's re-run signed (publish-nightly skipped there) that did not publish.
                    {"NEXT_OK": "false", "NEXT_BUILD": "", "PUBLISHED": "false"},
                    {"SOURCE_RUN": "41136161064", "PUBLISHED": "false"},
                    {"ACTION": "continue", "PUBLISHED": "false"},
                    # Pending, but the sign job failed after Apple took it (no stored bundle).
                    {"SIGN_PENDING": "true", "SIGN_OK": "false", "PUBLISHED": ""},
                    # A continued older build whose sign or verify failed.
                    {"ACTION": "continue", "BUILD": "4023540480101", "SIGN_OK": "false", "PUBLISHED": ""},
                    {"ACTION": "continue", "BUILD": "4023540480101", "TESTED": "", "PUBLISHED": ""}):
            result = self.gate(**env)
            self.assertEqual(result.returncode, 1, env)
            self.assertIn("::error title=cmux NIGHTLY feed not published::", result.stdout)

    def test_the_gate_reads_outputs_and_runs_in_every_run_the_target_ran_in(self):
        # Runs 41126559170 and 41136161064 (2026-10-30): the rescue's re-runs skipped publish-nightly, so this gate
        # skipped too and the old feed sat 27 hours behind with no red. It runs whatever cmux NEXT's publication did.
        body = self.job("nightly-identity-legacy-published")
        for need in ("publish-nightly", "legacy-identity-target", "sign-nightly-identity-legacy",
                     "verify-nightly-identity-legacy", "publish-nightly-identity-legacy"):
            self.assertIn(need, body.split("\n", 1)[0])
        condition = re.search(r'\n    if: "(.*)"\n', body).group(1)
        self.assertIn("always() && !cancelled()", condition)
        self.assertNotIn("publish-nightly", condition)
        self.assertIn("NEXT_OK: ${{ needs.publish-nightly.result == 'success' && needs.publish-nightly.outputs.refused != 'true' }}", body)
        self.assertIn("SOURCE_RUN: ${{ needs.legacy-identity-target.outputs.source_run }}", body)
        self.assertNotIn("\n    continue-on-error:", body)
        self.assertNotRegex(body, r"needs\.(?:legacy-identity-target|[a-z-]*identity-legacy)\.result")
        target = self.job("legacy-identity-target")
        self.assertIn("decided: ${{ steps.target.outputs.decided }}", target)
        self.assertEqual(target.count('echo "decided=true"'), 2)
        publish = self.job("publish-nightly-identity-legacy")
        self.assertIn("published: ${{ steps.publish.outcome == 'success' && 'true' || 'false' }}", publish)
        self.assertIn("already: ${{ steps.order.outputs.skip }}", publish)

    def test_only_a_refusal_skips_a_build_and_an_error_fails_the_target(self):
        body = self.job("legacy-identity-target")
        self.assertIn('nightly-next-legacy-requirement.sh "$GITHUB_REPOSITORY" "$build" $REQUIRED)" || rc=$?', body)
        self.assertIn('if [ "$rc" != 3 ]; then', body)
        self.assertNotIn('if check="$(', body)
        listing = body[body.index('candidates="$(gh api'):]
        listing = listing[:listing.index("\n          for candidate")]
        self.assertNotIn("|| true", listing)
        self.assertIn("exit 1", listing)


if __name__ == "__main__":
    unittest.main()
