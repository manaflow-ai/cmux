#!/usr/bin/env python3
"""The post-publish read-back of the live nightly-next feeds (scripts/ci/nightly_next_live_feed_check.py).

2026-10-27: every nightly-next item after build 4038033920301 was on cmux-next-dev for hours,
so the shipped cmux NIGHTLY app (default ring Nightly) was offered nothing, and every check
stayed green. Leo: "but why shoudl there be a delay if we can just listen". Each publish now
reads its feed back and fails right then when the default Nightly app is offered nothing new.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from nightly_workflow_text import nightly_text  # noqa: E402

SCRIPT = ROOT / "scripts/ci/nightly_next_live_feed_check.py"
spec = importlib.util.spec_from_file_location("nightly_next_live_feed_check", SCRIPT)
live = importlib.util.module_from_spec(spec)
sys.modules["nightly_next_live_feed_check"] = live
spec.loader.exec_module(live)

RING_SPEC = importlib.util.spec_from_file_location("nightly_next_ring", ROOT / "scripts/ci/nightly_next_ring.py")
ring = importlib.util.module_from_spec(RING_SPEC)
RING_SPEC.loader.exec_module(ring)

UPDATE_RING = ROOT / "Packages/macOS/CmuxUpdater/Sources/CmuxUpdater/UpdateRing.swift"
FEED_RESOLVER = ROOT / "Packages/macOS/CmuxUpdater/Sources/CmuxUpdater/UpdateFeedResolver.swift"
SETTINGS = ROOT / "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Schema/SettingsSchema+Updates.generated.swift"


def swift_ring_channels() -> tuple[list[str], dict[str, str], str]:
    """(ring cases slowest first, each ring's sparkle:channel, the default ring) from the app source."""
    source = UPDATE_RING.read_text()
    body = source[source.index("enum UpdateRing"):]
    cases = re.findall(r"^\s*case (\w+)\s*$", body[:body.index("public var sparkleChannel")], re.MULTILINE)
    nightly = re.search(r'nightlyNextSparkleChannel = "([^"]+)"', FEED_RESOLVER.read_text()).group(1)
    switch = body[body.index("public var sparkleChannel"):body.index("public var acceptedSparkleChannels")]
    tags = {}
    for case, value in re.findall(r"case \.(\w+): ([^\n]+)", switch):
        value = value.strip()
        tags[case] = nightly if value.endswith("nightlyNextSparkleChannel") else value.strip('"')
    default = re.search(r"channelDefault: UpdatesChannelSetting = \.(\w+)", SETTINGS.read_text()).group(1)
    return cases, tags, default


def accepted(ring_name: str) -> set[str]:
    """UpdateRing.acceptedSparkleChannels: its own tag and every slower ring's (allCases order)."""
    cases, tags, _ = swift_ring_channels()
    return {tags[case] for case in cases[:cases.index(ring_name) + 1]}


def appcast(*entries: tuple[int, str | None]) -> str:
    body = "".join(
        "<item>"
        + (f"<sparkle:channel>{channel}</sparkle:channel>" if channel else "")
        + f"<sparkle:version>{build}</sparkle:version>"
        f'<enclosure url="https://files-next.cmux.com/nightly-next/next/cmux-nightly-next-macos-arm64-{build}.dmg" length="10"/>'
        "</item>"
        for build, channel in entries)
    return f'<rss xmlns:sparkle="{live.SPARKLE}"><channel>{body}</channel></rss>'


def ok(url):
    return 200, 10


class ShippedAppChannelTests(unittest.TestCase):
    """Every channel the feed writers put on an item is one the shipped NIGHTLY app takes, or the
    Dev tag that waits for its verdict; derived from the app source, so a rename fails here."""

    def test_the_default_ring_is_nightly_and_accepts_what_the_check_accepts(self):
        cases, tags, default = swift_ring_channels()
        self.assertEqual(default, "nightly")
        self.assertEqual(set(live.NIGHTLY_ACCEPTED), accepted(default))
        self.assertEqual(live.DEV, tags["dev"])
        self.assertNotIn(live.DEV, live.NIGHTLY_ACCEPTED)

    def test_the_ring_writer_only_writes_nightly_or_dev(self):
        _, tags, _ = swift_ring_channels()
        self.assertEqual(ring.NIGHTLY, tags["nightly"])
        self.assertEqual(ring.DEV, tags["dev"])
        self.assertEqual(set(ring.RING_CHANNELS), set(tags.values()))
        self.assertIn(ring.new_build_channel("off"), accepted("nightly"))
        self.assertEqual(ring.new_build_channel("on"), tags["dev"])
        # retag writes cmux-next on a pass (or with the ring off) and cmux-next-dev otherwise.
        text = appcast((3, None), (2, "cmux-next-dev"), (1, "cmux-next"))
        for mode in ("on", "off"):
            for verdict in ("pass", "fail", "skipped", None):
                _, summary = ring.retag(text, mode, lambda build: verdict)
                self.assertLessEqual(set(summary["channels"].values()), {ring.NIGHTLY, ring.DEV}, (mode, verdict))
                if mode == "off" or verdict == "pass":
                    self.assertEqual(set(summary["channels"].values()), {ring.NIGHTLY})

    def test_every_workflow_channel_is_nightly_or_the_dev_ring_switch(self):
        text = nightly_text()
        for tag in re.findall(r"^\s+SPARKLE_CHANNEL: (.*)$", text, re.MULTILINE):
            # The values an expression can yield: the operands after && or ||, not the ones
            # compared against (== 'on', == 'nightly-next').
            values = set(re.findall(r"(?:&&|\|\|)\s*'([a-z-]*)'", tag)) if "${{" in tag else {tag.strip()}
            self.assertLessEqual(values - {""}, accepted("nightly") | {live.DEV}, tag)


class CheckTests(unittest.TestCase):
    def check(self, feed, build, before=None, dev_ring="off", probe=ok):
        return live.check(live.items(feed), build, live.items(before) if before else None, dev_ring, probe)

    def test_a_promoted_downloadable_newer_build_passes(self):
        errors, warnings = self.check(appcast((2, "cmux-next"), (1, "cmux-next")), 2, appcast((1, "cmux-next")))
        self.assertEqual((errors, warnings), ([], []))

    def test_a_dev_build_with_the_ring_off_fails_loudly(self):
        # 2026-10-27 08:39Z: a re-run kept the ring-on vars snapshot and tagged the build Dev.
        errors, _ = self.check(appcast((2, "cmux-next-dev"), (1, "cmux-next")), 2, appcast((1, "cmux-next")))
        self.assertTrue(any("does not accept" in error and "offered build 1" in error for error in errors), errors)

    def test_a_dev_build_with_the_ring_on_is_a_warning(self):
        errors, warnings = self.check(appcast((2, "cmux-next-dev"), (1, "cmux-next")), 2,
                                      appcast((1, "cmux-next")), dev_ring="on")
        self.assertEqual(errors, [])
        self.assertIn("offered build 1", warnings[0])

    def test_an_unknown_channel_fails_even_with_the_ring_on(self):
        errors, _ = self.check(appcast((2, "cmux-next-canary")), 2, dev_ring="on")
        self.assertTrue(errors)

    def test_an_enclosure_that_is_not_downloadable_fails(self):
        errors, _ = self.check(appcast((2, "cmux-next")), 2, probe=lambda url: (404, None))
        self.assertTrue(any("HTTP 404" in error for error in errors), errors)
        errors, _ = self.check(appcast((2, "cmux-next")), 2, probe=lambda url: (200, 9))
        self.assertTrue(any("9 bytes" in error for error in errors), errors)
        # A length the edge does not name is unverified, not a pass.
        errors, _ = self.check(appcast((2, "cmux-next")), 2, probe=lambda url: (200, None))
        self.assertTrue(any("names no length" in error for error in errors), errors)

    def test_only_a_200_with_a_length_passes_the_enclosure_check(self):
        for status, length in ((206, 10), (404, None), (200, None)):
            errors, _ = self.check(appcast((2, "cmux-next")), 2, probe=lambda url, s=status, n=length: (s, n))
            self.assertTrue(errors, (status, length))

    def test_the_fallback_is_a_plain_get_read_for_its_headers(self):
        import unittest.mock
        seen = []
        class Response:
            def __init__(self, status, length):
                self.status, self.headers = status, {"Content-Length": length} if length else {}
            def __enter__(self): return self
            def __exit__(self, *exc): return False
        def urlopen(request, timeout):
            seen.append((request.get_method(), request.get_header("Range")))
            return Response(200, None) if request.get_method() == "HEAD" else Response(200, "10")
        with unittest.mock.patch.object(live.urllib.request, "urlopen", urlopen):
            self.assertEqual(live.probe_once("https://files-next.cmux.com/x.dmg"), (200, 10))
        self.assertEqual(seen, [("HEAD", None), ("GET", None)])

    def test_the_probe_retries_and_retries_a_failed_probe(self):
        import unittest.mock
        answers = iter([(502, None), (200, 10)])
        with unittest.mock.patch.object(live, "probe_once", lambda url: next(answers)), \
                unittest.mock.patch.object(live.time, "sleep") as sleep:
            self.assertEqual(live.probe("u"), (200, 10))
        sleep.assert_called_once()

    def test_a_write_that_never_reached_the_public_feed_fails(self):
        errors, _ = self.check(appcast((1, "cmux-next")), 2)
        self.assertTrue(any("never reached" in error for error in errors), errors)
        self.assertTrue(self.check(appcast(), 2)[0])

    def test_the_offered_build_never_moves_back_or_stands_still_with_the_ring_off(self):
        errors, _ = self.check(appcast((3, "cmux-next-dev")), 3, appcast((2, "cmux-next")), dev_ring="on")
        self.assertTrue(any("went back from 2 to none" in error for error in errors), errors)
        errors, _ = self.check(appcast((3, "cmux-next-dev"), (2, "cmux-next")), 3, appcast((2, "cmux-next")))
        self.assertTrue(any("still offered build 2" in error for error in errors), errors)

    def test_a_newer_build_already_live_is_not_this_writes_failure(self):
        # Another run published a newer build first: the check reads that one.
        errors, _ = self.check(appcast((5, "cmux-next"), (2, "cmux-next")), 2, appcast((4, "cmux-next")))
        self.assertEqual(errors, [])


class MainTests(unittest.TestCase):
    def test_a_failure_prints_every_item_and_the_retry_is_short(self):
        import contextlib, io, unittest.mock
        feed = appcast((2, "cmux-next-dev"), (1, "cmux-next"))
        out = io.StringIO()
        with unittest.mock.patch.object(live, "fetch", lambda url: feed), \
                unittest.mock.patch.object(live, "probe", ok), \
                unittest.mock.patch.object(live.time, "sleep") as sleep, \
                contextlib.redirect_stdout(out):
            code = live.main(["--feed-url", "u", "--build", "2"])
        self.assertEqual(code, 1)
        text = out.getvalue()
        self.assertIn("2  channel=cmux-next-dev  NOT offered to Nightly", text)
        self.assertIn("1  channel=cmux-next  offered to Nightly", text)
        self.assertIn("cmux-nightly-next-macos-arm64-2.dmg length=10", text)
        sleep.assert_not_called()  # the newest build was already live: no retry
        with unittest.mock.patch.object(live, "fetch", lambda url: appcast((1, "cmux-next"))), \
                unittest.mock.patch.object(live, "probe", ok), \
                unittest.mock.patch.object(live.time, "sleep") as sleep, \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(live.main(["--feed-url", "u", "--build", "2"]), 1)
        self.assertEqual(sum(call.args[0] for call in sleep.call_args_list), 4.0)


class BaselineTests(unittest.TestCase):
    def run_main(self, before_text):
        import contextlib, io, tempfile, unittest.mock
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "before.xml"
            if before_text is not None:
                path.write_text(before_text)
            with unittest.mock.patch.object(live, "fetch", lambda url: appcast((2, "cmux-next"))), \
                    unittest.mock.patch.object(live, "probe", ok), \
                    contextlib.redirect_stdout(io.StringIO()) as out:
                return live.main(["--feed-url", "u", "--build", "2", "--before", str(path)]), out.getvalue()

    def test_a_missing_baseline_fails_and_a_404_baseline_has_no_floor(self):
        code, out = self.run_main(None)
        self.assertEqual(code, 1)
        self.assertIn("a regression cannot be ruled out", out)
        self.assertEqual(self.run_main("absent")[0], 0)
        for empty in ("<rss><channel></channel></rss>", ""):
            code, out = self.run_main(empty)
            self.assertEqual(code, 1, repr(empty))
            self.assertIn("a regression cannot be ruled out", out)
        self.assertEqual(self.run_main(appcast((1, "cmux-next")))[0], 0)


class WorkflowTests(unittest.TestCase):
    """Both nightly-next feed writers read their feed back right after the write."""

    def job(self, name: str, until: str) -> str:
        text = nightly_text()
        return text[text.index(f"\n  {name}:"):text.index(f"\n  {until}:")]

    def test_publish_nightly_reads_the_next_feed_back(self):
        job = self.job("publish-nightly", "publish-nightly-next-github")
        upload = job.index("- name: Upload nightly-next appcasts to R2")
        readback = job.index("- name: Read the live nightly-next feed back")
        self.assertLess(upload, readback)
        # Last in the job, never failing it, and reported by report-nightly-failure.
        self.assertNotIn("\n      - ", job[readback + 1:])
        step = job[readback:]
        self.assertIn("if: always() && steps.recheck.outputs.already_published != 'true' && steps.upload_next_appcasts.outputs.feed_written == 'true'", step)
        self.assertIn("continue-on-error: true", step)
        self.assertIn("nightly_next_live_feed_check.py", step)  # the step runs publish-next-feed-readback.sh
        self.assertIn("feed_check: ${{ steps.feedcheck.outcome }}", job)
        self.assertIn("needs.publish-nightly.outputs.feed_check == 'failure'", nightly_text())
        script = (ROOT / "scripts/ci/nightly-steps/publish-next-feed-readback.sh").read_text()
        self.assertIn("nightly_next_live_feed_check.py", script)
        self.assertIn('--build "$NIGHTLY_BUILD" --dev-ring "$DEV_RING" --before', script)

    def test_the_old_feed_is_read_back_after_its_publish(self):
        job = self.job("publish-nightly-identity-legacy", "nightly-identity-legacy-published")
        publish = job.index("- name: Publish the cmux NIGHTLY DMG, release notes and the old feed")
        readback = job.index("- name: Read the old feed back")
        self.assertLess(publish, readback)
        # After the attempt accounting, which reads steps.publish only.
        self.assertLess(job.index("- name: Fail a failed attempt"), readback)
        self.assertIn("if: always() && steps.publish.outcome == 'success'", job[readback:])
        script = (ROOT / "scripts/ci/nightly-steps/legacy-identity-readback.sh").read_text()
        self.assertIn('${NIGHTLY_NEXT_LEGACY_FEED_BASE}/${LEGACY_APPCAST}', script)
        self.assertIn("--before", script)


if __name__ == "__main__":
    unittest.main()
