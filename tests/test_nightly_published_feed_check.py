#!/usr/bin/env python3
"""A nightly-next run reads its feeds back before it says it published (scripts/ci/nightly_published_feed_check.py).

Run 45607031207 (2026-11-25): nightly-next-one refused build 4560703120701 and still ended green, and
dispatch-published-in asked for "Finish a published nightly-next build" while appcast-arm64.xml stayed on
4557519416001. Leo: "are nightlies not publishin? where the priority?"
"""
from __future__ import annotations

import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT / "scripts/ci") not in sys.path:
    sys.path.insert(0, str(ROOT / "scripts/ci"))
import nightly_published_feed_check as check  # noqa: E402
import nightly_next_live_feed_check as live  # noqa: E402

FEED = "https://files-next.cmux.com/nightly-next/appcast-arm64.xml"


def appcast(*builds: int) -> str:
    entries = "".join(f"<item><sparkle:version>{b}</sparkle:version><enclosure url='u' length='1'/></item>"
                      for b in builds)
    return ("<rss xmlns:sparkle='http://www.andymatuschak.org/xml-namespaces/sparkle'><channel>"
            f"{entries}</channel></rss>")


class VerdictTests(unittest.TestCase):
    def test_the_2026_11_25_stall_fails(self) -> None:
        errors = check.verdict("4560703120701", {FEED: 4557519416001})
        self.assertEqual(len(errors), 1)
        self.assertIn("did not move", errors[0])

    def test_no_build_or_no_feed_fails(self) -> None:
        self.assertTrue(check.verdict("", {FEED: 1}))
        self.assertTrue(check.verdict("12", {}))
        self.assertTrue(check.verdict("12", {FEED: None}))

    def test_this_build_or_a_newer_one_passes(self) -> None:
        self.assertEqual(check.verdict("4560703120701", {FEED: 4560703120701}), [])
        self.assertEqual(check.verdict("4560703120701", {FEED: 4561000000001}), [])


class MainTests(unittest.TestCase):
    def run_main(self, xml: str, build: str, refused: str = "") -> tuple[int, str]:
        original, reads = check.fetch, []
        check.fetch = lambda url: reads.append(url) or xml
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            out.write_text("")
            with mock.patch.dict(os.environ, {"GITHUB_OUTPUT": str(out)}):
                try:
                    code = check.main(["--feed-base", "https://files-next.cmux.com/nightly-next/",
                                       "--feeds", "appcast-arm64.xml", "--build", build, "--refused", refused,
                                       "--attempts", "1"])
                finally:
                    check.fetch = original
            if refused == "true":
                self.assertEqual(reads, [])
            return code, out.read_text()

    def test_reads_the_newest_item(self) -> None:
        self.assertEqual(self.run_main(appcast(4557519416001, 4557245517201), "4560703120701"), (1, ""))
        self.assertEqual(self.run_main(appcast(4557519416001, 4560703120701), "4560703120701"),
                         (0, "published=true\n"))

    def test_a_refused_build_asks_for_no_tail_without_failing(self) -> None:
        self.assertEqual(self.run_main(appcast(4557519416001), "4560703120701", "true"), (0, "published=false\n"))

    def test_shares_the_live_check_parser(self) -> None:
        self.assertIs(check.items, live.items)


class WorkflowTests(unittest.TestCase):
    def test_dispatch_published_in_reads_back_before_it_dispatches(self) -> None:
        text = (ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8")
        job = text[text.index("\n  dispatch-published-in:\n"):]
        job = job[:job.index("\n  published-in:\n")]
        readback = job.index("scripts/ci/nightly_published_feed_check.py")
        self.assertLess(readback, job.index("nightly_next_post_publish="))
        self.assertLess(readback, job.index("nightly_published_build.py pack"))
        # Every step after the read-back runs only when it said published.
        later = job[readback:].split("\n      - ")[1:]
        self.assertTrue(later)
        for step in later:
            self.assertIn("steps.readback.outputs.published == 'true'", step, step.splitlines()[0])


if __name__ == "__main__":
    unittest.main()
