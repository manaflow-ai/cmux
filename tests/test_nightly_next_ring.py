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

    def test_ring_off_leaves_the_feed_alone(self):
        result, out = self.run_script(503, ring="off")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(out, feed(item("400", "cmux-next-dev")))


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
        # retagged from its verdict (nightly_next_ring.py legacy).
        self.assertEqual(sum(ring_expr in tag for tag in tags), 3, tags)
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
        self.assertIn("publish-next-feed-keep-nightly.sh $(printf 'nightly-out/%s ' $NIGHTLY_FEEDS)", step)
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
                "PUBLISHED": "true"}
        return subprocess.run(["bash", "-c", script], env={"PATH": "/usr/bin:/bin", **base, **env},
                              capture_output=True, text=True)

    def test_the_gate_is_red_unless_the_old_feed_published_or_had_nothing_to(self):
        self.assertEqual(self.gate().returncode, 0)
        for env in ({"ACTION": "none", "BUILD": "", "PUBLISHED": ""}, {"SIGN_SKIP": "true", "PUBLISHED": ""},
                    {"ALREADY": "true", "PUBLISHED": "false"}, {"SIGN_PENDING": "true", "PUBLISHED": ""},
                    # A continued older build: the publisher runs only for this run's build.
                    {"ACTION": "continue", "BUILD": "4023540480101", "PUBLISHED": ""}):
            self.assertEqual(self.gate(**env).returncode, 0, env)
        # A failed target leaves no outputs (continue-on-error reports it as success).
        for env in ({"DECIDED": "", "ACTION": "", "BUILD": "", "PUBLISHED": ""},
                    {"PUBLISHED": ""}, {"PUBLISHED": "false"},
                    {"ACTION": "continue", "PUBLISHED": "false"},
                    # Pending, but the sign job failed after Apple took it (no stored bundle).
                    {"SIGN_PENDING": "true", "SIGN_OK": "false", "PUBLISHED": ""},
                    # A continued older build whose sign or verify failed.
                    {"ACTION": "continue", "BUILD": "4023540480101", "SIGN_OK": "false", "PUBLISHED": ""},
                    {"ACTION": "continue", "BUILD": "4023540480101", "TESTED": "", "PUBLISHED": ""}):
            result = self.gate(**env)
            self.assertEqual(result.returncode, 1, env)
            self.assertIn("::error title=cmux NIGHTLY feed not published::", result.stdout)

    def test_the_gate_reads_outputs_and_runs_whenever_cmux_next_published(self):
        body = self.job("nightly-identity-legacy-published")
        for need in ("publish-nightly", "legacy-identity-target", "sign-nightly-identity-legacy",
                     "verify-nightly-identity-legacy", "publish-nightly-identity-legacy"):
            self.assertIn(need, body.split("\n", 1)[0])
        self.assertIn("always() && !cancelled()", body)
        self.assertIn("needs.publish-nightly.result == 'success'", body)
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
